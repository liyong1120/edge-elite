# -*- coding: utf-8 -*-
"""
武器参数化建模器（Blender 5.x headless）

用法：
    blender --background --python tools/build_weapons.py -- --out models/fpv
    blender --background --python tools/build_weapons.py -- --only AK47 MP5
    blender --background --python tools/build_weapons.py -- --all --out models/fpv

坐标系（Blender 内）：X = 左右，Y = 枪长（枪口朝 +Y），Z = 上下
导出 glTF 时 Blender 自动转成 Y-up，+Y 映射为 -Z —— 即 **枪口朝 -Z**，符合规格。

原点放在握把位置，材质命名 mat_{型号}_{部位}，UV 用 Smart Project 展开。
"""

import bpy
import bmesh
import math
import os
import sys
from mathutils import Vector, Euler

D = math.radians

# ------------------------------------------------------------------ 材质库
# key -> (base_color, metallic, roughness)
MATLIB = {
    "metal_dark":   ((0.070, 0.070, 0.080), 0.90, 0.42),
    "metal_grey":   ((0.220, 0.230, 0.250), 0.90, 0.35),
    "metal_steel":  ((0.520, 0.540, 0.570), 1.00, 0.28),
    "metal_silver": ((0.780, 0.790, 0.800), 1.00, 0.22),
    "metal_black":  ((0.035, 0.035, 0.040), 0.75, 0.45),
    "wood":         ((0.300, 0.170, 0.070), 0.00, 0.55),
    "wood_dark":    ((0.210, 0.115, 0.048), 0.00, 0.60),
    "polymer":      ((0.048, 0.048, 0.058), 0.00, 0.70),
    "polymer_od":   ((0.145, 0.175, 0.105), 0.00, 0.68),
    "polymer_tan":  ((0.400, 0.340, 0.225), 0.00, 0.68),
    "rubber":       ((0.028, 0.028, 0.030), 0.00, 0.90),
    "lens":         ((0.055, 0.095, 0.135), 0.60, 0.06),
    "brass":        ((0.540, 0.410, 0.135), 1.00, 0.30),
    # --- 第一人称手臂（握枪用）---
    # 袖管颜色在游戏里会按阵营重新染色（CT 深蓝 / T 土棕），这里只是中性底色
    "glove":        ((0.045, 0.045, 0.050), 0.00, 0.72),
    "sleeve":       ((0.085, 0.095, 0.130), 0.00, 0.78),
}


def make_material(wid, key):
    name = "mat_%s_%s" % (wid.lower(), key)
    m = bpy.data.materials.get(name)
    if m:
        return m
    color, metallic, rough = MATLIB[key]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
        bsdf.inputs["Metallic"].default_value = metallic
        bsdf.inputs["Roughness"].default_value = rough
    m.diffuse_color = (color[0], color[1], color[2], 1.0)
    return m


# ------------------------------------------------------------------ 几何构件
def add_box(size, loc, rot=(0, 0, 0), material=None):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc)
    o = bpy.context.active_object
    o.scale = size
    o.rotation_euler = Euler([D(a) for a in rot], "XYZ")
    if material:
        o.data.materials.append(material)
    return o


def add_cyl(radius, depth, loc, rot=(0, 0, 0), verts=10, material=None, scale=(1, 1, 1)):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=verts, radius=radius, depth=depth, location=loc)
    o = bpy.context.active_object
    o.rotation_euler = Euler([D(a) for a in rot], "XYZ")
    o.scale = scale
    if material:
        o.data.materials.append(material)
    return o


def tube(y0, y1, r, z=0.012, x=0.0, mat="metal_grey", verts=10):
    """沿 Y 轴的圆柱（枪管、瞄准镜筒等）。"""
    return ("cyl", r, abs(y1 - y0), (x, (y0 + y1) / 2.0, z), (90, 0, 0), verts, mat)


def scope(y, z, length, r, mat="metal_dark"):
    """瞄准镜组件：镜筒 + 前后镜片 + 两个镜座。"""
    return [
        ("cyl", r, length, (0, y, z), (90, 0, 0), 12, mat),
        ("cyl", r * 0.72, 0.012, (0, y - length / 2 - 0.004, z), (90, 0, 0), 12, "lens"),
        ("cyl", r * 0.72, 0.012, (0, y + length / 2 + 0.004, z), (90, 0, 0), 12, "lens"),
        ("box", (0.016, 0.018, 0.030), (0, y - length * 0.28, z - r - 0.014), (0, 0, 0), mat),
        ("box", (0.016, 0.018, 0.030), (0, y + length * 0.28, z - r - 0.014), (0, 0, 0), mat),
    ]


def iron_sights(y_front, y_rear, z, mat="metal_dark"):
    return [
        ("box", (0.010, 0.014, 0.030), (0, y_front, z + 0.014), (0, 0, 0), mat),
        ("box", (0.020, 0.022, 0.014), (0, y_rear, z + 0.008), (0, 0, 0), mat),
    ]


def mag_straight(y, z, w, h, d, mat="metal_dark", tilt=0.0):
    return [("box", (w, d, h), (0, y, z), (tilt, 0, 0), mat)]


def mag_curved(y, z, w, mat="metal_dark", scale=1.0):
    """弧形弹匣：两段盒子模拟香蕉形。"""
    return [
        ("box", (w, 0.048 * scale, 0.058 * scale), (0, y, z), (10, 0, 0), mat),
        ("box", (w * 0.94, 0.046 * scale, 0.070 * scale),
         (0, y + 0.030 * scale, z - 0.056 * scale), (26, 0, 0), mat),
    ]


def grip(y, z, h=0.10, tilt=16.0, mat="polymer"):
    return [("box", (0.032, 0.046, h), (0, y, z), (tilt, 0, 0), mat)]


