#!/usr/bin/env python3
"""生成 App 图标（浅色 + 深色两版，1024×1024）。

设计：黑白底 + 一颗双色球红球，球面写「08」。
球的渐变、内高光、投影都对齐 App 内 BallView 的参数，图标和界面是同一件东西。

不依赖第三方库（CI 的 macOS runner 上没有 Pillow），直接写 PNG。
数字用几何方式画 —— 圆体字的 0 和 8 本来就是圆环，用有向距离场画出来
比嵌一整套字体干净得多，而且任意分辨率都不会糊。
"""
import math
import struct
import zlib
from pathlib import Path

SIZE = 1024
SS = 3  # 超采样倍数，抗锯齿

# 球：直径占画布 56%，居中
BALL_R = SIZE * 0.28
CX, CY = SIZE / 2, SIZE / 2

# 方案②的双色球红（深端未改动）
BALL_LIGHT = (0xFF, 0x8E, 0x85)
BALL_DEEP = (0xEF, 0x44, 0x44)

# 「08」的排版
CAP = BALL_R * 0.74          # 字高
GAP = CAP * 0.22             # 字间距
W0, W8 = CAP * 0.60, CAP * 0.58
TEXT_W = W0 + GAP + W8
X0 = CX - TEXT_W / 2 + W0 / 2      # 「0」的中心
X8 = CX + TEXT_W / 2 - W8 / 2      # 「8」的中心


def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def ellipse_ring(x, y, cx, cy, rx, ry, half):
    """椭圆环的近似有向距离：<0 在环上。"""
    dx, dy = (x - cx) / rx, (y - cy) / ry
    d = math.hypot(dx, dy) - 1.0
    # 换算回像素尺度，rx/ry 差别不大时足够准
    d *= (rx + ry) / 2
    return abs(d) - half


def glyph_zero(x, y):
    return ellipse_ring(x, y, X0, CY, W0 / 2, CAP / 2, CAP * 0.115)


def glyph_eight(x, y):
    # 上小下大两个圆环，几何圆体字的标准做法
    up = ellipse_ring(x, y, X8, CY - CAP * 0.245, W8 * 0.385, CAP * 0.255, CAP * 0.105)
    lo = ellipse_ring(x, y, X8, CY + CAP * 0.235, W8 * 0.5, CAP * 0.265, CAP * 0.105)
    return min(up, lo)


def digits(x, y):
    return min(glyph_zero(x, y), glyph_eight(x, y))


def cover(d, feather):
    """把距离换成 0..1 的覆盖率。"""
    return max(0.0, min(1.0, 0.5 - d / feather))


def sample(x, y, dark):
    # ---- 背景：左上打光的极淡径向渐变 ----
    if dark:
        top, bottom = (0x2A, 0x2C, 0x31), (0x0B, 0x0B, 0x0D)
    else:
        top, bottom = (0xFF, 0xFF, 0xFF), (0xE4, 0xE5, 0xEA)
    gx, gy = (x - SIZE * 0.30) / (SIZE * 1.20), (y - SIZE * 0.08) / (SIZE * 1.20)
    color = lerp(top, bottom, min(1.0, math.hypot(gx, gy) / 0.62))

    dist = math.hypot(x - CX, y - CY) - BALL_R
    feather = 1.2

    # ---- 球下方的投影 ----
    sh = math.hypot(x - CX, (y - CY - BALL_R * 0.13) * 1.10) - BALL_R * 1.00
    if sh < BALL_R * 0.30:
        k = max(0.0, min(1.0, 1 - sh / (BALL_R * 0.30))) ** 2
        shade = 0.26 if dark else 0.13
        color = lerp(color, (0, 0, 0) if dark else (0xC0, 0x9A, 0x9A), k * shade)

    # ---- 球体 ----
    a = cover(dist, feather)
    if a > 0:
        t = (y - (CY - BALL_R)) / (2 * BALL_R)
        ball = lerp(BALL_LIGHT, BALL_DEEP, t)

        # 顶部内高光：沿球沿一圈的白边，上半最亮
        rim = cover(abs(dist + BALL_R * 0.018) - BALL_R * 0.012, feather)
        top_bias = max(0.0, 1 - (y - (CY - BALL_R)) / (BALL_R * 1.15))
        ball = lerp(ball, (255, 255, 255), rim * 0.50 * top_bias)

        # 底部一点点暗，给球一点厚度
        bottom_bias = max(0.0, (y - CY) / BALL_R)
        ball = lerp(ball, (0x8A, 0x10, 0x1C), bottom_bias * 0.14)

        # ---- 数字 ----
        dg = cover(digits(x, y), feather)
        if dg > 0:
            ball = lerp(ball, (255, 255, 255), dg)

        color = lerp(color, ball, a)

    return color


def build(dark):
    rows = []
    n = SS * SS
    for py in range(SIZE):
        row = bytearray()
        for px in range(SIZE):
            r = g = b = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    c = sample(px + (sx + 0.5) / SS, py + (sy + 0.5) / SS, dark)
                    r += c[0]; g += c[1]; b += c[2]
            row += bytes((round(r / n), round(g / n), round(b / n)))
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(tag, data):
        payload = tag + data
        return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    Path(path).write_bytes(png)


if __name__ == "__main__":
    out = Path(__file__).resolve().parent.parent / "LotteryWallet/Resources/Assets.xcassets/AppIcon.appiconset"
    out.mkdir(parents=True, exist_ok=True)
    for dark, name in ((False, "icon-1024.png"), (True, "icon-1024-dark.png")):
        write_png(out / name, build(dark))
        print("wrote", out / name)
