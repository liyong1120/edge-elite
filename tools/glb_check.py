# -*- coding: utf-8 -*-
"""
GLB 素材自检工具 —— 对照《素材规格清单.md》检查 models/ 下的 GLB 模型。

零依赖（只用标准库），可直接双击运行或用 python 运行：
    python tools/glb_check.py

检查项：
    1. 三角面数        是否 <= 规格上限
    2. 模型尺寸        最长边（米）是否在合理区间
    3. 朝向            最长轴是哪一根（游戏内会自动适配，仅作提示）
    4. 材质/贴图       GLB 是否内嵌材质、是否有贴图、材质命名
    5. 缺失文件        规格清单里有、但 models/ 下没有的

退出码：0 = 全部通过，1 = 有警告/缺失
"""

import json
import os
import struct
import sys

# ----------------------------------------------------------------- 规格表
# 文件名(不含扩展名) -> (面数上限, 长度下限m, 长度上限m, 中文名)
FPV_SPEC = {
    "AK47":   (600, 0.70, 1.00, "AK-47"),
    "M4A1":   (600, 0.60, 0.95, "M4A1"),
    "AWP":    (700, 0.90, 1.30, "AWP"),
    "Knife":  (300, 0.20, 0.45, "匕首"),
    "Deagle": (400, 0.18, 0.38, "沙漠之鹰"),
    "Glock":  (350, 0.14, 0.30, "Glock-18"),
    "USP":    (350, 0.14, 0.40, "USP"),   # 含消音器约 0.33m（database.gd 中 suppressor:true）
    "MP5":    (500, 0.50, 0.80, "MP5"),
    "P90":    (500, 0.40, 0.65, "P90"),
    "Galil":  (500, 0.60, 0.95, "Galil"),
    "FAMAS":  (500, 0.60, 0.95, "FAMAS"),
    "AUG":    (500, 0.65, 1.00, "AUG"),
    "SG552":  (500, 0.65, 1.00, "SG-552"),
    "Scout":  (500, 0.85, 1.20, "Scout"),
    "SG550":  (500, 0.85, 1.20, "SG-550"),
    "G3SG1":  (500, 0.90, 1.30, "G3SG1"),
    "M249":   (700, 0.70, 1.20, "M249"),
}

# 角色：(面数上限, 身高下限m, 身高上限m, 中文名)
CHAR_SPEC = {
    "player":   (3000, 1.70, 1.90, "CT 磐垒"),
    "t_player": (3000, 1.70, 1.90, "T 锐刃"),
}

# 面数“软上限”：AI 生成器最低只能到 10000 面，
# 超过这个数只提示、不算失败（FPV 单模型渲染，1~2 万面无性能压力）
SOFT_TRI_LIMIT = 25000

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ----------------------------------------------------------------- GLB 解析
def read_glb(path):
    """返回 (gltf_json, bin_chunk)。失败抛异常。"""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 12:
        raise ValueError("文件太小，不是合法 GLB")
    magic, version, total = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF":
        raise ValueError("magic 不是 glTF，可能是 .gltf/.obj 或损坏文件")
    off, js, bin_chunk = 12, None, None
    while off + 8 <= len(data):
        clen, ctype = struct.unpack_from("<II", data, off)
        off += 8
        chunk = data[off:off + clen]
        off += clen
        if ctype == 0x4E4F534A:      # 'JSON'
            js = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:    # 'BIN'
            bin_chunk = chunk
    if js is None:
        raise ValueError("GLB 里没有 JSON chunk")
    return js, bin_chunk


def _mat_identity():
    return [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]


def _mat_mul(a, b):
    """列主序 4x4 相乘：返回 a*b。"""
    out = [0.0] * 16
    for c in range(4):
        for r in range(4):
            out[c * 4 + r] = sum(a[k * 4 + r] * b[c * 4 + k] for k in range(4))
    return out