def trigger_guard(y, z, mat="metal_dark"):
    return [
        ("box", (0.013, 0.052, 0.007), (0, y, z - 0.036), (0, 0, 0), mat),
        ("box", (0.013, 0.007, 0.030), (0, y - 0.024, z - 0.020), (0, 0, 0), mat),
        ("box", (0.011, 0.008, 0.024), (0, y + 0.014, z - 0.016), (0, 0, 0), mat),
    ]


def stock_block(y, z, length, mat="wood"):
    return [("box", (0.034, length, 0.055), (0, y, z), (0, 0, 0), mat)]


def rail(y, z, length, mat="metal_dark"):
    return [("box", (0.021, length, 0.010), (0, y, z), (0, 0, 0), mat)]


def arms(support):
    """生成两只握枪的手臂（第一人称用）。
    武器原点就在握把上，所以右手直接放在原点；左手放在 support 处。
    +Y 是枪口方向，所以「向后」是 -Y、「向下」是 -Z。
    小臂要足够长，才能从画面底部伸出去 —— 太短会变成几个悬空的方块。
    support 为 None 时只生成右手（小刀这类单手武器）。"""
    def forearm(sx, sy, sz, mirror):
        """三段小臂，越往后越粗，形成锥形。mirror=+1 右手 / -1 左手。
        粗细要克制：太粗会比武器本身还抢眼（第一人称里手臂离相机很近，透视会放大它）。"""
        return [
            ("box", (0.038, 0.140, 0.038), (sx + 0.024 * mirror, sy - 0.100, sz - 0.050),
             (-28, 0, -8 * mirror), "sleeve"),
            ("box", (0.050, 0.125, 0.050), (sx + 0.066 * mirror, sy - 0.216, sz - 0.114),
             (-34, 0, -12 * mirror), "sleeve"),
            ("box", (0.062, 0.110, 0.062), (sx + 0.112 * mirror, sy - 0.322, sz - 0.178),
             (-38, 0, -15 * mirror), "sleeve"),
        ]

    parts = [
        # 右手掌（包住握把）
        ("box", (0.040, 0.072, 0.052), (0.004, 0.004, -0.008), (6, 0, 0), "glove"),
        # 右手拇指 / 虎口
        ("box", (0.019, 0.038, 0.031), (-0.023, 0.023, 0.011), (0, 0, 0), "glove"),
    ]
    parts += forearm(0.0, 0.0, 0.0, 1)
    if support is None:
        return parts
    sy = support[0]
    sz = support[1]
    parts += [
        # 左手掌（托住护木 / 前握把）
        ("box", (0.040, 0.068, 0.050), (0.000, sy, sz - 0.006), (0, 0, 0), "glove"),
        ("box", (0.019, 0.036, 0.030), (0.023, sy + 0.019, sz + 0.011), (0, 0, 0), "glove"),
    ]
    parts += forearm(0.0, sy, sz, -1)
    return parts


# ------------------------------------------------------------------ 武器定义
def w_knife():
    parts = [
        ("box", (0.004, 0.150, 0.028), (0, 0.075, 0.004), (0, 0, 0), "metal_silver"),
        ("box", (0.004, 0.045, 0.014), (0, 0.018, 0.022), (0, 0, 0), "metal_silver"),
        ("box", (0.018, 0.100, 0.026), (0, -0.070, 0.0), (0, 0, 0), "rubber"),
        ("box", (0.022, 0.010, 0.032), (0, -0.014, 0.0), (0, 0, 0), "metal_dark"),
        ("box", (0.022, 0.010, 0.030), (0, -0.126, 0.0), (0, 0, 0), "metal_dark"),
        ("cyl", 0.010, 0.014, (0, -0.132, -0.006), (90, 0, 0), 8, "metal_dark"),
    ]
    return parts, (0.0, -0.070, 0.0)


def w_glock():
    parts = [
        ("box", (0.030, 0.170, 0.028), (0, 0.030, 0.020), (0, 0, 0), "metal_dark"),
        ("box", (0.028, 0.150, 0.014), (0, 0.020, -0.002), (0, 0, 0), "polymer"),
        ("box", (0.028, 0.048, 0.098), (0, -0.058, -0.052), (12, 0, 0), "polymer"),
        ("box", (0.020, 0.030, 0.018), (0, -0.070, -0.108), (12, 0, 0), "polymer"),
        ("box", (0.012, 0.048, 0.008), (0, -0.012, -0.030), (0, 0, 0), "polymer"),
        ("box", (0.012, 0.007, 0.024), (0, -0.034, -0.018), (0, 0, 0), "polymer"),
        ("box", (0.010, 0.014, 0.010), (0, 0.112, 0.040), (0, 0, 0), "metal_dark"),
        ("box", (0.020, 0.020, 0.008), (0, -0.045, 0.036), (0, 0, 0), "metal_dark"),
        ("cyl", 0.006, 0.020, (0, 0.122, 0.022), (90, 0, 0), 8, "metal_grey"),
    ]
    return parts, (0.0, -0.070, -0.060)


def w_usp():
    parts = [
        ("box", (0.030, 0.168, 0.030), (0, 0.030, 0.020), (0, 0, 0), "metal_grey"),
        ("box", (0.028, 0.146, 0.014), (0, 0.020, -0.004), (0, 0, 0), "polymer"),
        ("box", (0.028, 0.048, 0.096), (0, -0.056, -0.052), (12, 0, 0), "polymer"),
        ("box", (0.012, 0.048, 0.008), (0, -0.012, -0.030), (0, 0, 0), "polymer"),
        ("box", (0.012, 0.007, 0.024), (0, -0.032, -0.018), (0, 0, 0), "polymer"),
        ("box", (0.010, 0.014, 0.010), (0, 0.110, 0.042), (0, 0, 0), "metal_grey"),
        ("box", (0.020, 0.020, 0.008), (0, -0.044, 0.036), (0, 0, 0), "metal_grey"),
        # 消音器
        ("cyl", 0.017, 0.118, (0, 0.168, 0.022), (90, 0, 0), 12, "metal_black"),
        ("cyl", 0.013, 0.014, (0, 0.106, 0.022), (90, 0, 0), 10, "metal_grey"),
    ]
    return parts, (0.0, -0.068, -0.060)


