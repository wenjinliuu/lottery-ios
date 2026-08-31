#!/usr/bin/env python3
"""生成 1024×1024 App 图标。

不依赖第三方库（CI 的 macOS runner 上没有 Pillow），直接写 PNG。
配色沿用 App 内的彩种色，红/黄/白三颗号码球压在蓝色渐变底上。
"""
import struct
import zlib
from pathlib import Path

SIZE = 1024
SS = 2  # 超采样倍数，用来做抗锯齿


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


BG_TOP = (0x1D, 0x4E, 0xD8)
BG_BOTTOM = (0x0E, 0xA5, 0xE9)

# (圆心 x, 圆心 y, 半径, 渐变上端, 渐变下端)
BALLS = [
    (212, 512, 148, (0xFF, 0x87, 0x93), (0xEF, 0x44, 0x44)),
    (512, 512, 148, (0xFF, 0xFF, 0xFF), (0xE2, 0xE8, 0xF0)),
    (812, 512, 148, (0xFF, 0xC8, 0x5C), (0xFF, 0x9C, 0x34)),
]


def sample(x, y):
    """返回某个采样点的颜色。"""
    color = lerp(BG_TOP, BG_BOTTOM, y / SIZE)
    for cx, cy, r, light, deep in BALLS:
        dx, dy = x - cx, y - cy
        if dx * dx + dy * dy <= r * r:
            # 球自身的上浅下深渐变
            t = (dy + r) / (2 * r)
            color = lerp(light, deep, t)
    return color


def build_rows():
    rows = []
    for py in range(SIZE):
        row = bytearray()
        for px in range(SIZE):
            r = g = b = 0
            for sy in range(SS):
                for sx in range(SS):
                    c = sample(px + (sx + 0.5) / SS, py + (sy + 0.5) / SS)
                    r += c[0]
                    g += c[1]
                    b += c[2]
            n = SS * SS
            row += bytes((r // n, g // n, b // n))
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(tag, data):
        payload = tag + data
        return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload))

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    Path(path).write_bytes(png)


if __name__ == "__main__":
    target = Path(__file__).resolve().parent.parent / "LotteryWallet/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    write_png(target, build_rows())
    print(f"wrote {target}")