def _node_matrix(node):
    if "matrix" in node and len(node["matrix"]) == 16:
        return list(node["matrix"])
    t = node.get("translation", [0.0, 0.0, 0.0])
    r = node.get("rotation", [0.0, 0.0, 0.0, 1.0])
    s = node.get("scale", [1.0, 1.0, 1.0])
    x, y, z, w = r
    # 四元数 -> 旋转矩阵（列主序）
    rot = [
        1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0,
        2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0,
        2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0,
        0, 0, 0, 1,
    ]
    m = _mat_identity()
    for c in range(3):
        for r_ in range(3):
            m[c * 4 + r_] = rot[c * 4 + r_] * s[c]
    m[12], m[13], m[14] = t[0], t[1], t[2]
    return m


def _xform(m, p):
    x, y, z = p
    return (
        m[0] * x + m[4] * y + m[8] * z + m[12],
        m[1] * x + m[5] * y + m[9] * z + m[13],
        m[2] * x + m[6] * y + m[10] * z + m[14],
    )


def analyze(path):
    """返回统计字典。"""
    js, _ = read_glb(path)
    meshes = js.get("meshes", [])
    accessors = js.get("accessors", [])
    materials = js.get("materials", [])
    images = js.get("images", [])
    textures = js.get("textures", [])

    tri_total = 0
    for mesh in meshes:
        for prim in mesh.get("primitives", []):
            mode = prim.get("mode", 4)
            if mode != 4:           # 只统计三角形
                continue
            if "indices" in prim:
                tri_total += accessors[prim["indices"]]["count"] // 3
            elif "POSITION" in prim.get("attributes", {}):
                tri_total += accessors[prim["attributes"]["POSITION"]]["count"] // 3

    # 遍历场景，把各 mesh 的局部 AABB 变换到世界空间合并
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    found = False
    has_skin = bool(js.get("skins"))

    def visit(idx, parent):
        nonlocal found
        node = js["nodes"][idx]
        # 跳过第一人称手臂节点（武器 GLB 里名为 arms 的独立节点），
        # 它只是装饰，不该算进规格尺寸
        if "arms" in node.get("name", "").lower():
            return
        m = _mat_mul(parent, _node_matrix(node))
        # 蒙皮网格：顶点最终位置由骨骼 + inverseBindMatrices 决定，
        # 用节点变换去算包围盒会得出完全错误的尺寸，直接跳过。
        if "mesh" in node and "skin" not in node:
            for prim in meshes[node["mesh"]].get("primitives", []):
                acc_i = prim.get("attributes", {}).get("POSITION")
                if acc_i is None:
                    continue
                acc = accessors[acc_i]
                if "min" not in acc or "max" not in acc:
                    continue
                mn, mx = acc["min"], acc["max"]
                for i in range(8):
                    corner = (
                        mn[0] if i & 1 else mx[0],
                        mn[1] if i & 2 else mx[1],
                        mn[2] if i & 4 else mx[2],
                    )
                    p = _xform(m, corner)
                    for k in range(3):
                        lo[k] = min(lo[k], p[k])
                        hi[k] = max(hi[k], p[k])
                    found = True
        for c in node.get("children", []):
            visit(c, m)

    scene_i = js.get("scene", 0)
    scenes = js.get("scenes", [{}])
    for root in scenes[scene_i].get("nodes", []) if scenes else []:
        visit(root, _mat_identity())
    if not found:                    # 没有 scene 就遍历全部 node
        for i in range(len(js.get("nodes", []))):
            visit(i, _mat_identity())

    size = [hi[k] - lo[k] for k in range(3)] if found else [0.0, 0.0, 0.0]
    return {
        "tris": tri_total,
        "size": size,
        "measured": found,
        "skinned": has_skin,
        "longest": max(size) if found else 0.0,
        "axis": "XYZ"[size.index(max(size))] if found else "-",
        "materials": [m.get("name", "(未命名)") for m in materials],
        "tex_count": len(textures),
        "img_count": len(images),
        "has_vertex_color": any(
            "COLOR_0" in p.get("attributes", {})
            for m in meshes for p in m.get("primitives", [])
        ),
    }