def w_deagle():
    parts = [
        ("box", (0.036, 0.185, 0.040), (0, 0.028, 0.024), (0, 0, 0), "metal_silver"),
        ("box", (0.030, 0.090, 0.018), (0, 0.062, 0.048), (0, 0, 0), "metal_silver"),
        ("box", (0.034, 0.150, 0.016), (0, 0.014, -0.004), (0, 0, 0), "metal_dark"),
        ("box", (0.032, 0.052, 0.100), (0, -0.062, -0.056), (10, 0, 0), "polymer"),
        ("box", (0.012, 0.050, 0.008), (0, -0.016, -0.032), (0, 0, 0), "metal_dark"),
        ("box", (0.012, 0.007, 0.026), (0, -0.040, -0.020), (0, 0, 0), "metal_dark"),
        ("box", (0.010, 0.016, 0.012), (0, 0.118, 0.048), (0, 0, 0), "metal_dark"),
        ("box", (0.020, 0.020, 0.010), (0, -0.048, 0.042), (0, 0, 0), "metal_dark"),
        ("cyl", 0.010, 0.026, (0, 0.128, 0.024), (90, 0, 0), 10, "metal_silver"),
        ("box", (0.008, 0.100, 0.006), (0, 0.060, 0.058), (0, 0, 0), "metal_dark"),
    ]
    return parts, (0.0, -0.072, -0.066)


def w_mp5():
    parts = [
        ("cyl", 0.022, 0.310, (0, 0.155, 0.030), (90, 0, 0), 12, "metal_dark"),
        ("box", (0.040, 0.120, 0.052), (0, -0.020, 0.010), (0, 0, 0), "metal_dark"),
        ("box", (0.038, 0.120, 0.040), (0, -0.125, -0.004), (0, 0, 0), "polymer"),
        ("box", (0.034, 0.080, 0.034), (0, -0.225, -0.010), (0, 0, 0), "polymer"),
        ("box", (0.020, 0.014, 0.048), (0, -0.272, -0.012), (0, 0, 0), "rubber"),
        ("box", (0.036, 0.150, 0.042), (0, 0.170, 0.004), (0, 0, 0), "polymer"),
        ("box", (0.032, 0.030, 0.012), (0, 0.315, 0.026), (0, 0, 0), "polymer"),
        ("box", (0.034, 0.048, 0.096), (0, -0.028, -0.078), (12, 0, 0), "polymer"),
        ("box", (0.036, 0.046, 0.062), (0, -0.010, -0.146), (24, 0, 0), "polymer"),
        ("box", (0.013, 0.052, 0.007), (0, -0.062, -0.040), (0, 0, 0), "metal_dark"),
        ("box", (0.013, 0.007, 0.030), (0, -0.086, -0.024), (0, 0, 0), "metal_dark"),
        ("box", (0.010, 0.016, 0.030), (0, 0.222, 0.062), (0, 0, 0), "metal_dark"),
        ("box", (0.020, 0.024, 0.014), (0, -0.048, 0.048), (0, 0, 0), "metal_dark"),
        ("box", (0.021, 0.110, 0.010), (0, 0.115, 0.062), (0, 0, 0), "metal_dark"),
    ]
    return parts, (0.0, -0.028, -0.070)


def w_p90():
    parts = [
        # 主体上壳
        ("box", (0.050, 0.300, 0.052), (0, 0.055, 0.030), (0, 0, 0), "polymer"),
        # 顶部横置弹匣（P90 的标志性特征）
        ("box", (0.048, 0.170, 0.028), (0, 0.020, 0.070), (0, 0, 0), "polymer"),
        ("box", (0.044, 0.030, 0.020), (0, 0.112, 0.070), (0, 0, 0), "metal_dark"),
        # 下机匣
        ("box", (0.044, 0.170, 0.048), (0, -0.040, -0.024), (0, 0, 0), "polymer"),
        # 后托（与下机匣之间形成握孔）
        ("box", (0.042, 0.036, 0.082), (0, -0.150, 0.006), (0, 0, 0), "polymer"),
        ("box", (0.040, 0.014, 0.092), (0, -0.172, 0.006), (0, 0, 0), "rubber"),
        # 前垂直握把
        ("box", (0.030, 0.034, 0.058), (0, 0.078, -0.030), (0, 0, 0), "polymer"),
        # 枪管 / 枪口
        ("cyl", 0.011, 0.110, (0, 0.250, 0.030), (90, 0, 0), 10, "metal_dark"),
        ("cyl", 0.013, 0.020, (0, 0.308, 0.030), (90, 0, 0), 10, "metal_dark"),
        # 前护圈 / 准星
        ("box", (0.034, 0.040, 0.030), (0, 0.205, 0.048), (0, 0, 0), "polymer"),
        ("box", (0.010, 0.014, 0.024), (0, 0.288, 0.052), (0, 0, 0), "metal_dark"),
        # 光学瞄具
        ("box", (0.020, 0.090, 0.024), (0, 0.050, 0.096), (0, 0, 0), "metal_dark"),
        ("cyl", 0.008, 0.012, (0, 0.098, 0.096), (90, 0, 0), 8, "lens"),
        # 扳机 / 挂带环
        ("box", (0.010, 0.010, 0.026), (0, 0.020, -0.042), (0, 0, 0), "metal_dark"),
        ("cyl", 0.005, 0.018, (0, 0.150, -0.038), (0, 0, 0), 6, "metal_dark"),
    ]
    return parts, (0.0, 0.020, -0.042)


