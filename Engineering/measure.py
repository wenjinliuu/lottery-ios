#!/usr/bin/env python3
"""量票面用的小工具。

改代码之前先拿新票照片量一遍 —— 之前每一次靠猜的改动都白费了，
每一次先量的改动都直接定位到根因。

用法:
    python3 Engineering/measure.py 票.jpg              # 找虚线
    python3 Engineering/measure.py 票.jpg --rows L T R B  # 量某块区域的行列
"""
import sys
import numpy as np
from PIL import Image


def otsu(a):
    """大津法阈值。热敏票印在银灰纸上，固定阈值不管用。"""
    hist, _ = np.histogram(a, bins=256, range=(0, 256))
    total = a.size
    sum_all = np.dot(np.arange(256), hist)
    sum_b = 0.0
    weight_b = 0.0
    best = 0.0
    threshold = 128
    for t in range(256):
        weight_b += hist[t]
        if weight_b == 0:
            continue
        weight_f = total - weight_b
        if weight_f == 0:
            break
        sum_b += t * hist[t]
        diff = sum_b / weight_b - (sum_all - sum_b) / weight_f
        variance = weight_b * weight_f * diff * diff
        if variance > best:
            best, threshold = variance, t
    return threshold


def bands(ink, width, floor=0.08):
    """按横向墨量把图切成一条条横带。"""
    profile = ink.sum(axis=1)
    out, start = [], None
    for y, value in enumerate(profile):
        on = value > width * floor
        if on and start is None:
            start = y
        if not on and start is not None:
            out.append((start, y - 1))
            start = None
    if start is not None:
        out.append((start, len(profile) - 1))
    return out


def find_rules(path, box=None):
    """找上下两条虚线。判据来自三张真票实测，零误报。"""
    image = Image.open(path).convert("L")
    if box:
        image = image.crop(box)
    a = np.array(image, dtype=float)
    height, width = a.shape
    ink = a < otsu(a)
    print(f"{path}  {width}x{height}")
    hits = []
    for y0, y1 in bands(ink, width):
        thickness = y1 - y0 + 1
        cols = ink[y0:y1 + 1].any(axis=0)
        xs = np.where(cols)[0]
        if len(xs) == 0:
            continue
        extent = (xs[-1] - xs[0] + 1) / width
        runs = np.diff(np.concatenate(([0], cols.astype(int), [0])))
        lengths = np.where(runs == -1)[0] - np.where(runs == 1)[0]
        fill = cols.sum() / max(1, xs[-1] - xs[0] + 1)
        dashed = (thickness <= 6 and extent > 0.80 and len(lengths) >= 12
                  and lengths.max() <= width * 0.05 and 0.25 < fill < 0.75)
        if dashed:
            hits.append((y0, y1))
        print(f"  y{y0:4d}-{y1:4d} 高{thickness:3d} 横跨{extent:.2f} "
              f"左{xs[0]:4d} 右{xs[-1]:4d} 段{len(lengths):3d} 占空{fill:.2f}"
              f"{'   <<< 虚线' if dashed else ''}")
    print(f"  → 虚线 {len(hits)} 条 {hits}")
    return hits


def measure(path, box):
    """量一块区域的行距、列距、字宽、字高。"""
    a = np.array(Image.open(path).convert("L").crop(box), dtype=float)
    height, width = a.shape
    ink = a < otsu(a)

    def runs(profile, floor):
        out, start = [], None
        for i, value in enumerate(profile):
            on = value > floor
            if on and start is None:
                start = i
            if not on and start is not None:
                if i - 1 - start >= 1:
                    out.append((start, i - 1))
                start = None
        if start is not None:
            out.append((start, len(profile) - 1))
        return out

    cols = runs(ink.sum(axis=0), 0)
    rows = runs(ink.sum(axis=1), width * 0.05)
    cc = [(a1 + b1) / 2 for a1, b1 in cols]
    rc = [(a1 + b1) / 2 for a1, b1 in rows]
    print(f"{path} {box}  {width}x{height}")
    print("  列段", [(a1, b1, b1 - a1 + 1) for a1, b1 in cols])
    print("  列距", [round(cc[i + 1] - cc[i], 1) for i in range(len(cc) - 1)])
    print("  行距", [round(rc[i + 1] - rc[i], 1) for i in range(len(rc) - 1)],
          "字高", [b1 - a1 + 1 for a1, b1 in rows])


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        raise SystemExit(1)
    if "--rows" in args:
        index = args.index("--rows")
        box = tuple(int(v) for v in args[index + 1:index + 5])
        measure(args[0], box)
    else:
        find_rules(args[0])
