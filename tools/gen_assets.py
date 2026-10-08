# -*- coding: utf-8 -*-
"""
武器素材批量生成器

调用 WorkBuddy 内置的文生 3D 能力（腾讯混元 3D），按《素材规格清单.md》
的提示词批量生成武器 GLB，自动下载并落到 models/fpv/ 对应文件名。

用法（需要先拿到临时凭据）：
    python tools/gen_assets.py --token "<ck_t_xxxx>"                # 只补缺失的
    python tools/gen_assets.py --token "<ck_t_xxxx>" --only AK47 MP5 # 指定型号
    python tools/gen_assets.py --token "<ck_t_xxxx>" --all --force   # 全部重生成
    python tools/gen_assets.py --list                                # 只看清单不生成
    python tools/gen_assets.py --dry-run                             # 打印将执行的命令

注意：
  * 生成一个模型约 1~5 分钟，17 个全部生成需要 20~60 分钟。
  * 会消耗云端生成额度。
  * 生成器最低面数是 10000（--face-count 下限），无法做到规格书里的 500~700 面。
    但游戏内 FPV 只渲染一把枪，1~2 万面无性能压力；若要严格达标需 Blender 减面。
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "models", "fpv")

SKILL_SCRIPT = (
    r"C:\Users\liyong\.workbuddy-ai\plugins\cache\workbuddy-builtin"
    r"\skill-buddy-multimodal-generation\5.6.2-wb.39458645.g35219ed6.h85a557611a02"
    r"\scripts\buddy-multimodal-generation.py"
)
PYTHON = r"C:\Users\liyong\.workbuddy-ai\binaries\python\envs\default\Scripts\python.exe"

# 统一的风格前缀：把规格书「通用约束」里能生效的部分压进提示词
STYLE = ("low poly 1999 retro military FPS game asset, gritty realistic, "
         "clean UV layout, PBR textures, no hands, no arms, no animation, "
         "single object centered at origin")

# 文件名 -> 提示词主体
WEAPONS = {
    "AK47": "an AK-47 assault rifle, black metal receiver, brown wooden handguard "
            "and buttstock, strongly curved banana magazine, muzzle brake, rear sight block",
    "M4A1": "an M4A1 carbine, black and dark grey metal, carry handle rear sight, "
            "collapsible stock, straight magazine",
    "AWP": "an AWP bolt-action sniper rifle, dark olive green body, long black barrel, "
           "large scope on top, curved magazine, thumbhole stock",
    "Knife": "a military combat knife, silver blade with serrated spine and blood groove, "
             "black wrapped handle",
    "Deagle": "a Desert Eagle large caliber pistol, silver chrome slide with black grip, "
              "wide heavy frame, thick barrel",
    "Glock": "a Glock 18 compact black polymer pistol, boxy slide, rectangular grip",
    "USP": "a USP pistol, dark grey metal slide, black polymer frame, threaded barrel",
    "MP5": "an MP5 submachine gun, black metal, curved magazine, slim foregrip, "
           "retractable stock, cylindrical receiver",
    "P90": "a P90 submachine gun, distinctive bullpup polymer shell, magazine on top, "
           "forward vertical grip, thumbhole",
    "Galil": "a Galil assault rifle, black metal receiver, brown wooden handguard "
             "and folding stock, curved magazine, muzzle brake, carry handle",
    "FAMAS": "a FAMAS bullpup assault rifle, black metal, distinctive tall carry handle "
             "with integrated sight, curved magazine behind the grip",
    "AUG": "a Steyr AUG bullpup assault rifle, black polymer body, integrated optical "
           "scope in carry handle, curved translucent magazine, vertical foregrip",
    "SG552": "a SIG SG-552 short assault rifle, black metal, side folding stock, "
             "optical scope on rail, curved magazine",
    "Scout": "a Steyr Scout bolt-action sniper rifle, black lightweight body, "
             "long thin barrel, optical scope, detachable box magazine",
    "SG550": "a SIG SG-550 semi-automatic sniper rifle, black and dark grey metal, "
             "optical scope, adjustable stock, curved magazine",
    "G3SG1": "a Heckler Koch G3SG1 semi-automatic sniper rifle, black metal, "
             "optical scope, adjustable stock, curved magazine",
    "M249": "an M249 light machine gun, black metal, large ammunition box underneath, "
            "bipod, long barrel with heat shield, carry handle",
}


def run_cmd(args, dry=False):
    if dry:
        print("  $ " + " ".join('"%s"' % a if " " in a else a for a in args))
        return None
    proc = subprocess.run(args, capture_output=True, text=True, encoding="utf-8",
                          errors="replace")
    if proc.returncode != 0:
        return {"__error__": (proc.stdout or "") + (proc.stderr or "")}
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"__error__": "无法解析输出: " + (proc.stdout or "")[:400]}


def collect_urls(payload):
    """从返回里挖出所有可下载的文件 URL（兼容多种字段形态）。"""
    urls = []

    def walk(node, depth=0):
        if depth > 6:
            return
        if isinstance(node, str):
            low = node.lower().split("?")[0]
            if low.endswith((".glb", ".gltf", ".zip", ".obj", ".fbx")):
                urls.append(node)
        elif isinstance(node, dict):
            for k, v in node.items():
                if k in ("url", "Url", "FileUrl", "ResultUrl", "ModelUrl",
                         "ResultModelUrl", "DownloadUrl", "ResultFileUrl"):
                    walk(v, depth + 1)
                elif isinstance(v, (dict, list)):
                    walk(v, depth + 1)
        elif isinstance(node, list):
            for v in node:
                walk(v, depth + 1)

    walk(payload)
    # 去重保序
    seen, out = set(), []
    for u in urls:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


def download(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=180) as resp, open(dest, "wb") as f:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    return os.path.getsize(dest)


def gen_one(name, prompt, token, dry=False, force=False):
    dest = os.path.join(OUT_DIR, name + ".glb")
    if os.path.exists(dest) and not force:
        print("  - %-8s 已存在，跳过（--force 可覆盖）" % name)
        return "skip"

    full = "%s, %s" % (prompt, STYLE)
    cmd = [
        PYTHON, SKILL_SCRIPT, "3d", full,
        "--model", "3.0",
        "--generate-type", "LowPoly",
        "--face-count", "10000",
        "--enable-pbr",
        "--token", token,
        "--max-poll-time", "600",
    ]
    print("  > %-8s 提交生成..." % name)
    if dry:
        run_cmd(cmd, dry=True)
        return "dry"

    t0 = time.time()
    res = run_cmd(cmd)
    if res is None or "__error__" in res:
        print("    × 失败: %s" % str(res.get("__error__", ""))[:300])
        return "fail"

    urls = collect_urls(res)
    glb_url = next((u for u in urls if u.lower().split("?")[0].endswith(".glb")), None)
    if not glb_url:
        print("    × 未找到 GLB 下载地址。返回内容：%s"
              % json.dumps(res, ensure_ascii=False)[:400])
        if urls:
            print("      可手动下载的链接：")
            for u in urls:
                print("        " + u)
        return "fail"

    try:
        size = download(glb_url, dest)
    except Exception as exc:
        print("    × 下载失败: %s\n      原始链接: %s" % (exc, glb_url))
        return "fail"

    print("    ✓ 完成 %s (%.1f KB, 用时 %ds)"
          % (dest, size / 1024.0, int(time.time() - t0)))
    return "ok"


def main():
    ap = argparse.ArgumentParser(description="批量生成武器 GLB 素材")
    ap.add_argument("--token", default="", help="临时凭据 ck_t_xxx")
    ap.add_argument("--only", nargs="*", default=None, help="只生成指定型号")
    ap.add_argument("--all", action="store_true", help="生成全部 17 把（默认只补缺失的）")
    ap.add_argument("--force", action="store_true", help="覆盖已存在的文件")
    ap.add_argument("--dry-run", action="store_true", help="只打印命令，不实际生成")
    ap.add_argument("--list", action="store_true", help="列出清单后退出")
    args = ap.parse_args()

    names = list(WEAPONS.keys())
    if args.only:
        names = [n for n in names if n in args.only]
        unknown = [n for n in args.only if n not in WEAPONS]
        if unknown:
            print("未知型号: %s" % "、".join(unknown))
            return 1
    elif not args.all:
        names = [n for n in names
                 if not os.path.exists(os.path.join(OUT_DIR, n + ".glb"))]
        if not names:
            print("models/fpv/ 下 17 把武器已齐全，无需生成。用 --all 可全部重生成。")
            return 0

    if args.list:
        for n in names:
            print("%-8s -> models/fpv/%s.glb" % (n, n))
        return 0

    if not args.token and not args.dry_run:
        print("缺少 --token（临时凭据）。请先获取凭据后再运行。")
        return 1
    if not os.path.isfile(SKILL_SCRIPT):
        print("找不到生成脚本: %s" % SKILL_SCRIPT)
        return 1

    os.makedirs(OUT_DIR, exist_ok=True)
    print("将生成 %d 个模型 -> %s\n" % (len(names), OUT_DIR))
    stats = {"ok": 0, "fail": 0, "skip": 0, "dry": 0}
    for i, n in enumerate(names, 1):
        print("[%d/%d] %s" % (i, len(names), n))
        stats[gen_one(n, WEAPONS[n], args.token, args.dry_run, args.force)] += 1

    print("\n完成: 成功 %d | 失败 %d | 跳过 %d" % (stats["ok"], stats["fail"], stats["skip"]))
    print("接着运行自检: python tools/glb_check.py")
    return 0 if stats["fail"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