def w_ak47():
    parts = [
        ("box", (0.036, 0.270, 0.062), (0, 0.055, 0.0), (0, 0, 0), "metal_dark"),
        ("box", (0.032, 0.160, 0.022), (0, 0.070, 0.042), (0, 0, 0), "metal_dark"),
        tube(0.180, 0.430, 0.0085, z=0.014, mat="metal_grey"),
        tube(0.180, 0.350, 0.0075, z=0.048, mat="metal_grey", verts=8),
        ("cyl", 0.0135, 0.058, (0, 0.452, 0.014), (90, 0, 0), 10, "metal_dark"),
        ("box", (0.012, 0.020, 0.038), (0, 0.404, 0.048), (0, 0, 0), "metal_dark"),
        ("box", (0.022, 0.030, 0.018), (0, 0.130, 0.062), (0, 0, 0), "metal_dark"),
        ("box", (0.042, 0.150, 0.028), (0, 0.222, 0.046), (0, 0, 0), "wood"),
        ("box", (0.044, 0.150, 0.034), (0, 0.222, 0.012), (0, 0, 0), "wood"),
        ("box", (0.034, 0.050, 0.062), (0, 0.010, -0.062), (10, 0, 0), "metal_dark"),
        ("box", (0.032, 0.046, 0.072), (0, 0.042, -0.126), (28, 0, 0), "metal_dark"),
        ("box", (0.033, 0.048, 0.104), (0, -0.086, -0.082), (16, 0, 0), "wood_dark"),
        ("box", (0.014, 0.056, 0.008), (0, -0.032, -0.048), (0, 0, 0), "metal_dark"),
        ("box", (0.014, 0.008, 0.032), (0, -0.058, -0.030), (0, 0, 0), "metal_dark"),
        ("box", (0.036, 0.205, 0.056), (0, -0.245, -0.022), (0, 0, 0), "wood"),
        ("box", (0.038, 0.014, 0.078), (0, -0.352, -0.022), (0, 0, 0), "metal_dark"),
        ("box", (0.010, 0.070, 0.014), (0.020, 0.130, 0.028), (0, 0, 0), "metal_dark"),
        ("cyl", 0.005, 0.020, (0, 0.300, -0.014), (90, 0, 0), 6, "metal_dark"),
    ]
    return parts, (0.0, -0.086, -0.082)


def w_m4a1():
    parts = [
        ("box", (0.034, 0.200, 0.058), (0, 0.030, 0.010), (0, 0, 0), "metal_black"),
        ("box", (0.030, 0.230, 0.026), (0, 0.048, 0.052), (0, 0, 0), "metal_black"),
        ("box", (0.024, 0.070, 0.030), (0, -0.080, 0.048), (0, 0, 0), "metal_black"),
        ("box", (0.020, 0.026, 0.022), (0, -0.120, 0.056), (0, 0, 0), "metal_black"),
        tube(0.150, 0.395, 0.0080, z=0.016, mat="metal_grey"),
        ("cyl", 0.0110, 0.020, (0, 0.398, 0.016), (90, 0, 0), 10, "metal_dark"),
        ("box", (0.012, 0.018, 0.034), (0, 0.360, 0.042), (0, 0, 0), "metal_black"),
        ("cyl", 0.020, 0.170, (0, 0.300, 0.016), (90, 0, 0), 12, "metal_black"),
        ("box", (0.038, 0.130, 0.038), (0, 0.240, 0.016), (0, 0, 0), "polymer"),
        ("box", (0.021, 0.110, 0.010), (0, 0.250, 0.044), (0, 0, 0), "metal_black"),
        ("box", (0.034, 0.050, 0.056), (0, -0.020, -0.052), (8, 0, 0), "metal_black"),
        ("box", (0.032, 0.046, 0.078), (0, 0.006, -0.114), (22, 0, 0), "metal_black"),
        ("box", (0.033, 0.048, 0.098), (0, -0.096, -0.080), (16, 0, 0), "polymer"),
        ("box", (0.014, 0.054, 0.008), (0, -0.046, -0.046), (0, 0, 0), "metal_black"),
        ("cyl", 0.017, 0.190, (0, -0.235, 0.006), (90, 0, 0), 10, "polymer"),
        ("box", (0.036, 0.014, 0.062), (0, -0.335, 0.004), (0, 0, 0), "polymer"),
        ("box", (0.016, 0.036, 0.040), (0, -0.160, -0.010), (0, 0, 0), "polymer"),
        ("cyl", 0.005, 0.020, (0, 0.280, -0.020), (90, 0, 0), 6, "metal_dark"),
    ]
    return parts, (0.0, -0.096, -0.080)