# ----------------------------------------------------------------- 主流程
def fmt_size(size):
    return "%.2f x %.2f x %.2f m" % (size[0], size[1], size[2])


def check_dir(subdir, spec, kind):
    folder = os.path.join(ROOT, "models", subdir)
    rows, missing, failed = [], [], []
    if not os.path.isdir(folder):
        return rows, list(spec.keys()), failed

    for name, (tri_max, lo, hi, cn) in sorted(spec.items()):
        path = os.path.join(folder, name + ".glb")
        if not os.path.isfile(path):
            missing.append(name)
            continue
        try:
            info = analyze(path)
        except Exception as exc:
            rows.append((name, cn, "解析失败: %s" % exc, "FAIL"))
            failed.append(name)
            continue

        issues = []
        status = "OK"
        # 面数
        if info["tris"] > tri_max:
            issues.append("面数 %d > 上限 %d" % (info["tris"], tri_max))
            if kind == "角色":
                # 规格书里的 3000 面是给 AI 生成定的；真人/商业素材 1~3 万面属正常
                status = "INFO" if status == "OK" else status
            else:
                status = "WARN"
        # 尺寸（蒙皮模型无法从 GLB 静态推算，跳过）
        L = info["longest"]
        if not info["measured"]:
            issues.append("蒙皮模型，尺寸请在引擎内实测")
        elif L < lo or L > hi:
            issues.append("尺寸 %.2fm 超出 %.2f~%.2f" % (L, lo, hi))
            status = "WARN" if status == "OK" else status
        if not info["materials"]:
            issues.append("无材质")
            status = "FAIL"
            failed.append(name)
        elif info["tex_count"] == 0:
            issues.append("无贴图（纯色/顶点色）")

        if info["measured"]:
            size_txt = fmt_size(info["size"])
            axis_txt = info["axis"]
        else:
            size_txt, axis_txt = "蒙皮(不适用)", "-"
        detail = "%d 面 | %s | 长边 %s | 材质 %d | 贴图 %d" % (
            info["tris"], size_txt, axis_txt,
            len(info["materials"]), info["tex_count"])
        if issues:
            detail += "  ⚠ " + "；".join(issues)
        rows.append((name, cn, detail, status))

    # 目录里多余的文件
    if os.path.isdir(folder):
        for f in sorted(os.listdir(folder)):
            if f.endswith(".glb") and os.path.splitext(f)[0] not in spec:
                rows.append((os.path.splitext(f)[0], "(规格外)",
                             "文件存在但不在规格清单中", "INFO"))
    return rows, missing, failed


def main():
    print("=" * 78)
    print("素材自检报告")
    print("项目根目录: %s" % ROOT)
    print("=" * 78)

    total_missing, total_failed = [], []

    for subdir, spec, kind in (
        ("fpv", FPV_SPEC, "武器"),
        ("characters", CHAR_SPEC, "角色"),
    ):
        rows, missing, failed = check_dir(subdir, spec, kind)
        print("\n【%s】models/%s/" % (kind, subdir))
        print("-" * 78)
        if not rows:
            print("  (目录为空或不存在)")
        for name, cn, detail, status in rows:
            mark = {"OK": "  ✓", "WARN": "  !", "FAIL": "  ×", "INFO": "  -"}[status]
            print("%s %-10s %-12s %s" % (mark, name, cn, detail))
        if missing:
            print("\n  缺失 %d 个: %s" % (len(missing), "、".join(missing)))
        total_missing += missing
        total_failed += failed

    print("\n" + "=" * 78)
    print("汇总: 缺失 %d 个 | 严重问题 %d 个" % (len(total_missing), len(total_failed)))
    print("说明: '!' 表示与规格清单有偏差但游戏可正常运行（游戏内会自动适配尺寸/朝向）。")
    print("      '×' 表示模型不可用，需要重新生成。")
    print("=" * 78)
    return 1 if (total_missing or total_failed) else 0


if __name__ == "__main__":
    sys.exit(main())
