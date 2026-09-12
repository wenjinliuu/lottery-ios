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


def runs(profile, floor):
    """一条剖面里连续「超过下限」的那些段。"""
    out, start = [], None
    for i, value in enumerate(profile):
        on = value > floor
        if on and start is None:
            start = i
        if not on and start is not None:
            out.append((start, i - 1))
            start = None
    if start is not None:
        out.append((start, len(profile) - 1))
    return out


def bands(ink, width, floor=0.08):
    """按横向墨量把图切成一条条横带。"""
    return runs(ink.sum(axis=1), width * floor)


# 试哪些倾角。0.005 ≈ 0.29°，一路试到 ±2°。
# 一条横跨 950px 的虚线只要歪 0.5°，按行投影就摊成十几行高，
# 「高 ≤ 6 行」当场判不出来 —— 所以投影方向要跟着票斜。
# slope=0 时和按行投影完全等价，实测那三张票的判据一个数都没动。
# 这套逻辑和 LotteryWallet/Features/Scan/DashedRuleDetector.swift 是一对，
# 改一边就要改另一边，否则量出来的和 App 里跑出来的对不上。
SLOPES = [0.0] + [s * d for s in (0.005 * k for k in range(1, 8)) for d in (1, -1)]


def bins_at(ink, slope):
    """沿着一条有斜率的方向做横向投影。返回 (剖面, 让出的格数)。"""
    height, width = ink.shape
    extra = int(np.ceil(abs(slope) * width / 2)) + 1
    ys, xs = np.nonzero(ink)
    profile = np.zeros(height + extra * 2, dtype=int)
    if len(ys):
        idx = np.rint(ys - slope * (xs - width / 2)).astype(int) + extra
        np.add.at(profile, np.clip(idx, 0, len(profile) - 1), 1)
    return profile, extra


def present_at(ink, band, extra, slope):
    """斜投影里某一格带上，每一列有没有墨。"""
    height, width = ink.shape
    cols = np.zeros(width, dtype=bool)
    for x in range(width):
        shift = slope * (x - width / 2)
        low = max(0, int(np.floor(band[0] - extra + shift)))
        high = min(height - 1, int(np.ceil(band[1] - extra + shift)))
        if low <= high:
            cols[x] = ink[low:high + 1, x].any()
    return cols


def rules_at(ink, slope, verbose=False):
    """沿某一个倾角量一遍。判据来自三张真票实测，零误报。"""
    height, width = ink.shape
    profile, extra = bins_at(ink, slope)
    hits = []
    for band in runs(profile, width * 0.08):
        thickness = band[1] - band[0] + 1
        cols = present_at(ink, band, extra, slope)
        xs = np.where(cols)[0]
        if len(xs) == 0:
            continue
        extent = (xs[-1] - xs[0] + 1) / width
        edges = np.diff(np.concatenate(([0], cols.astype(int), [0])))
        lengths = np.where(edges == -1)[0] - np.where(edges == 1)[0]
        fill = cols.sum() / max(1, xs[-1] - xs[0] + 1)
        dashed = (thickness <= 6 and extent > 0.80 and len(lengths) >= 12
                  and lengths.max() <= width * 0.05 and 0.25 < fill < 0.75)
        if dashed:
            hits.append((band[0] - extra, band[1] - extra))
        if verbose:
            print(f"  y{band[0] - extra:4d}-{band[1] - extra:4d} 高{thickness:3d} "
                  f"横跨{extent:.2f} 左{xs[0]:4d} 右{xs[-1]:4d} "
                  f"段{len(lengths):3d} 占空{fill:.2f}"
                  f"{'   <<< 虚线' if dashed else ''}")
    return hits


def find_rules(path, box=None):
    """找上下两条虚线。

    先按行投影量（和以前一样），没凑够两条再按倾角从小到大扫一遍 ——
    票只要歪半度，按行投影就量不出来了。
    """
    image = Image.open(path).convert("L")
    if box:
        image = image.crop(box)
    a = np.array(image, dtype=float)
    height, width = a.shape
    ink = a < otsu(a)
    print(f"{path}  {width}x{height}")
    hits = rules_at(ink, 0.0, verbose=True)
    if len(hits) == 2:
        print(f"  → 虚线 {len(hits)} 条 {hits}")
        return hits
    for slope in SLOPES[1:]:
        found = rules_at(ink, slope)
        if len(found) == 2:
            print(f"  票歪着 {np.degrees(np.arctan(slope)):+.2f}°，"
                  f"沿这个方向投影量到 2 条 {found}")
            return found
    print(f"  → 虚线 {len(hits)} 条 {hits}（各个倾角都没凑够两条）")
    return hits


def measure(path, box):
    """量一块区域的行距、列距、字宽、字高。"""
    a = np.array(Image.open(path).convert("L").crop(box), dtype=float)
    height, width = a.shape
    ink = a < otsu(a)

    def segments(profile, floor):
        """和上面的 `runs` 差一条：太窄的段（一两个像素）当噪点丢掉。"""
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

    cols = segments(ink.sum(axis=0), 0)
    rows = segments(ink.sum(axis=1), width * 0.05)
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