def w_galil():
    parts = [
        ("box", (0.036, 0.240, 0.060), (0, 0.045, 0.0), (0, 0, 0), "metal_dark"),
        ("box", (0.030, 0.140, 0.022), (0, 0.060, 0.042), (0, 0, 0), "metal_dark"),
        tube(0.160, 0.380, 0.0085, z=0.014, mat="metal_grey"),
        ("cyl", 0.0130, 0.052, (0, 0.402, 0.014), (90, 0, 0), 10, "metal_dark"),
        ("box", (0.012, 0.020, 0.036), (0, 0.356, 0.046), (0, 0, 0), "metal_dark"),
        ("box", (0.022, 0.028, 0.016), (0, 0.120, 0.060), (0, 0, 0), "metal_dark"),
        ("box", (0.040, 0.120, 0.028), (0, 0.190, 0.044), (0, 0, 0), "wood"),
        ("box", (0.042, 0.120, 0.032), (0, 0.190, 0.012), (0, 0, 0), "wood"),
        ("box", (0.032, 0.048, 0.062), (0, 0.010, -0.060), (10, 0, 0), "metal_dark"),
        ("box", (0.030, 0.044, 0.070), (0, 0.040, -0.122), (26, 0, 0), "metal_dark"),
        ("box", (0.033, 0.048, 0.102), (0, -0.084, -0.080), (16, 0, 0), "polymer"),
        ("box", (0.014, 0.054, 0.008), (0, -0.030, -0.046), (0, 0, 0), "metal_dark"),
        ("box", (0.034, 0.170, 0.050), (0, -0.220, -0.020), (0, 0, 0), "wood"),
        ("box", (0.016, 0.060, 0.040), (0, -0.310, -0.020), (0, 0, 0), "metal_dark"),
        ("box", (0.036, 0.014, 0.070), (0, -0.322, -0.020), (0, 0, 0), "metal_dark"),
        ("box", (0.010, 0.060, 0.014), (0.020, 0.110, 0.026), (0, 0, 0), "metal_dark"),
    ]
    return parts, (0.0, -0.084, -0.080)


def w_famas():
    parts = [
        # 无托主体：机匣一直延伸到肩托
        ("box", (0.038, 0.400, 0.064), (0, -0.030, 0.010), (0, 0, 0), "metal_black"),
        # 提把基座 + 提把 + 镜片
        ("box", (0.030, 0.080, 0.046), (0, 0.020, 0.062), (0, 0, 0), "metal_black"),
        ("box", (0.024, 0.170, 0.032), (0, 0.100, 0.078), (0, 0, 0), "metal_black"),
        ("cyl", 0.015, 0.030, (0, 0.030, 0.084), (90, 0, 0), 12, "lens"),
        # 枪管 / 枪口 / 准星
        tube(0.170, 0.420, 0.0085, z=0.014, mat="metal_grey"),
        ("cyl", 0.0125, 0.052, (0, 0.444, 0.014), (90, 0, 0), 10, "metal_dark"),
        ("box", (0.012, 0.018, 0.036), (0, 0.396, 0.042), (0, 0, 0), "metal_black"),
        # 护木（上/下）
        ("box", (0.040, 0.160, 0.034), (0, 0.210, 0.014), (0, 0, 0), "polymer"),
        ("box", (0.038, 0.130, 0.030), (0, 0.200, -0.028), (0, 0, 0), "polymer"),
        # 前握把
        ("box", (0.028, 0.030, 0.050), (0, 0.288, -0.032), (0, 0, 0), "polymer"),
        # 握把（在弹匣之前）
        ("box", (0.032, 0.048, 0.092), (0, -0.010, -0.088), (14, 0, 0), "polymer"),
        # 弹匣（无托结构：位于握把之后，向后下方倾斜）
        ("box", (0.030, 0.046, 0.100), (0, -0.100, -0.082), (16, 0, 0), "polymer"),
        ("box", (0.028, 0.042, 0.062), (0, -0.074, -0.160), (32, 0, 0), "polymer"),
        # 扳机护圈
        ("box", (0.014, 0.060, 0.008), (0, -0.050, -0.052), (0, 0, 0), "metal_black"),
        ("box", (0.014, 0.008, 0.032), (0, -0.080, -0.034), (0, 0, 0), "metal_black"),
        # 托底板
        ("box", (0.040, 0.018, 0.076), (0, -0.240, 0.010), (0, 0, 0), "rubber"),
        # 拉机柄
        ("box", (0.010, 0.070, 0.014), (0.021, 0.050, 0.032), (0, 0, 0), "metal_black"),
    ]
    return parts, (0.0, -0.010, -0.088)


def w_aug():
    parts = [
        ("box", (0.044, 0.300, 0.070), (0, 0.020, 0.006), (0, 0, 0), "polymer"),
        ("box", (0.030, 0.150, 0.028), (0, 0.010, 0.056), (0, 0, 0), "polymer"),
        ("cyl", 0.019, 0.150, (0, 0.020, 0.086), (90, 0, 0), 12, "polymer"),
        ("cyl", 0.015, 0.024, (0, -0.058, 0.086), (90, 0, 0), 12, "lens"),
        ("cyl", 0.015, 0.024, (0, 0.098, 0.086), (90, 0, 0), 12, "lens"),
        tube(0.170, 0.420, 0.0090, z=0.014, mat="metal_grey"),
        ("cyl", 0.0130, 0.052, (0, 0.442, 0.014), (90, 0, 0), 10, "metal_dark"),
        ("box", (0.012, 0.018, 0.034), (0, 0.396, 0.042), (0, 0, 0), "polymer"),
        ("box", (0.046, 0.140, 0.040), (0, 0.180, 0.008), (0, 0, 0), "polymer"),
        ("box", (0.032, 0.046, 0.096), (0, -0.010, -0.086), (12, 0, 0), "polymer"),
        ("box", (0.048, 0.140, 0.034), (0, 0.240, -0.036), (0, 0, 0), "polymer"),
        ("cyl", 0.014, 0.090, (0, 0.300, -0.036), (0, 0, 0), 10, "polymer"),
        ("box", (0.014, 0.054, 0.008), (0, -0.072, -0.052), (0, 0, 0), "polymer"),
        ("box", (0.040, 0.130, 0.046), (0, -0.190, -0.004), (0, 0, 0), "polymer"),
        ("box", (0.042, 0.016, 0.058), (0, -0.262, -0.004), (0, 0, 0), "rubber"),
        ("box", (0.010, 0.060, 0.014), (0.024, 0.030, 0.030), (0, 0, 0), "polymer"),
    ]
    return parts, (0.0, -0.010, -0.086)


