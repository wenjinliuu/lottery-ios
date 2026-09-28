#!/usr/bin/env python3
"""生成 `--demo-data` 用的示例票据：LotteryWallet/Data/DemoDataset.swift。

只给截图、UI 测试和 Live Preview 用，不会进用户的数据库。

- 彩种：双色球、大乐透
- 区间：2026-06-01 至 2026-09-27，每一期开奖都有一张票
- 开奖号码和各奖级奖金来自 lottery-data-repo 的 public_data/v2/by-year/{game}/2026.json
- 六成的票中奖（中奖的票每注都中）；总投入五六百元，整体盈亏为正

号码是按「要中哪个奖级」反推出来的，结论由 App 里的 PrizeRules 在播种时重新核对，
所以这里算的只是预期，真正落库的奖级以 App 的判定为准（单元测试会核对两者一致）。

用法：
    python3 Scripts/make-demo-data.py /path/to/lottery-data-repo
"""
import json
import random
import sys
from pathlib import Path

START, END = "2026-06-01", "2026-09-27"
SEED = 20260927
WIN_RATE = 0.6

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "LotteryWallet/Data/DemoDataset.swift"

GAMES = {
    # key: (主区, 主区范围, 主区个数, 副区, 副区范围, 副区个数)
    "ssq": ("red", 33, 6, "blue", 16, 1),
    "dlt": ("front", 35, 5, "back", 12, 2),
}

# 中奖的票每一注都中，要中哪个奖级：(主区命中, 副区命中)。权重决定出现频率。
# 首页的「中奖率」按注算，这样票和注的中奖比例都在六成左右。
WIN_SHAPES = {
    "ssq": [((1, 1), 40), ((2, 1), 30), ((0, 1), 20), ((3, 1), 6), ((4, 0), 4)],
    "dlt": [((2, 1), 40), ((1, 2), 15), ((3, 0), 30), ((0, 2), 10), ((3, 1), 3), ((2, 2), 2)],
}
# 不中奖的注：命中数组合必须落在无奖区。
LOSE_SHAPES = {
    "ssq": [(0, 0), (1, 0), (2, 0), (1, 0), (2, 0)],
    "dlt": [(0, 0), (1, 0), (2, 0), (0, 1), (1, 1)],
}
# 每张票几注：权重。中奖的票注数偏少，免得奖金把盈亏抬得太离谱。
LINE_COUNTS = {True: [(1, 30), (2, 45), (3, 25)], False: [(2, 25), (3, 40), (5, 35)]}

# 七乐彩、七星彩单独生成（自己的随机数，不影响上面两个彩种已经定下来的数据）。
EXTRA_GAMES = ("qlc", "qxc")
EXTRA_SEED = 20260928
# 七乐彩：(基本号命中数, 是否含特别号)；七星彩：(前六位按位命中数, 特别号是否命中)
EXTRA_WIN = {
    "qlc": [((4, False), 88), ((4, True), 12)],
    "qxc": [((3, False), 60), ((2, True), 20), ((1, True), 17), ((4, False), 3)],
}
EXTRA_LOSE = {
    "qlc": [(1, False), (2, False), (3, False), (2, True), (3, True)],
    "qxc": [(0, False), (1, False), (2, False), (2, False)],
}


def pick(rng, population, weights):
    return rng.choices(population, weights=weights, k=1)[0]


def make_line(rng, draw_main, draw_sub, main_range, main_count, sub_range, sub_count, hits):
    main_hit, sub_hit = hits
    main = rng.sample(sorted(draw_main), main_hit)
    others = [n for n in range(1, main_range + 1) if n not in draw_main]
    main += rng.sample(others, main_count - main_hit)
    sub = rng.sample(sorted(draw_sub), sub_hit)
    sub_others = [n for n in range(1, sub_range + 1) if n not in draw_sub]
    sub += rng.sample(sub_others, sub_count - sub_hit)
    return sorted(main), sorted(sub)


def prize_name(game, hits):
    m, s = hits
    if game == "ssq":
        table = {(6, 1): "一等奖", (6, 0): "二等奖", (5, 1): "三等奖", (5, 0): "四等奖", (4, 1): "四等奖",
                 (4, 0): "五等奖", (3, 1): "五等奖", (2, 1): "六等奖", (1, 1): "六等奖", (0, 1): "六等奖"}
    else:
        table = {(5, 2): "一等奖", (5, 1): "二等奖", (5, 0): "三等奖", (4, 2): "三等奖", (4, 1): "四等奖",
                 (4, 0): "五等奖", (3, 2): "五等奖", (3, 1): "六等奖", (2, 2): "六等奖",
                 (3, 0): "七等奖", (2, 1): "七等奖", (1, 2): "七等奖", (0, 2): "七等奖"}
    return table.get(hits)


def qlc_line(rng, draw, hits):
    basic, special = draw["numbers"]["basic"], draw["numbers"]["special"]
    count, with_special = hits
    line = rng.sample(sorted(basic), count)
    if with_special:
        line.append(special)
    others = [n for n in range(1, 31) if n not in basic and n != special]
    line += rng.sample(others, 7 - len(line))
    name = {(4, True): "六等奖", (4, False): "七等奖"}.get(hits)
    return {"nums7": sorted(line)}, name


def qxc_line(rng, draw, hits):
    digits = draw["numbers"]["digits"]
    main, tail = digits[:6], digits[6]
    count, tail_hit = hits
    hit_at = set(rng.sample(range(6), count))
    line = [main[i] if i in hit_at else rng.choice([d for d in range(10) if d != main[i]]) for i in range(6)]
    back = tail if tail_hit else rng.choice([d for d in range(15) if d != tail])
    if count == 4 or (count == 3 and tail_hit):
        name = "五等奖"
    elif count == 3 or tail_hit:
        name = "六等奖"
    else:
        name = None
    return {"nums6": line, "tail": [back]}, name


