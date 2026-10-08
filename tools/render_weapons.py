# -*- coding: utf-8 -*-
"""
武器素材预览渲染器 —— 把 models/fpv/*.glb 排成目录图渲染成 PNG。

用法：
    blender --background --factory-startup --python tools/render_weapons.py
    blender --background --factory-startup --python tools/render_weapons.py -- --out screenshots/x.png
    blender --background --factory-startup --python tools/render_weapons.py -- --hero AK47 AWP M249

实现要点：后台模式下 object.matrix_world 不会随 rotation/scale 刷新，
所以这里把「缩放 + 旋转 + 平移」直接烘进网格顶点，物体本身保持单位变换，
渲染结果与 depsgraph 状态无关。
"""

import bpy
import math
import os
import sys
from mathutils import Vector, Matrix

D = math.radians

ORDER = ["Knife", "Glock", "USP", "Deagle", "MP5", "P90",
         "AK47", "M4A1", "Galil", "FAMAS", "AUG", "SG552",
         "Scout", "SG550", "G3SG1", "AWP", "M249"]

COLS = 6
COL_GAP = 1.20
ROW_GAP = 0.55
TARGET_LEN = 0.95


def clear():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for blk in (bpy.data.meshes, bpy.data.materials, bpy.data.curves):
        for b in list(blk):
            if b.users == 0:
                blk.remove(b)


def import_glb(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in new if o.type == "MESH"]
    if not meshes:
        return None
    if len(meshes) > 1:
        bpy.ops.object.select_all(action="DESELECT")
        for o in meshes:
            o.select_set(True)
        bpy.context.view_layer.objects.active = meshes[0]
        bpy.ops.object.join()
        meshes = [bpy.context.active_object]
    obj = meshes[0]
    obj.parent = None
    # 烘焙导入时可能带的变换
    obj.data.transform(obj.matrix_basis)
    obj.matrix_basis = Matrix.Identity(4)
    return obj


def bake_place(obj, target_len, world_pos, rot_z_deg=0.0):
    """把缩放/旋转/平移直接写进顶点，返回 (尺寸, 中心)。"""
    vs = obj.data.vertices
    if not len(vs):
        return (0, 0, 0), (0, 0, 0)
    lo = Vector((min(v.co.x for v in vs), min(v.co.y for v in vs), min(v.co.z for v in vs)))
    hi = Vector((max(v.co.x for v in vs), max(v.co.y for v in vs), max(v.co.z for v in vs)))
    size = hi - lo
    length = max(size.x, size.y, size.z)
    s = target_len / length if length > 1e-9 else 1.0
    center = (lo + hi) / 2.0
    R = Matrix.Rotation(D(rot_z_deg), 4, "Z")
    tgt = Vector(world_pos)
    for v in vs:
        v.co = (R @ ((v.co - center) * s)) + tgt
    obj.data.update()

    lo2 = Vector((min(v.co.x for v in vs), min(v.co.y for v in vs), min(v.co.z for v in vs)))
    hi2 = Vector((max(v.co.x for v in vs), max(v.co.y for v in vs), max(v.co.z for v in vs)))
    return tuple(hi2 - lo2), tuple((lo2 + hi2) / 2.0)


def add_label(text, loc, size=0.13):
    bpy.ops.object.text_add(location=loc)
    t = bpy.context.active_object
    t.data.body = text
    t.data.size = size
    t.data.align_x = "CENTER"
    t.data.align_y = "CENTER"
    t.rotation_euler = (D(90), 0, 0)
    m = bpy.data.materials.new("lbl_%s" % text)
    m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    if b:
        b.inputs["Base Color"].default_value = (0.04, 0.04, 0.05, 1)
        b.inputs["Roughness"].default_value = 0.95
        b.inputs["Metallic"].default_value = 0.0
    t.data.materials.append(m)
    return t


def setup_world(bg=0.74):
    w = bpy.data.worlds.new("W")
    bpy.context.scene.world = w
    w.use_nodes = True
    n = w.node_tree.nodes.get("Background")
    if n:
        n.inputs[0].default_value = (bg, bg, min(1.0, bg * 1.03), 1)
        n.inputs[1].default_value = 1.1


def setup_lights():
    for name, loc, rot, energy in (
        ("key", (2.5, -4.5, 4.0), (D(48), 0, D(30)), 4.5),
        ("fill", (-4.0, -3.5, 1.6), (D(74), 0, D(-40)), 2.0),
        ("rim", (0.5, 4.5, 2.6), (D(108), 0, D(186)), 2.4),
    ):
        d = bpy.data.lights.new(name, "SUN")
        d.energy = energy
        d.angle = D(14)
        o = bpy.data.objects.new(name, d)
        o.location = loc
        o.rotation_euler = rot
        bpy.context.collection.objects.link(o)