def w_sg552():
    parts = [
        ("box", (0.038, 0.260, 0.064), (0, 0.020, 0.006), (0, 0, 0), "metal_black"),
        ("box", (0.021, 0.150, 0.010), (0, 0.060, 0.062), (0, 0, 0), "metal_black"),
        tube(0.150, 0.360, 0.0085, z=0.014, mat="metal_grey"),
        ("cyl", 0.0125, 0.048, (0, 0.382, 0.014), (90, 0, 0), 10, "metal_dark"),
        ("box", (0.012, 0.018, 0.034), (0, 0.338, 0.040), (0, 0, 0), "metal_black"),
        ("box", (0.040, 0.120, 0.034), (0, 0.160, 0.012), (0, 0, 0), "polymer"),
        ("box", (0.032, 0.046, 0.060), (0, -0.010, -0.058), (10, 0, 0), "metal_black"),
        ("box", (0.030, 0.044, 0.068), (0, 0.020, -0.118), (26, 0, 0), "metal_black"),
        ("box", (0.033, 0.048, 0.098), (0, -0.090, -0.078), (16, 0, 0), "polymer"),
        ("box", (0.014, 0.054, 0.008), (0, -0.040, -0.046), (0, 0, 0), "metal_black"),
        ("box", (0.036, 0.140, 0.048), (0, -0.215, -0.014), (0, 0, 0), "polymer"),
        ("box", (0.022, 0.020, 0.058), (0, -0.290, -0.014), (0, 0, 0), "rubber"),
        ("box", (0.010, 0.060, 0.014), (0.021, 0.070, 0.026), (0, 0, 0), "metal_black"),
        ("cyl", 0.005, 0.020, (0, 0.250, -0.020), (90, 0, 0), 6, "metal_dark"),
    ] + scope(0.060, 0.082, 0.150, 0.017, "metal_black")
    return parts, (0.0, -0.090, -0.078)


def w_scout():
    parts = [
        ("box", (0.036, 0.230, 0.062), (0, 0.010, 0.008), (0, 0, 0), "polymer_od"),
        ("box", (0.034, 0.170, 0.046), (0, -0.215, -0.004), (0, 0, 0), "polymer_od"),
        ("box", (0.034, 0.220, 0.052), (0, 0.200, 0.008), (0, 0, 0), "polymer_od"),
        tube(0.260, 0.690, 0.0090, z=0.016, mat="metal_dark"),
        ("cyl", 0.0125, 0.046, (0, 0.710, 0.016), (90, 0, 0), 10, "metal_dark"),
        ("box", (0.034, 0.048, 0.062), (0, -0.030, -0.056), (8, 0, 0), "polymer_od"),
        ("box", (0.032, 0.044, 0.070), (0, 0.000, -0.116), (24, 0, 0), "metal_dark"),
        ("box", (0.033, 0.048, 0.098), (0, -0.100, -0.078), (16, 0, 0), "polymer_od"),
        ("box", (0.014, 0.054, 0.008), (0, -0.050, -0.046), (0, 0, 0), "metal_dark"),
        ("box", (0.036, 0.014, 0.062), (0, -0.310, -0.006), (0, 0, 0), "rubber"),
        ("box", (0.010, 0.060, 0.014), (0.021, 0.060, 0.028), (0, 0, 0), "metal_dark"),
        ("box", (0.008, 0.050, 0.020), (0.0, 0.400, 0.036), (0, 0, 0), "metal_dark"),
    ] + scope(0.080, 0.086, 0.260, 0.019, "metal_dark")
    return parts, (0.0, -0.100, -0.078)


def w_sg550():
    parts = [
        ("box", (0.040, 0.280, 0.070), (0, 0.010, 0.006), (0, 0, 0), "metal_black"),
        ("box", (0.038, 0.160, 0.050), (0, 0.200, 0.010), (0, 0, 0), "polymer"),
        tube(0.290, 0.500, 0.0090, z=0.018, mat="metal_grey"),
        ("cyl", 0.0125, 0.048, (0, 0.522, 0.018), (90, 0, 0), 10, "metal_dark"),
        ("box", (0.036, 0.050, 0.064), (0, -0.040, -0.058), (8, 0, 0), "metal_black"),
        ("box", (0.034, 0.046, 0.072), (0, -0.010, -0.120), (24, 0, 0), "metal_black"),
        ("box", (0.034, 0.048, 0.100), (0, -0.110, -0.080), (16, 0, 0), "polymer"),
        ("box", (0.014, 0.054, 0.008), (0, -0.060, -0.048), (0, 0, 0), "metal_black"),
        ("box", (0.038, 0.150, 0.052), (0, -0.230, -0.010), (0, 0, 0), "polymer"),
        ("box", (0.038, 0.016, 0.070), (0, -0.312, -0.010), (0, 0, 0), "rubber"),
        ("box", (0.010, 0.060, 0.014), (0.022, 0.050, 0.030), (0, 0, 0), "metal_black"),
    ] + scope(0.040, 0.092, 0.240, 0.019, "metal_black")
    return parts, (0.0, -0.110, -0.080)


