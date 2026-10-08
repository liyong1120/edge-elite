# -*- coding: utf-8 -*-
"""
GLB 尺寸归一化 / 减面工具

解决的问题：图生 3D 出来的模型，尺寸和朝向完全随机 —— 有的 2.8 米长，
有的 0.2 米，比例也常常不对。这个脚本把任意来源的 GLB 强制校正到规格尺寸。

用法：
    # 单个文件
    blender --background --factory-startup --python tools/normalize_glb.py -- \
        --in "D:/下载/AK47_raw.glb" --out "models/fpv/AK47.glb"

    # 整个目录批量（按文件名自动查规格表）
    blender --background --factory-startup --python tools/normalize_glb.py -- \
        --in-dir "D:/下载/武器" --out-dir "models/fpv"

    # 顺便减面到 600 面
    ... --in-dir "D:/下载" --out-dir "models/fpv" --decimate 600

    # 只看会怎么处理，不写文件
    ... --in-dir "D:/下载" --dry-run

    # 强制指定目标长度（不在规格表里的型号）
    ... --in "x.glb" --out "y.glb" --len 0.9

对静态模型做的事：
    1. 测包围盒 → 把最长轴缩放到规格全长（保持长宽高比例，不变形）
    2. 最长轴对齐到 Z 轴（枪口方向，游戏内还会自动纠正）
    3. 顶点平移，让包围盒中心落在原点
    4. 可选：Decimate 减面到目标三角面数
    5. 导出单位变换的干净 GLB（Godot 里旋转不会斜切）

对带骨骼 / 动画的模型：
    默认 **跳过**。顶点级操作会把蒙皮和动画整段抹掉（实测角色 52 个动画会全丢）。
    确实需要缩放时加 --allow-rig，此时只对骨架做等比缩放，不碰顶点、不减面。
"""

import bpy
import math
import os
import sys
from mathutils import Vector, Matrix

D = math.radians

# 文件名(不含扩展名) -> 规格全长（米），取自《素材规格清单.md》+ 真枪数据
TARGET_LEN = {
    "Knife": 0.30,
    "Glock": 0.20,
    "USP":   0.33,   # 含消音器
    "Deagle": 0.27,
    "MP5":   0.65,
    "P90":   0.50,
    "AK47":  0.88,
    "M4A1":  0.84,
    "Galil": 0.78,
    "FAMAS": 0.79,
    "AUG":   0.82,
    "SG552": 0.75,
    "Scout": 1.04,
    "SG550": 1.00,
    "G3SG1": 1.12,
    "AWP":   1.14,
    "M249":  1.05,
    # 角色：按身高处理
    "player":   1.80,
    "t_player": 1.80,
}

TOL = 0.03          # 尺寸误差容限（米）


def clear():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for blk in (bpy.data.meshes, bpy.data.materials, bpy.data.images,
                bpy.data.armatures, bpy.data.actions):
        for b in list(blk):
            if b.users == 0:
                blk.remove(b)


def local_bounds(obj):
    """遍历顶点算包围盒（不依赖 matrix_world，后台模式下才可靠）。"""
    vs = obj.data.vertices
    if not len(vs):
        return None, None
    lo = Vector((min(v.co.x for v in vs), min(v.co.y for v in vs), min(v.co.z for v in vs)))
    hi = Vector((max(v.co.x for v in vs), max(v.co.y for v in vs), max(v.co.z for v in vs)))
    return lo, hi


def import_glb(path):
    """返回 (mesh对象, 骨架对象或None, 全部新对象列表)。"""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in new if o.type == "MESH"]
    arms = [o for o in new if o.type == "ARMATURE"]
    if not meshes:
        return None, None, new

    rigged = bool(arms) or any(
        m.type == "ARMATURE" for o in meshes for m in o.modifiers)

    if rigged:
        # 有骨骼：保持原样，不做 join / 不烘变换
        return meshes[0], (arms[0] if arms else None), new

    if len(meshes) > 1:
        bpy.ops.object.select_all(action="DESELECT")
        for o in meshes:
            o.select_set(True)
        bpy.context.view_layer.objects.active = meshes[0]
        bpy.ops.object.join()
        meshes = [bpy.context.active_object]
    obj = meshes[0]
    # 把导入时带的变换烘进网格，之后全部按本地坐标处理
    obj.data.transform(obj.matrix_basis)
    obj.matrix_basis = Matrix.Identity(4)
    obj.parent = None
    return obj, None, new


