import XCTest
@testable import LotteryWallet

/// 复式与胆拖的展开注数，对应 web 版 `tests/product-v2.test.js` 里的组合校验。
final class TicketBuilderTests: XCTestCase {

    func testBinomial() {
        XCTAssertEqual(TicketBuilder.binomial(7, 6), 7)
        XCTAssertEqual(TicketBuilder.binomial(10, 5), 252)
        XCTAssertEqual(TicketBuilder.binomial(3, 5), 0)
    }

    func testCombinationsAreUniqueAndSized() {
        let result = TicketBuilder.combinations(of: [1, 2, 3, 4], choose: 2)
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(Set(result.map { $0.map(String.init).joined(separator: ",") }).count, 6)
    }

    /// 双色球红球复式 7 个 → 7 注。
    func testSSQSystemExpansion() {
        let selections: [SectionKey: SectionSelection] = [
            .red: SectionSelection(selected: [1, 2, 3, 4, 5, 6, 7]),
            .blue: SectionSelection(selected: [8])
        ]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .ssq, selections: selections, mode: .system), 7)
        let tickets = TicketBuilder.expand(game: .ssq, selections: selections, mode: .system, playMode: "", addOn: false)
        XCTAssertEqual(tickets?.count, 7)
        XCTAssertTrue(tickets?.allSatisfy { $0[.red].count == 6 && $0[.blue] == [8] } ?? false)
    }

    /// 双色球胆拖：2 胆 + 5 拖，红球从拖码里再选 4 个 → C(5,4) = 5 注。
    func testSSQDantuoExpansion() {
        let selections: [SectionKey: SectionSelection] = [
            .red: SectionSelection(selected: [1, 2, 3, 4, 5, 6, 7], dan: [1, 2]),
            .blue: SectionSelection(selected: [8])
        ]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .ssq, selections: selections, mode: .dantuo), 5)
        let tickets = TicketBuilder.expand(game: .ssq, selections: selections, mode: .dantuo, playMode: "", addOn: false)
        XCTAssertEqual(tickets?.count, 5)
        // 每一注都必须包含全部胆码
        XCTAssertTrue(tickets?.allSatisfy { $0[.red].contains(1) && $0[.red].contains(2) } ?? false)
    }

    /// 大乐透前区复式 6 个 + 后区复式 3 个 → 6 × 3 = 18 注。
    func testDLTSystemCrossProduct() {
        let selections: [SectionKey: SectionSelection] = [
            .front: SectionSelection(selected: [1, 2, 3, 4, 5, 6]),
            .back: SectionSelection(selected: [1, 2, 3])
        ]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .dlt, selections: selections, mode: .system), 18)
        XCTAssertEqual(TicketBuilder.expand(game: .dlt, selections: selections, mode: .system, playMode: "normal", addOn: false)?.count, 18)
    }

    /// 超过上限时返回 nil，不允许保存。
    func testOverLimitReturnsNil() {
        let selections: [SectionKey: SectionSelection] = [
            .red: SectionSelection(selected: Array(1...20)),
            .blue: SectionSelection(selected: [1])
        ]
        XCTAssertGreaterThan(TicketBuilder.combinationCount(game: .ssq, selections: selections, mode: .system),
                             TicketBuilder.maxCombinations)
        XCTAssertNil(TicketBuilder.expand(game: .ssq, selections: selections, mode: .system, playMode: "", addOn: false))
    }

    /// 数字型玩法按位取值，展开时不能排序。
    func testDigitSectionKeepsOrder() {
        let selections: [SectionKey: SectionSelection] = [.nums3: SectionSelection(selected: [3, 1, 2])]
        let tickets = TicketBuilder.expand(game: .fc3d, selections: selections, mode: .manual, playMode: "single", addOn: false)
        XCTAssertEqual(tickets?.first?[.nums3], [3, 1, 2])
    }

    /// 「随机」录入模式已经删掉，只保留手选里的随机填充。
    func testEntryModesDropRandom() {
        XCTAssertEqual(EntryMode.modes(for: .ssq), [.manual, .system, .dantuo])
        XCTAssertEqual(EntryMode.modes(for: .k8), [.manual])
        XCTAssertEqual(EntryMode.allCases, [.manual, .system, .dantuo])
        XCTAssertEqual(EntryMode.manual.label, "手选")
    }

    /// 组三必须出两个相同的号，组六必须三个都不同。
    /// 早期一律 `Int.random` 三次，选着组三却随出 1-5-9。
    func testRandomDigitsFollowPlayMode() {
        for _ in 0..<200 {
            let group3 = TicketBuilder.randomDigits(game: .fc3d, count: 3, range: 0...9, playMode: "group3")
            XCTAssertEqual(group3.count, 3)
            XCTAssertEqual(Set(group3).count, 2, "组三应当正好两个号相同：\(group3)")

            let group6 = TicketBuilder.randomDigits(game: .pl3, count: 3, range: 0...9, playMode: "group6")
            XCTAssertEqual(Set(group6).count, 3, "组六三个号必须互不相同：\(group6)")

            let single = TicketBuilder.randomDigits(game: .fc3d, count: 3, range: 0...9, playMode: "single")
            XCTAssertEqual(single.count, 3)
            XCTAssertTrue(single.allSatisfy { (0...9).contains($0) })
        }

        // 非 3 位的数字区（排列5、七星彩前六位）按位取值，允许重复
        let pl5 = TicketBuilder.randomDigits(game: .pl5, count: 5, range: 0...9, playMode: "")
        XCTAssertEqual(pl5.count, 5)
        XCTAssertTrue(pl5.allSatisfy { (0...9).contains($0) })
    }

    /// 快乐8 选几个号由玩法决定，不是开奖的 20 个。
    func testK8PickCountFollowsPlayMode() {
        guard let section = GameKey.k8.sections.first else { return XCTFail("快乐8 没有号码区") }
        XCTAssertEqual(GameKey.k8.pickCount(for: section, playMode: "5"), 5)
        XCTAssertEqual(GameKey.k8.pickCount(for: section, playMode: "10"), 10)
        // 玩法缺失时退回开奖个数，不至于算出 0 注
        XCTAssertEqual(GameKey.k8.pickCount(for: section, playMode: ""), section.count)

        let selections: [SectionKey: SectionSelection] = [.nums: SectionSelection(selected: [1, 2, 3, 4, 5])]
        XCTAssertEqual(
            TicketBuilder.combinationCount(game: .k8, selections: selections, mode: .manual, playMode: "5"),
            1
        )
    }

    /// 其余彩种不受影响：选几个就是开奖开几个。
    func testPickCountUnchangedForOtherGames() {
        for game in GameKey.ordered where game != .k8 {
            for section in game.sections {
                XCTAssertEqual(game.pickCount(for: section, playMode: game.defaultPlayMode), section.count)
            }
        }
    }
}