def w_g3sg1():
    parts = [
        ("box", (0.042, 0.320, 0.072), (0, 0.010, 0.006), (0, 0, 0), "metal_black"),
        ("box", (0.040, 0.180, 0.052), (0, 0.230, 0.010), (0, 0, 0), "polymer"),
        tube(0.330, 0.560, 0.0090, z=0.018, mat="metal_grey"),
        ("cyl", 0.0130, 0.050, (0, 0.582, 0.018), (90, 0, 0), 10, "metal_dark"),
        ("box", (0.038, 0.052, 0.066), (0, -0.050, -0.060), (8, 0, 0), "metal_black"),
        ("box", (0.036, 0.046, 0.074), (0, -0.020, -0.124), (24, 0, 0), "metal_black"),
        ("box", (0.036, 0.048, 0.102), (0, -0.120, -0.082), (16, 0, 0), "polymer"),
        ("box", (0.014, 0.054, 0.008), (0, -0.070, -0.050), (0, 0, 0), "metal_black"),
        ("box", (0.040, 0.170, 0.054), (0, -0.260, -0.010), (0, 0, 0), "polymer"),
        ("box", (0.040, 0.016, 0.072), (0, -0.352, -0.010), (0, 0, 0), "rubber"),
        ("box", (0.010, 0.060, 0.014), (0.023, 0.050, 0.032), (0, 0, 0), "metal_black"),
        ("cyl", 0.005, 0.020, (0, 0.420, -0.022), (90, 0, 0), 6, "metal_dark"),
    ] + scope(0.030, 0.094, 0.260, 0.020, "metal_black")
    return parts, (0.0, -0.120, -0.082)


def w_awp():
    parts = [
        ("box", (0.042, 0.340, 0.074), (0, 0.020, 0.008), (0, 0, 0), "polymer_od"),
        ("box", (0.040, 0.190, 0.056), (0, 0.250, 0.012), (0, 0, 0), "polymer_od"),
        tube(0.360, 0.580, 0.0095, z=0.020, mat="metal_dark"),
        ("cyl", 0.0135, 0.052, (0, 0.602, 0.020), (90, 0, 0), 10, "metal_dark"),
        ("box", (0.038, 0.052, 0.068), (0, -0.040, -0.062), (8, 0, 0), "polymer_od"),
        ("box", (0.036, 0.048, 0.076), (0, -0.010, -0.128), (24, 0, 0), "metal_dark"),
        ("box", (0.036, 0.048, 0.104), (0, -0.115, -0.084), (16, 0, 0), "polymer_od"),
        ("box", (0.014, 0.054, 0.008), (0, -0.062, -0.050), (0, 0, 0), "metal_dark"),
        ("box", (0.042, 0.200, 0.060), (0, -0.270, -0.006), (0, 0, 0), "polymer_od"),
        ("box", (0.042, 0.018, 0.080), (0, -0.378, -0.006), (0, 0, 0), "rubber"),
        ("box", (0.010, 0.060, 0.014), (0.024, 0.060, 0.034), (0, 0, 0), "metal_dark"),
        ("box", (0.006, 0.030, 0.030), (0, 0.480, 0.050), (0, 0, 0), "metal_dark"),
    ] + scope(0.040, 0.098, 0.280, 0.021, "metal_dark")
    return parts, (0.0, -0.115, -0.084)


def w_m249():
    parts = [
        ("box", (0.046, 0.330, 0.084), (0, 0.020, 0.014), (0, 0, 0), "metal_dark"),
        ("box", (0.030, 0.060, 0.040), (0, 0.180, 0.070), (0, 0, 0), "metal_dark"),
        tube(0.210, 0.520, 0.0105, z=0.020, mat="metal_grey"),
        ("cyl", 0.0150, 0.058, (0, 0.548, 0.020), (90, 0, 0), 10, "metal_dark"),
        ("box", (0.014, 0.020, 0.040), (0, 0.500, 0.056), (0, 0, 0), "metal_dark"),
        ("box", (0.048, 0.170, 0.050), (0, 0.290, 0.014), (0, 0, 0), "metal_dark"),
        ("box", (0.056, 0.170, 0.110), (0, 0.030, -0.098), (0, 0, 0), "metal_dark"),
        ("box", (0.052, 0.150, 0.014), (0, 0.030, -0.156), (0, 0, 0), "metal_dark"),
        ("box", (0.036, 0.050, 0.070), (0, -0.040, -0.062), (8, 0, 0), "polymer"),
        ("box", (0.034, 0.048, 0.100), (0, -0.120, -0.084), (16, 0, 0), "polymer"),
        ("box", (0.014, 0.054, 0.008), (0, -0.070, -0.050), (0, 0, 0), "metal_dark"),
        ("box", (0.042, 0.190, 0.062), (0, -0.270, -0.004), (0, 0, 0), "polymer"),
        ("box", (0.042, 0.018, 0.082), (0, -0.368, -0.004), (0, 0, 0), "rubber"),
        ("cyl", 0.007, 0.120, (0.028, 0.300, -0.020), (70, 0, 0), 8, "metal_dark"),
        ("cyl", 0.007, 0.120, (-0.028, 0.300, -0.020), (70, 0, 0), 8, "metal_dark"),
        ("box", (0.010, 0.060, 0.014), (0.026, 0.040, 0.036), (0, 0, 0), "metal_dark"),
        ("box", (0.006, 0.030, 0.028), (0, 0.430, 0.058), (0, 0, 0), "metal_dark"),
    ]
    return parts, (0.0, -0.120, -0.084)


WEAPONS = {
    # (构建函数, 规格全长, 左手托枪位置(相对握把原点的 y,z)；None=单手武器)
    "Knife": (w_knife, 0.30, None),
    "Glock": (w_glock, 0.20, (0.020, 0.010)),
    "USP": (w_usp, 0.33, (0.020, 0.010)),
    "Deagle": (w_deagle, 0.28, (0.020, 0.010)),
    "MP5": (w_mp5, 0.66, (0.198, 0.055)),
    "P90": (w_p90, 0.51, (0.058, 0.000)),
    "AK47": (w_ak47, 0.88, (0.308, 0.075)),
    "M4A1": (w_m4a1, 0.84, (0.336, 0.075)),
    "Galil": (w_galil, 0.78, (0.274, 0.070)),
    "FAMAS": (w_famas, 0.79, (0.210, 0.040)),
    "AUG": (w_aug, 0.82, (0.190, 0.072)),
    "SG552": (w_sg552, 0.75, (0.250, 0.068)),
    "Scout": (w_scout, 1.04, (0.300, 0.064)),
    "SG550": (w_sg550, 1.00, (0.310, 0.068)),
    "G3SG1": (w_g3sg1, 1.12, (0.350, 0.070)),
    "AWP": (w_awp, 1.14, (0.365, 0.074)),
    "M249": (w_m249, 1.05, (0.410, 0.076)),
}


