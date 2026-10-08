# -*- coding: utf-8 -*-
"""
程序化生成小刀音效（纯标准库，不依赖 numpy）

输出到 sounds/：
    knife_swing.wav   挥刀破空声（whoosh）
    knife_hit.wav     刀刺入身体的闷响
    knife_wall.wav    刀划过墙面的刮擦声

用法：
    python tools/gen_knife_sounds.py
"""

import math
import os
import random
import struct
import wave

SR = 44100          # 采样率
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "sounds")


# ---------------------------------------------------------------- 基础工具
class SVF:
    """Chamberlin 状态变量滤波器，可输出低通/带通/高通，支持中心频率扫描。"""

    def __init__(self, fc, q=1.0):
        self.low = 0.0
        self.band = 0.0
        self.fc = fc
        self.q = q

    def process(self, x, fc=None, q=None):
        f = 2.0 * math.sin(math.pi * (fc if fc else self.fc) / SR)
        qq = 1.0 / (q if q else self.q)
        self.low += f * self.band
        high = x - self.low - qq * self.band
        self.band = f * high + self.band
        return self.low, self.band, high


def noise():
    return random.uniform(-1.0, 1.0)


def env_ar(n, attack, decay, curve=2.0):
    """攻击-衰减包络，返回长度 n 的列表。"""
    out = []
    a = max(int(attack * SR), 1)
    d = max(n - a, 1)
    for i in range(n):
        if i < a:
            out.append((i / a) ** 0.6)
        else:
            t = (i - a) / d
            out.append(max(1.0 - t, 0.0) ** curve)
    return out


def normalize(buf, peak=0.85):
    m = max((abs(v) for v in buf), default=0.0)
    if m < 1e-9:
        return buf
    k = peak / m
    return [v * k for v in buf]


def soft_clip(buf, drive=1.6):
    return [math.tanh(v * drive) for v in buf]


def write_wav(name, buf, sr=SR):
    path = os.path.join(OUT, name)
    frames = b"".join(
        struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767)) for v in buf)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(frames)
    print("  ✓ %-20s %6.2f 秒  %6.1f KB"
          % (name, len(buf) / float(sr), os.path.getsize(path) / 1024.0))


# ---------------------------------------------------------------- 三个音效
def make_swing(dur=0.24):
    """挥刀破空：带通噪声，中心频率从低扫到高再回落，模拟刀锋划过空气。"""
    n = int(dur * SR)
    f_lo, f_hi = 700.0, 3400.0
    svf = SVF(1200.0, q=3.2)
    buf = []
    for i in range(n):
        t = i / float(n)
        # 频率先升后降（划过时空气压缩最剧烈在 60% 处）
        shape = math.sin(t * math.pi) ** 0.7
        fc = f_lo + (f_hi - f_lo) * shape
        _, band, _ = svf.process(noise(), fc=fc, q=2.4 + 2.0 * shape)
        buf.append(band)
    e = env_ar(n, 0.035, 0.0, 2.2)
    buf = [v * e[i] for i, v in enumerate(buf)]
    return soft_clip(normalize(buf, 0.8), 1.3)


def make_stab(dur=0.30):
    """刺中身体：低频闷响 + 短促中频噪声，像刀刃入肉。"""
    n = int(dur * SR)
    buf = []
    svf = SVF(420.0, q=1.1)
    for i in range(n):
        t = i / float(n)
        # 低频 thump：95Hz 下滑到 55Hz
        f0 = 95.0 - 40.0 * min(t * 3.0, 1.0)
        thump = math.sin(2.0 * math.pi * f0 * (i / float(SR)))
        thump *= math.exp(-t * 11.0)
        # 中频噪声（破开组织）
        _, band, _ = svf.process(noise(), fc=380.0 + 260.0 * (1.0 - t), q=1.4)
        nz = band * math.exp(-t * 16.0) * 0.7
        buf.append(thump * 0.9 + nz)
    e = env_ar(n, 0.004, 0.0, 2.6)
    buf = [v * e[i] for i, v in enumerate(buf)]
    return soft_clip(normalize(buf, 0.85), 1.2)


def make_wall(dur=0.34):
    """划过墙面：高频刮擦噪声 + 两个共振峰，比挥空声更刺、更长。"""
    n = int(dur * SR)
    svf = SVF(3800.0, q=6.0)
    res1 = SVF(2600.0, q=9.0)
    res2 = SVF(5200.0, q=9.0)
    buf = []
    for i in range(n):
        t = i / float(n)
        _, band, high = svf.process(noise(), fc=3000.0 + 2200.0 * math.sin(t * math.pi),
                                    q=3.0)
        _, b1, _ = res1.process(noise(), q=10.0)
        _, b2, _ = res2.process(noise(), q=10.0)
        # 起始最刺（刀尖接触瞬间），之后逐渐衰减但保持摩擦感
        scrape = (band * 1.0 + b1 * 0.55 + b2 * 0.35 + high * 0.25)
        buf.append(scrape)
    e = env_ar(n, 0.003, 0.0, 1.7)
    # 叠加细密的"颗粒抖动"，模拟刀锋在粗糙墙面上跳动
    for i in range(n):
        grain = 1.0 + 0.28 * math.sin(i * 0.7) * math.sin(i * 0.031)
        buf[i] *= e[i] * grain
    return soft_clip(normalize(buf, 0.75), 1.5)


def main():
    random.seed(20260924)
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    print("\n生成小刀音效 -> %s\n" % OUT)
    write_wav("knife_swing.wav", make_swing())
    write_wav("knife_hit.wav", make_stab())
    write_wav("knife_wall.wav", make_wall())
    print("\n完成。Godot 打开项目后会自动导入。\n")


if __name__ == "__main__":
    main()
