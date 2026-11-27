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

    /// 「随机」录入模式已经删掉，只保留手选里的随机填充；各彩种按真实票面规则开放复式与胆拖。
    func testEntryModesDropRandom() {
        XCTAssertEqual(EntryMode.modes(for: .ssq), [.manual, .system, .dantuo])
        XCTAssertEqual(EntryMode.modes(for: .qlc), [.manual, .system, .dantuo])
        XCTAssertEqual(EntryMode.modes(for: .k8), [.manual, .system, .dantuo])
        XCTAssertEqual(EntryMode.modes(for: .k8, playMode: "1"), [.manual, .system])
        XCTAssertEqual(EntryMode.modes(for: .pl3, playMode: "single"), [.manual, .system])
        XCTAssertEqual(EntryMode.modes(for: .pl3, playMode: "group3"), [.manual, .system, .dantuo])
        XCTAssertEqual(EntryMode.modes(for: .pl3, playMode: "group6"), [.manual, .system, .dantuo])
        XCTAssertEqual(EntryMode.modes(for: .pl5), [.manual, .system])
        XCTAssertEqual(EntryMode.modes(for: .qxc), [.manual, .system])
        XCTAssertEqual(EntryMode.allCases, [.manual, .system, .dantuo])
        XCTAssertEqual(EntryMode.manual.label, "单式票")
        XCTAssertEqual(EntryMode.system.label, "复式票")
        XCTAssertEqual(EntryMode.dantuo.label, "胆拖票")
    }

    /// 票面类型的显示名只有 `TicketShape` 一处，三条录入路径都落到它上面。
    func testTicketShapeIsSharedByEntryAndScan() {
        XCTAssertEqual(EntryMode.manual.shape, .single)
        XCTAssertEqual(EntryMode.system.shape, .system)
        XCTAssertEqual(EntryMode.dantuo.shape, .dantuo)

        XCTAssertEqual(ScanPlay.single.shape, .single)
        XCTAssertEqual(ScanPlay.system.shape, .system)
        XCTAssertEqual(ScanPlay.dantuo.shape, .dantuo)

        // 扫描导入的复式票和手动录入的复式票，在票夹里必须是同一个标签
        XCTAssertEqual(ScanPlay.system.label, EntryMode.system.label)
        XCTAssertEqual(ScanPlay.dantuo.label, EntryMode.dantuo.label)
    }

    /// 历史记录里的各种 `entryLabel` 写法都要能折回正确的票面类型。
    ///
    /// 这是上一版的真实事故：`shapeLabel` 按**全等**匹配「复式」「胆拖」，
    /// 只要把录入页的文案改一个字（比如改成「复式票」），所有新存的复式票
    /// 在票夹里就会被标成「单式」。改成包含判断之后，新旧写法都认得。
    func testShapeSurvivesEntryLabelRewording() {
        // 旧写法
        XCTAssertEqual(TicketShape.from(entryLabel: "复式"), .system)
        XCTAssertEqual(TicketShape.from(entryLabel: "胆拖"), .dantuo)
        XCTAssertEqual(TicketShape.from(entryLabel: "单式"), .single)
        // 旧录入方式写法，一律按单式票看
        XCTAssertEqual(TicketShape.from(entryLabel: "手选"), .single)
        XCTAssertEqual(TicketShape.from(entryLabel: "普通"), .single)
        XCTAssertEqual(TicketShape.from(entryLabel: "随机"), .single)
        XCTAssertEqual(TicketShape.from(entryLabel: "扫描"), .single)
        XCTAssertEqual(TicketShape.from(entryLabel: ""), .single)
        // 新写法
        XCTAssertEqual(TicketShape.from(entryLabel: "复式票"), .system)
        XCTAssertEqual(TicketShape.from(entryLabel: "胆拖票"), .dantuo)
        XCTAssertEqual(TicketShape.from(entryLabel: "单式票"), .single)

        // 当前录入 / 扫描实际会存进去的值，必须原样折回来
        for mode in EntryMode.allCases {
            XCTAssertEqual(TicketShape.from(entryLabel: mode.label), mode.shape)
        }
        for play in [ScanPlay.single, .system, .dantuo] {
            XCTAssertEqual(TicketShape.from(entryLabel: play.label), play.shape)
        }
        for kind in [EntryKind.random, .manual, .system, .dantuo, .scan] {
            XCTAssertEqual(TicketShape.from(entryLabel: kind.label), kind.shape)
        }
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

        // 玩法缺失时退回**彩种默认玩法**（选十），不是开奖的 20 个。
        //
        // 这条断言以前写的是 `section.count`（20），理由是「不至于算出 0 注」。
        // 那个理由成立，但 20 是个**永远无效**的答案：快乐8 一注最多选十，
        // 20 个号凑不出任何一注合法投注 —— 号码盘会要求选 20 个，用户
        // 永远选不完；`TicketBuilder.expand` 也会因为 `count != need`
        // 直接返回空数组，一张玩法丢了的快乐8 票注数变成 0。
        // 选十同样满足「不算出 0 注」，而且它本身是合法的。
        XCTAssertEqual(GameKey.k8.pickCount(for: section, playMode: ""), 10)
        XCTAssertEqual(GameKey.k8.defaultPlayMode, "10")

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

    // MARK: - 新增真实票面复式 / 胆拖 / 定位复式展开

    func testK8AndQlcSystemAndDantuoExpansion() throws {
        // 快乐8 选五复式 6 个号 → C(6,5) = 6 注
        let k8Sys = [SectionKey.nums: SectionSelection(selected: [1, 5, 12, 23, 34, 45])]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .k8, selections: k8Sys, mode: .system, playMode: "5"), 6)
        let k8SysTickets = try XCTUnwrap(TicketBuilder.expand(game: .k8, selections: k8Sys, mode: .system, playMode: "5", addOn: false))
        XCTAssertEqual(k8SysTickets.count, 6)
        XCTAssertTrue(k8SysTickets.allSatisfy { $0[.nums].count == 5 && $0.playCount == 5 })

        // 快乐8 选六胆拖 2 胆 6 拖 → C(6,4) = 15 注
        let k8Dan = [SectionKey.nums: SectionSelection(selected: [1, 2, 3, 4, 5, 6, 7, 8], dan: [1, 2])]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .k8, selections: k8Dan, mode: .dantuo, playMode: "6"), 15)
        let k8DanTickets = try XCTUnwrap(TicketBuilder.expand(game: .k8, selections: k8Dan, mode: .dantuo, playMode: "6", addOn: false))
        XCTAssertEqual(k8DanTickets.count, 15)
        XCTAssertTrue(k8DanTickets.allSatisfy { $0[.nums].contains(1) && $0[.nums].contains(2) })

        // 七乐彩 8 号复式 = 8 注；2 胆 7 拖 = C(7,5) = 21 注
        let qlcSys = [SectionKey.nums7: SectionSelection(selected: [1, 2, 3, 4, 5, 6, 7, 8])]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .qlc, selections: qlcSys, mode: .system), 8)
        let qlcDan = [SectionKey.nums7: SectionSelection(selected: Array(1...9), dan: [1, 2])]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .qlc, selections: qlcDan, mode: .dantuo), 21)
        let qlcDanTickets = try XCTUnwrap(TicketBuilder.expand(game: .qlc, selections: qlcDan, mode: .dantuo, playMode: "", addOn: false))
        XCTAssertEqual(qlcDanTickets.count, 21)
        XCTAssertTrue(qlcDanTickets.allSatisfy { $0[.nums7].contains(1) && $0[.nums7].contains(2) })
    }

    func testPickThreeGroupSystemAndDantuoExpansion() throws {
        // 组选3复式 2 个数字 → 2×1 = 2 注（[2,2,5] 和 [5,5,2]）
        let g3Two = [SectionKey.nums3: SectionSelection(selected: [2, 5])]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .pl3, selections: g3Two, mode: .system, playMode: "group3"), 2)
        let g3TwoTickets = try XCTUnwrap(TicketBuilder.expand(game: .pl3, selections: g3Two, mode: .system, playMode: "group3", addOn: false))
        XCTAssertEqual(g3TwoTickets.map { $0[.nums3] }, [[2, 2, 5], [5, 5, 2]])

        // 组选3胆拖 1 胆 3 拖 → 2×3 = 6 注
        let g3Dan = [SectionKey.nums3: SectionSelection(selected: [1, 3, 5, 8], dan: [1])]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .fc3d, selections: g3Dan, mode: .dantuo, playMode: "group3"), 6)
        let g3DanTickets = try XCTUnwrap(TicketBuilder.expand(game: .fc3d, selections: g3Dan, mode: .dantuo, playMode: "group3", addOn: false))
        XCTAssertEqual(g3DanTickets.count, 6)
        XCTAssertTrue(g3DanTickets.allSatisfy { $0[.nums3].contains(1) && Set($0[.nums3]).count == 2 })

        // 组选6胆拖 2 胆 4 拖 → C(4,1) = 4 注；1 胆 4 拖 → C(4,2) = 6 注
        let g6Dan2 = [SectionKey.nums3: SectionSelection(selected: [1, 2, 3, 4, 5, 6], dan: [1, 2])]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .pl3, selections: g6Dan2, mode: .dantuo, playMode: "group6"), 4)
        let g6Dan1 = [SectionKey.nums3: SectionSelection(selected: [1, 3, 4, 5, 6], dan: [1])]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .pl3, selections: g6Dan1, mode: .dantuo, playMode: "group6"), 6)
    }

    func testPositionalSystemExpansionForPl3Pl5AndQxc() throws {
        // 排列3 直选定位复式：[0,1] × [2,3,4] × [5] = 6 注
        let pl3Pos = [SectionKey.nums3: SectionSelection(positional: [[0, 1], [2, 3, 4], [5]])]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .pl3, selections: pl3Pos, mode: .system, playMode: "single"), 6)
        let pl3Tickets = try XCTUnwrap(TicketBuilder.expand(game: .pl3, selections: pl3Pos, mode: .system, playMode: "single", addOn: false))
        XCTAssertEqual(pl3Tickets.count, 6)
        XCTAssertEqual(pl3Tickets.first?[.nums3], [0, 2, 5])
        XCTAssertEqual(pl3Tickets.last?[.nums3], [1, 4, 5])
        XCTAssertEqual(GameKey.pl3.ticketLabel(modes: ["single"], shape: .system), "直选定位复式票")

        // 排列5 直选定位复式：[1,2] × [3] × [4,5] × [6] × [7,8,9] = 12 注
        let pl5Pos = [SectionKey.nums5: SectionSelection(positional: [[1, 2], [3], [4, 5], [6], [7, 8, 9]])]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .pl5, selections: pl5Pos, mode: .system), 12)
        XCTAssertEqual(TicketBuilder.expand(game: .pl5, selections: pl5Pos, mode: .system, playMode: "", addOn: false)?.count, 12)
        XCTAssertEqual(GameKey.pl5.ticketLabel(modes: [""], shape: .system), "直选定位复式票")

        // 七星彩 定位复式 + 特别号复式：2 × 1 × 1 × 1 × 1 × 1 × 2 = 4 注
        let qxcPos: [SectionKey: SectionSelection] = [
            .nums6: SectionSelection(positional: [[0, 1], [2], [3], [4], [5], [6]]),
            .tail: SectionSelection(selected: [7, 12])
        ]
        XCTAssertEqual(TicketBuilder.combinationCount(game: .qxc, selections: qxcPos, mode: .system), 4)
        XCTAssertEqual(TicketBuilder.expand(game: .qxc, selections: qxcPos, mode: .system, playMode: "", addOn: false)?.count, 4)
    }
}