# ------------------------------------------------------------------ 构建流程
def clear_scene():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for blk in (bpy.data.meshes, bpy.data.materials, bpy.data.images):
        for b in list(blk):
            if b.users == 0:
                blk.remove(b)


def _build_objects(parts, wid, name):
    """按部件列表建对象并合并成一个物体。"""
    objs = []
    for p in parts:
        if p[0] == "box":
            _, size, loc, rot, matkey = p
            o = add_box(size, loc, rot, make_material(wid, matkey))
        else:
            _, r, depth, loc, rot, verts, matkey = p
            o = add_cyl(r, depth, loc, rot, verts, make_material(wid, matkey))
        objs.append(o)
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    obj = bpy.context.active_object
    obj.name = name
    obj.data.name = "%s_mesh" % name
    # join 会把「第一个部件」的非均匀缩放/位移残留在 object 上，
    # 必须烘进网格，否则导出节点带脏变换（Godot 里再旋转会斜切）。
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return obj


def _shift_origin(obj, grip):
    """原点移到握把：直接平移顶点，让 object 保持单位变换。"""
    g = Vector(grip)
    for v in obj.data.vertices:
        v.co -= g
    obj.data.update()


def _uv_and_shade(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    try:
        bpy.ops.uv.smart_project(angle_limit=D(66.0), island_margin=0.02)
    except Exception:
        bpy.ops.uv.cube_project(cube_size=1.0)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.shade_flat()
    bpy.ops.object.material_slot_remove_unused()


def build_one(wid, out_dir):
    builder, target_len, support = WEAPONS[wid]
    clear_scene()
    parts, grip_pos = builder()

    obj = _build_objects(parts, wid, wid)
    _shift_origin(obj, grip_pos)
    _uv_and_shade(obj)

    # 手臂单独一个物体（不 join 进武器）：游戏里算包围盒时要跳过它，
    # 否则手臂会把包围盒撑大、把武器整体缩小、枪口位置也会算偏。
    arm_obj = None
    arm_parts = arms(support)
    if arm_parts:
        arm_obj = _build_objects(arm_parts, wid, "arms")
        _shift_origin(arm_obj, grip_pos)
        _uv_and_shade(arm_obj)

    bpy.context.view_layer.update()

    # 统计（只算武器本身，不含手臂）
    me = obj.data
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    bbox = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
    xs = [v.x for v in bbox]
    ys = [v.y for v in bbox]
    zs = [v.z for v in bbox]
    dims = (max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs))
    arm_tris = 0
    if arm_obj:
        arm_tris = sum(len(p.vertices) - 2 for p in arm_obj.data.polygons)

    path = os.path.join(out_dir, wid + ".glb")
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    if arm_obj:
        arm_obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    _export(path)

    return {"wid": wid, "tris": tris, "arm_tris": arm_tris, "dims": dims,
            "mats": len(me.materials), "target": target_len, "path": path}


def _export(path):
    kwargs = dict(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_materials="EXPORT",
    )
    try:
        bpy.ops.export_scene.gltf(**kwargs)
    except TypeError:
        for k in ("export_materials", "export_apply", "export_yup"):
            kwargs.pop(k, None)
        bpy.ops.export_scene.gltf(**kwargs)


def main():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []

    out_dir = "models/fpv"
    only = []
    do_all = False
    i = 0
    while i < len(argv):
        if argv[i] == "--out" and i + 1 < len(argv):
            out_dir = argv[i + 1]
            i += 2
        elif argv[i] == "--only":
            i += 1
            while i < len(argv) and not argv[i].startswith("--"):
                only.append(argv[i])
                i += 1
        elif argv[i] == "--all":
            do_all = True
            i += 1
        else:
            i += 1

    root = os.getcwd()
    out_dir = out_dir if os.path.isabs(out_dir) else os.path.join(root, out_dir)
    os.makedirs(out_dir, exist_ok=True)

    if only:
        names = [n for n in only if n in WEAPONS]
        bad = [n for n in only if n not in WEAPONS]
        if bad:
            print("[WARN] 未知型号: %s" % "、".join(bad))
    elif do_all:
        names = list(WEAPONS.keys())
    else:
        names = [n for n in WEAPONS
                 if not os.path.exists(os.path.join(out_dir, n + ".glb"))]

    print("\n" + "=" * 74)
    print("参数化建模 %d 把 -> %s" % (len(names), out_dir))
    print("=" * 74)

    results = []
    for n in names:
        try:
            r = build_one(n, out_dir)
            results.append(r)
            print("  ✓ %-8s %4d 面 + 手臂 %3d 面 | %.2f x %.2f x %.2f m | 目标长 %.2fm"
                  % (n, r["tris"], r["arm_tris"], r["dims"][0], r["dims"][1],
                     r["dims"][2], r["target"]))
        except Exception as exc:
            print("  × %-8s 失败: %s" % (n, exc))

    print("-" * 74)
    if results:
        avg = sum(r["tris"] for r in results) / float(len(results))
        print("平均 %.0f 面 | 最高 %d 面 | 最低 %d 面"
              % (avg, max(r["tris"] for r in results),
                 min(r["tris"] for r in results)))
    print("完成 %d/%d" % (len(results), len(names)))
    print("=" * 74 + "\n")


if __name__ == "__main__":
    main()
