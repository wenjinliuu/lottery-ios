import SwiftUI

/// 开奖卡片上的奖级行。
///
/// 首页那张轮播卡和「往期开奖」里的每一行本来各画各的：首页画两档奖级
/// （带奖杯、注数、单注奖金），往期只有干巴巴一行「一等奖 N 注」。
/// 同一份开奖数据在两个页面上长得不一样，用户翻到往期会以为信息丢了。
/// 抽到这里之后两边都走同一套排版和同一套挑选规则（`PrizeRanking.topTwo`）。
struct DrawPrizeLines: View {
    let game: GameKey
    let draw: Draw?

    /// 要列的奖级。
    ///
    /// 快乐8 的奖级表是「选十中十、选十中九…」几十行，「一等奖」这个概念在它
    /// 身上不成立，所以排序第一依据是**单注奖金**而不是表里的行序。
    private var prizes: [PrizeEntry] {
        PrizeRanking.topTwo(of: draw?.prizeList ?? [], game: game)
    }

    var body: some View {
        if !prizes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(prizes.enumerated()), id: \.offset) { rank, entry in
                    line(entry, rank: rank)
                }
            }
        }
    }

    /// 一个奖级一行。奖金后面不跟「/注」—— 奖级本来就是按注计的，
    /// 那两个字每行都重复一遍，纯占地方。
    private func line(_ entry: PrizeEntry, rank: Int) -> some View {
        HStack(spacing: 6) {
            // 快乐8 没有「一等奖」这个名字，用排名区分：金额最高的那行挂奖杯。
            Image(systemName: isTopPrize(entry, rank: rank) ? "trophy.fill" : "rosette")
                .font(.system(size: 10))
                .foregroundStyle(game.tint)
            Text("\(prizeLabel(entry)) \(entry.winningCount) 注")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if entry.amount > 0 {
                Text(MoneyText.compactYuan(entry.amount))
                    .font(.system(.footnote, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(game.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func isTopPrize(_ entry: PrizeEntry, rank: Int) -> Bool {
        game == .k8 ? rank == 0 : entry.prizeName.contains("一等奖")
    }

    /// 快乐8 的奖级名照抄票面（「选十中9」），其余彩种收成「一等奖 / 二等奖」。
    private func prizeLabel(_ entry: PrizeEntry) -> String {
        if game == .k8 { return entry.prizeName }
        return entry.prizeName.contains("一等奖") ? "一等奖" : "二等奖"
    }
}