def set_engine(scene):
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        try:
            scene.render.engine = eng
            return eng
        except TypeError:
            continue
    return scene.render.engine


def do_render(out_path, res_x, res_y, ortho, cam_loc, cam_rot, bg):
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = ortho
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = cam_loc
    cam.rotation_euler = cam_rot
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam

    setup_world(bg)
    setup_lights()

    scene = bpy.context.scene
    eng = set_engine(scene)
    scene.render.resolution_x = res_x
    scene.render.resolution_y = res_y
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = out_path
    try:
        scene.view_settings.view_transform = "Standard"
    except Exception:
        pass
    bpy.ops.render.render(write_still=True)
    print("渲染引擎: %s" % eng)
    print("已输出: %s" % out_path)


def render_catalog(out_path, normalize=True):
    clear()
    src = os.path.join(os.getcwd(), "models", "fpv")
    names = [n for n in ORDER if os.path.exists(os.path.join(src, n + ".glb"))]
    if not names:
        print("找不到任何 GLB，检查 models/fpv/")
        return

    rows = (len(names) + COLS - 1) // COLS
    for i, name in enumerate(names):
        obj = import_glb(os.path.join(src, name + ".glb"))
        if obj is None:
            continue
        col, row = i % COLS, i // COLS
        x = (col - (COLS - 1) / 2.0) * COL_GAP
        z = -(row - (rows - 1) / 2.0) * ROW_GAP
        # 真实比例模式下保持原尺寸；归一化模式下统一拉到 TARGET_LEN
        target = TARGET_LEN
        if not normalize:
            vs = obj.data.vertices
            target = max(
                max(v.co.x for v in vs) - min(v.co.x for v in vs),
                max(v.co.y for v in vs) - min(v.co.y for v in vs),
                max(v.co.z for v in vs) - min(v.co.z for v in vs))
        size, center = bake_place(obj, target, (x, 0.0, z), -90.0)
        add_label(name, (x, 0.0, z - ROW_GAP * 0.40), 0.13)
        print("  %-8s %.2f x %.2f x %.2f" % (name, size[0], size[1], size[2]))

    do_render(out_path,
              res_x=2400, res_y=1080,
              ortho=COLS * COL_GAP,
              cam_loc=(0.0, -10.0, 0.0),
              cam_rot=(D(90), 0, 0),
              bg=0.74)


def render_hero(out_path, names, real_scale=True):
    clear()
    src = os.path.join(os.getcwd(), "models", "fpv")
    names = [n for n in names if os.path.exists(os.path.join(src, n + ".glb"))]
    if not names:
        names = ["AK47"]

    gap = 1.35
    for i, name in enumerate(names):
        obj = import_glb(os.path.join(src, name + ".glb"))
        if obj is None:
            continue
        x = (i - (len(names) - 1) / 2.0) * gap
        # real_scale=True 时按真实尺寸摆放（保持相互比例），否则归一化
        target = 1.15
        if real_scale:
            vs = obj.data.vertices
            span = max(
                max(v.co.x for v in vs) - min(v.co.x for v in vs),
                max(v.co.y for v in vs) - min(v.co.y for v in vs),
                max(v.co.z for v in vs) - min(v.co.z for v in vs))
            target = span
        bake_place(obj, target, (x, 0.0, 0.0), -90.0)
        add_label(name, (x, 0.0, -0.42), 0.11)

    # 俯角 15°：从 (0,-10,h) 看向原点 → h = 10*cos(75°)/sin(75°)
    rx = 75.0
    h = 10.0 * math.cos(D(rx)) / math.sin(D(rx))
    do_render(out_path,
              res_x=2400, res_y=1100,
              ortho=len(names) * gap + 0.5,
              cam_loc=(0.0, -10.0, h),
              cam_rot=(D(rx), 0, 0),
              bg=0.72)


def main():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    out = os.path.join(os.getcwd(), "screenshots", "weapons_preview.png")
    hero = []
    both = False
    i = 0
    while i < len(argv):
        if argv[i] == "--out" and i + 1 < len(argv):
            out = argv[i + 1]
            i += 2
        elif argv[i] == "--hero":
            i += 1
            while i < len(argv) and not argv[i].startswith("--"):
                hero.append(argv[i])
                i += 1
        elif argv[i] == "--both":
            both = True
            i += 1
        else:
            i += 1
    if not os.path.isabs(out):
        out = os.path.join(os.getcwd(), out)
    os.makedirs(os.path.dirname(out), exist_ok=True)

    if hero:
        render_hero(out, hero)
    elif both:
        root, ext = os.path.splitext(out)
        render_catalog(root + "_归一化" + ext, normalize=True)
        render_catalog(root + "_真实比例" + ext, normalize=False)
    else:
        render_catalog(out)


if __name__ == "__main__":
    main()
