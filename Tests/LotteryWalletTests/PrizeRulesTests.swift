import XCTest
@testable import LotteryWallet

/// 奖级判定的一致性测试，用例逐条对应 web 版 `tests/prize-rules.test.js`。
/// 两端结论必须完全一样，否则同一张票在网页和 App 上会给出不同答案。
final class PrizeRulesTests: XCTestCase {

    private func prize(_ name: String, _ amount: Double) -> PrizeEntry {
        PrizeEntry(prizeName: name, require: "", winningCount: 1, singleBonus: String(Int(amount)), addBonus: "")
    }

    private func draw(_ game: GameKey, _ values: NumberSet, _ prizes: [PrizeEntry]) -> Draw {
        var draw = Draw()
        draw.gameKey = game
        draw.expect = "2026001"
        draw.openDate = "2026-01-01"
        draw.drawValues = values
        draw.prizeList = prizes
        return draw
    }

    private func ticket(_ values: NumberSet, playMode: String = "", playCount: Int? = nil, addOn: Bool = false) -> Ticket {
        Ticket(numbers: values, playMode: playMode, playCount: playCount, addOn: addOn)
    }

    // MARK: - 双色球

    func testSSQFirstPrize() {
        let drawValues = NumberSet([.red: [1, 2, 3, 4, 5, 6], .blue: [7]])
        let result = PrizeRules.evaluate(
            gameKey: .ssq,
            ticket: ticket(NumberSet([.red: [1, 2, 3, 4, 5, 6], .blue: [7]])),
            draw: draw(.ssq, drawValues, [prize("一等奖", 5_000_000)])
        )
        XCTAssertEqual(result.prizeName, "一等奖")
        XCTAssertEqual(result.amount, 5_000_000)
        XCTAssertFalse(result.isFloating)
    }

    func testSSQFuyunPrizeOnlyWhenDrawOffersIt() {
        let drawValues = NumberSet([.red: [1, 2, 3, 4, 5, 6], .blue: [7]])
        let bet = ticket(NumberSet([.red: [1, 2, 3, 20, 21, 22], .blue: [8]]))

        let withFuyun = PrizeRules.evaluate(gameKey: .ssq, ticket: bet,
                                            draw: draw(.ssq, drawValues, [prize("福运奖", 10)]))
        XCTAssertEqual(withFuyun.prizeName, "福运奖")

        let without = PrizeRules.evaluate(gameKey: .ssq, ticket: bet,
                                          draw: draw(.ssq, drawValues, []))
        XCTAssertEqual(without.prizeName, PrizeRules.noPrizeName)
    }

    func testSSQMultiplierAppliesToConfirmedAmount() {
        let drawValues = NumberSet([.red: [1, 2, 3, 4, 5, 6], .blue: [7]])
        let result = PrizeRules.evaluate(
            gameKey: .ssq,
            ticket: ticket(NumberSet([.red: [1, 2, 3, 4, 5, 6], .blue: [8]])),
            draw: draw(.ssq, drawValues, [prize("二等奖", 200_000)]),
            multiple: 3
        )
        XCTAssertEqual(result.prizeName, "二等奖")
        XCTAssertEqual(result.amount, 600_000)
    }

    // MARK: - 大乐透

    func testDLTThirdPrizeBothShapes() {
        let drawValues = NumberSet([.front: [1, 2, 3, 4, 5], .back: [6, 7]])
        let meta = [prize("三等奖", 10_000)]

        let fiveZero = PrizeRules.evaluate(
            gameKey: .dlt,
            ticket: ticket(NumberSet([.front: [1, 2, 3, 4, 5], .back: [8, 9]])),
            draw: draw(.dlt, drawValues, meta)
        )
        XCTAssertEqual(fiveZero.prizeName, "三等奖")

        let fourTwo = PrizeRules.evaluate(
            gameKey: .dlt,
            ticket: ticket(NumberSet([.front: [1, 2, 3, 4, 8], .back: [6, 7]])),
            draw: draw(.dlt, drawValues, meta)
        )
        XCTAssertEqual(fourTwo.prizeName, "三等奖")
    }