def tris_of(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


def normalize_static(obj, target_len, decimate=None, align=True):
    lo, hi = local_bounds(obj)
    if lo is None:
        return None
    size = hi - lo
    longest = max(size.x, size.y, size.z)
    if longest < 1e-9:
        return None
    s = target_len / longest

    for v in obj.data.vertices:
        v.co *= s
    obj.data.update()

    # 最长轴对齐到 Z
    if align:
        lo, hi = local_bounds(obj)
        size = hi - lo
        axis = [size.x, size.y, size.z].index(max(size.x, size.y, size.z))
        R = Matrix.Identity(4)
        if axis == 0:
            R = Matrix.Rotation(D(-90), 4, "Y")
        elif axis == 1:
            R = Matrix.Rotation(D(-90), 4, "X")
        if axis != 2:
            for v in obj.data.vertices:
                v.co = R @ v.co
            obj.data.update()

    # 居中到原点
    lo, hi = local_bounds(obj)
    c = (lo + hi) / 2.0
    for v in obj.data.vertices:
        v.co -= c
    obj.data.update()

    before_tris = tris_of(obj)
    if decimate and before_tris > decimate:
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        m = obj.modifiers.new("Decimate", "DECIMATE")
        m.decimate_type = "COLLAPSE"
        m.ratio = float(decimate) / float(before_tris)
        bpy.ops.object.modifier_apply(modifier=m.name)

    lo, hi = local_bounds(obj)
    return {"size": tuple(hi - lo), "tris": tris_of(obj),
            "tris_before": before_tris, "scale": s}


def normalize_rigged(mesh, arm, target_len):
    """只对骨架做等比缩放，不碰顶点，保住蒙皮和动画。"""
    lo, hi = local_bounds(mesh)
    if lo is None:
        return None
    size = hi - lo
    longest = max(size.x, size.y, size.z)
    if longest < 1e-9:
        return None
    s = target_len / longest
    if arm is not None:
        arm.scale = tuple(c * s for c in arm.scale)
    else:
        mesh.scale = tuple(c * s for c in mesh.scale)
    return {"size": tuple(size * s), "tris": tris_of(mesh),
            "tris_before": tris_of(mesh), "scale": s}


def export(objs, path):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    kwargs = dict(filepath=path, export_format="GLB", use_selection=True,
                  export_apply=False, export_yup=True, export_materials="EXPORT")
    try:
        bpy.ops.export_scene.gltf(**kwargs)
    except TypeError:
        for k in ("export_materials", "export_yup", "export_apply"):
            kwargs.pop(k, None)
        bpy.ops.export_scene.gltf(**kwargs)


def process(src, dst, target_len, decimate, dry, allow_rig):
    clear()
    name = os.path.splitext(os.path.basename(src))[0]
    try:
        mesh, arm, allnew = import_glb(src)
    except Exception as exc:
        print("  × %-10s 导入失败: %s" % (name, exc))
        return False
    if mesh is None:
        print("  × %-10s 没有网格" % name)
        return False

    rigged = arm is not None or any(
        m.type == "ARMATURE" for m in mesh.modifiers)
    if rigged:
        if not allow_rig:
            print("  - %-10s 带骨骼/动画，已跳过（加 --allow-rig 可只做等比缩放）" % name)
            return None
        info = normalize_rigged(mesh, arm, target_len)
        out_objs = allnew
    else:
        info = normalize_static(mesh, target_len, decimate)
        out_objs = [mesh]

    if info is None:
        print("  × %-10s 包围盒为空" % name)
        return False

    longest = max(info["size"])
    ok = abs(longest - target_len) <= TOL
    dec = ""
    if info["tris_before"] != info["tris"]:
        dec = " | 减面 %d→%d" % (info["tris_before"], info["tris"])
    print("  %s %-10s 目标 %.2fm → %.2f x %.2f x %.2f m | %d 面%s"
          % ("✓" if ok else "!", name, target_len, info["size"][0],
             info["size"][1], info["size"][2], info["tris"], dec))

    if not dry:
        d = os.path.dirname(dst)
        if d:
            os.makedirs(d, exist_ok=True)
        export(out_objs, dst)
    return True


def main():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []

    src = src_dir = dst = dst_dir = None
    decimate = None
    default_len = None
    dry = False
    allow_rig = False

    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--in" and i + 1 < len(argv):
            src = argv[i + 1]; i += 2
        elif a == "--out" and i + 1 < len(argv):
            dst = argv[i + 1]; i += 2
        elif a == "--in-dir" and i + 1 < len(argv):
            src_dir = argv[i + 1]; i += 2
        elif a == "--out-dir" and i + 1 < len(argv):
            dst_dir = argv[i + 1]; i += 2
        elif a == "--decimate" and i + 1 < len(argv):
            decimate = int(argv[i + 1]); i += 2
        elif a == "--len" and i + 1 < len(argv):
            default_len = float(argv[i + 1]); i += 2
        elif a == "--dry-run":
            dry = True; i += 1
        elif a == "--allow-rig":
            allow_rig = True; i += 1
        else:
            i += 1

    print("\n" + "=" * 78)
    print("GLB 尺寸归一化" + ("（预览模式，不写文件）" if dry else ""))
    print("=" * 78)

    jobs = []
    if src:
        name = os.path.splitext(os.path.basename(src))[0]
        t = default_len or TARGET_LEN.get(name)
        if t is None:
            print("× 未知型号 %s，请用 --len 指定目标长度" % name)
            return
        jobs.append((src, dst or os.path.join("models", "fpv", name + ".glb"), t))
    elif src_dir:
        if not os.path.isdir(src_dir):
            print("× 目录不存在: %s" % src_dir)
            return
        for f in sorted(os.listdir(src_dir)):
            if not f.lower().endswith((".glb", ".gltf")):
                continue
            name = os.path.splitext(f)[0]
            t = default_len or TARGET_LEN.get(name)
            if t is None:
                print("  - %-10s 不在规格表里，跳过（可用 --len 强制指定）" % name)
                continue
            out = os.path.join(dst_dir, name + ".glb") if dst_dir else \
                os.path.join(os.path.dirname(src_dir), name + ".glb")
            jobs.append((os.path.join(src_dir, f), out, t))
    else:
        print("用法见文件头注释。至少要给 --in 或 --in-dir。")
        return

    if not jobs:
        print("没有可处理的文件。")
        return

    ok = skip = 0
    for s, d, t in jobs:
        r = process(s, d, t, decimate, dry, allow_rig)
        if r is True:
            ok += 1
        elif r is None:
            skip += 1

    print("-" * 78)
    print("完成 %d/%d%s" % (ok, len(jobs), ("，跳过 %d" % skip) if skip else ""))
    if not dry:
        print("接着运行: python tools/glb_check.py")
    print("=" * 78 + "\n")


if __name__ == "__main__":
    main()