def app_numbers(game, numbers):
    """开奖号换成 App 里的号码区键名（和 LotteryV2Mapper 一致）。"""
    if game == "qlc":
        return {"nums7": numbers["basic"], "special": [numbers["special"]]}
    if game == "qxc":
        return {"nums6": numbers["digits"][:6], "tail": numbers["digits"][6:7]}
    return numbers


def amount(draw, name):
    for prize in draw["prizes"]:
        if prize["name"] == name:
            return float(prize.get("amount") or 0)
    return 0.0


def main():
    repo = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT.parent / "lottery-data-repo")
    rng = random.Random(SEED)
    draws, tickets = [], []
    # 先把这段时间的全部开奖读出来，再按比例精确挑出中奖的那几期，不靠随机数碰运气。
    periods = []
    for game in GAMES:
        data = json.loads((repo / f"public_data/v2/by-year/{game}/2026.json").read_text())
        periods += [(game, d) for d in data["draws"] if START <= d["date"] <= END]
    periods.sort(key=lambda item: (item[1]["date"], item[0]))
    winners = set(rng.sample(range(len(periods)), round(len(periods) * WIN_RATE)))
    for index, (game, draw) in enumerate(periods):
        main_key, main_range, main_count, sub_key, sub_range, sub_count = GAMES[game]
        if True:
            draws.append({
                "game": game,
                "issue": draw["issue"],
                "date": draw["date"],
                "numbers": draw["numbers"],
                "prizes": [{"name": p["name"], "amount": p.get("amount", "")} for p in draw["prizes"]],
            })
            draw_main, draw_sub = set(draw["numbers"][main_key]), set(draw["numbers"][sub_key])
            counts = LINE_COUNTS[index in winners]
            count = pick(rng, [c for c, _ in counts], [w for _, w in counts])
            if index in winners:
                options = WIN_SHAPES[game]
                shapes = [pick(rng, [s for s, _ in options], [w for _, w in options]) for _ in range(count)]
            else:
                shapes = [rng.choice(LOSE_SHAPES[game]) for _ in range(count)]
            lines = []
            expected = 0.0
            for hits in shapes:
                main_nums, sub_nums = make_line(rng, draw_main, draw_sub, main_range, main_count,
                                                sub_range, sub_count, hits)
                lines.append({main_key: main_nums, sub_key: sub_nums})
                name = prize_name(game, hits)
                if name:
                    expected += amount(draw, name)
            tickets.append({"game": game, "issue": draw["issue"], "lines": lines, "expected": expected})

    rng = random.Random(EXTRA_SEED)
    periods = []
    for game in EXTRA_GAMES:
        data = json.loads((repo / f"public_data/v2/by-year/{game}/2026.json").read_text())
        periods += [(game, d) for d in data["draws"] if START <= d["date"] <= END]
    periods.sort(key=lambda item: (item[1]["date"], item[0]))
    winners = set(rng.sample(range(len(periods)), round(len(periods) * WIN_RATE)))
    for index, (game, draw) in enumerate(periods):
        draws.append({
            "game": game,
            "issue": draw["issue"],
            "date": draw["date"],
            "numbers": app_numbers(game, draw["numbers"]),
            "prizes": [{"name": p["name"], "amount": p.get("amount", "")} for p in draw["prizes"]],
        })
        options = EXTRA_WIN[game] if index in winners else [(h, 1) for h in EXTRA_LOSE[game]]
        hits = pick(rng, [h for h, _ in options], [w for _, w in options])
        line, name = (qlc_line if game == "qlc" else qxc_line)(rng, draw, hits)
        tickets.append({"game": game, "issue": draw["issue"], "lines": [line],
                        "expected": amount(draw, name) if name else 0.0})

    for group in (("ssq", "dlt"), EXTRA_GAMES):
        part = [t for t in tickets if t["game"] in group]
        print(f"  {'/'.join(group)}：{len(part)} 张，投入 {sum(2 * len(t['lines']) for t in part)} 元，"
              f"奖金 {sum(t['expected'] for t in part):.0f} 元")

    cost = sum(2 * len(t["lines"]) for t in tickets)
    prize = sum(t["expected"] for t in tickets)
    won = sum(1 for t in tickets if t["expected"] > 0)
    lines = sum(len(t["lines"]) for t in tickets)
    won_lines = sum(len(t["lines"]) for t in tickets if t["expected"] > 0)
    print(f"{len(tickets)} 张票，{sum(len(t['lines']) for t in tickets)} 注；投入 {cost:.0f} 元，"
          f"奖金 {prize:.0f} 元，盈亏 {prize - cost:+.0f} 元；中奖票 {won}/{len(tickets)} = {won / len(tickets):.0%}，"
          f"中奖注 {won_lines}/{lines} = {won_lines / lines:.0%}")

    payload = json.dumps({"draws": draws, "tickets": [{k: v for k, v in t.items() if k != "expected"} for t in tickets]},
                         ensure_ascii=False, separators=(",", ":"))
    # 每行一条，方便看 diff
    payload = payload.replace("},{\"game\"", "},\n{\"game\"")
    OUT.write_text(
        "// 由 Scripts/make-demo-data.py 生成，不要手改。\n"
        "// 开奖号码与奖金来自 lottery-data-repo（2026-06-01 至 2026-09-27 的双色球、大乐透、七乐彩、七星彩）。\n\n"
        "enum DemoDataset {\n"
        "    static let json = #\"\"\"\n"
        f"{payload}\n"
        "\"\"\"#\n"
        "}\n",
        encoding="utf-8",
    )
    print(f"写入 {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
