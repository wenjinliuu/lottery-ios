import Foundation

enum LotteryV2Mapper {}

extension LotteryV2Mapper {
    // MARK: - 开奖

    /// 一条开奖。
    ///
    /// `drawTime` 由调用方从 `schedule.<type>.draw_time` 传进来 ——
    /// **开奖条目自己不带时刻**，文档里写的 `time` 字段实测一个都没有。
    static func draw(_ item: LotteryV2.DrawItem, game: GameKey) -> Draw? {
        let issue = item.issue.text
        guard !issue.isEmpty else { return nil }

        var draw = Draw()
        draw.gameKey = game
        draw.gameName = game.label
        draw.expect = issue
        draw.openDate = item.date ?? ""
        draw.id = [game.rawValue, draw.expect, draw.openDate].filter { !$0.isEmpty }.joined(separator: "_")
        draw.drawValues = numbers(item.numbers, game: game)
        draw.saleAmount = item.sales.text
        draw.totalMoney = item.pool.text
        draw.prizeList = (item.prizes ?? []).map(prize)
        return draw
    }

    static func draws(_ items: [LotteryV2.DrawItem]?, game: GameKey) -> [Draw] {
        (items ?? []).compactMap { draw($0, game: game) }
    }

    /// 奖级。V2 的字段名和 V1 全不一样，对应关系写在这儿一次。
    ///
    /// `extra_winners` 没有落到业务模型上：`PrizeEntry` 没有这个概念，
    /// 界面也没有任何地方展示「追加中奖注数」。实测数据里大乐透的追加
    /// 本来就是独立的「追加一等奖」行，注数在那一行的 `winners` 上。
    private static func prize(_ item: LotteryV2.Prize) -> PrizeEntry {
        PrizeEntry(prizeName: item.name ?? "",
                   require: item.match ?? "",
                   winningCount: item.winners ?? 0,
                   singleBonus: item.amount.text,
                   addBonus: item.extraAmount.text)
    }

    /// 号码区。各彩种的键名来自实测数据，和 V1 一致。
    static func numbers(_ raw: LotteryV2.Numbers?, game: GameKey) -> NumberSet {
        guard let raw else { return NumberSet() }
        switch game {
        case .ssq:
            return NumberSet([.red: raw.red ?? [], .blue: raw.blue ?? []])
        case .dlt:
            return NumberSet([.front: raw.front ?? [], .back: raw.back ?? []])
        case .k8:
            return NumberSet([.nums: raw.nums ?? []])
        case .fc3d, .pl3, .pl5:
            return NumberSet([.nums: raw.digits ?? []])
        case .qlc:
            var set = NumberSet([.nums7: raw.basic ?? []])
            if let special = raw.special { set[.special] = [special] }
            return set
        case .qxc:
            // 七星彩的 digits 是 7 位：前六位一组，末位单独一组。
            let digits = raw.digits ?? []
            var set = NumberSet([.nums6: Array(digits.prefix(6))])
            if digits.count > 6 { set[.tail] = [digits[6]] }
            return set
        }
    }
}