    /// 追加票只有基本奖金和追加奖金都拿到才算确定，否则继续按浮动展示。
    func testDLTAddOnNeedsBothAmounts() {
        let drawValues = NumberSet([.front: [1, 2, 3, 4, 5], .back: [6, 7]])
        let bet = ticket(NumberSet([.front: [1, 2, 3, 4, 5], .back: [6, 7]]), playMode: "add", addOn: true)

        let baseOnly = PrizeRules.evaluate(gameKey: .dlt, ticket: bet,
                                           draw: draw(.dlt, drawValues, [prize("一等奖", 10_000_000)]))
        XCTAssertEqual(baseOnly.prizeName, "一等奖")
        XCTAssertTrue(baseOnly.isFloating)
        XCTAssertEqual(baseOnly.amount, 0)

        var inline = prize("一等奖", 10_000_000)
        inline.addBonus = "8000000"
        let both = PrizeRules.evaluate(gameKey: .dlt, ticket: bet,
                                       draw: draw(.dlt, drawValues, [inline]))
        XCTAssertFalse(both.isFloating)
        XCTAssertEqual(both.amount, 18_000_000)
    }

    // MARK: - 快乐8

    func testK8UsesPlayCountPrizeTable() {
        let drawValues = NumberSet([.nums: Array(1...20)])
        let result = PrizeRules.evaluate(
            gameKey: .k8,
            ticket: ticket(NumberSet([.nums: [1, 2, 3, 4, 5]]), playMode: "5", playCount: 5),
            draw: draw(.k8, drawValues, [prize("选五中五", 1000)])
        )
        XCTAssertEqual(result.amount, 1000)
    }

    // MARK: - 数字型

    func testDigitGames() {
        let single = PrizeRules.evaluate(
            gameKey: .fc3d,
            ticket: ticket(NumberSet([.nums3: [1, 2, 3]]), playMode: "single"),
            draw: draw(.fc3d, NumberSet([.nums: [1, 2, 3]]), [prize("直选", 1040)])
        )
        XCTAssertEqual(single.amount, 1040)

        // 直选看位置：号码相同但顺序不同不中奖
        let wrongOrder = PrizeRules.evaluate(
            gameKey: .fc3d,
            ticket: ticket(NumberSet([.nums3: [3, 2, 1]]), playMode: "single"),
            draw: draw(.fc3d, NumberSet([.nums: [1, 2, 3]]), [prize("直选", 1040)])
        )
        XCTAssertEqual(wrongOrder.prizeName, PrizeRules.noPrizeName)

        let group3 = PrizeRules.evaluate(
            gameKey: .pl3,
            ticket: ticket(NumberSet([.nums3: [1, 1, 2]]), playMode: "group3"),
            draw: draw(.pl3, NumberSet([.nums: [1, 2, 1]]), [prize("组三", 346)])
        )
        XCTAssertEqual(group3.amount, 346)

        let pl5 = PrizeRules.evaluate(
            gameKey: .pl5,
            ticket: ticket(NumberSet([.nums5: [1, 2, 3, 4, 5]])),
            draw: draw(.pl5, NumberSet([.nums: [1, 2, 3, 4, 5]]), [prize("一等奖", 100_000)])
        )
        XCTAssertEqual(pl5.amount, 100_000)
    }

    // MARK: - 七乐彩 / 七星彩

    func testQLCSecondPrizeNeedsSpecial() {
        let drawValues = NumberSet([.nums7: [1, 2, 3, 4, 5, 6, 7], .special: [8]])
        let result = PrizeRules.evaluate(
            gameKey: .qlc,
            ticket: ticket(NumberSet([.nums7: [1, 2, 3, 4, 5, 6, 8]])),
            draw: draw(.qlc, drawValues, [prize("二等奖", 10_000)])
        )
        XCTAssertEqual(result.prizeName, "二等奖")
    }

    func testQXCPositionAwareMatching() {
        let drawValues = NumberSet([.nums6: [1, 2, 3, 4, 5, 6], .tail: [7]])

        let first = PrizeRules.evaluate(
            gameKey: .qxc,
            ticket: ticket(NumberSet([.nums6: [1, 2, 3, 4, 5, 6], .tail: [7]])),
            draw: draw(.qxc, drawValues, [prize("一等奖", 5_000_000)])
        )
        XCTAssertEqual(first.amount, 5_000_000)

        // 前六位全错、只对上特别号 → 六等奖
        let tailOnly = PrizeRules.evaluate(
            gameKey: .qxc,
            ticket: ticket(NumberSet([.nums6: [9, 9, 9, 9, 9, 9], .tail: [7]])),
            draw: draw(.qxc, drawValues, [prize("六等奖", 5)])
        )
        XCTAssertEqual(tailOnly.prizeName, "六等奖")
    }

    // MARK: - 奖金文本

    func testMoneyParsing() {
        XCTAssertEqual(MoneyText.parse("1,234"), 1234)
        XCTAssertEqual(MoneyText.parse("500万"), 5_000_000)
        XCTAssertEqual(MoneyText.parse("1.2亿"), 120_000_000)
        XCTAssertEqual(MoneyText.parse(""), 0)
    }
}
