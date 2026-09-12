import XCTest
@testable import LotteryWallet

/// 按坐标补位的几何核心。
///
/// 这是整条路上唯一有可能**把号码摆错位**的一步，所以判据要钉死：
/// 宁可什么都不返回（退回文本那一遍），也不能把第 3 位的数字摆到第 2 位上 ——
/// 那样用户会照着一注错号去核奖，比"没识别出来"糟得多。
final class DigitRowReaderTests: XCTestCase {

    private func observed(_ pairs: [(Int, CGFloat)]) -> [DigitRowReader.Observation] {
        pairs.map { DigitRowReader.Observation(value: $0.0, center: $0.1) }
    }

    /// 一位没漏：五个等距字符，栅格就是它们自己。
    func testFullRowMapsOneToOne() {
        let row = observed([(8, 0.10), (4, 0.25), (4, 0.40), (1, 0.55), (5, 0.70)])
        let grid = DigitRowReader.layout(row, expected: 5)
        XCTAssertEqual(grid?.indices, [0, 1, 2, 3, 4])
        XCTAssertEqual(grid?.slack, 0)
        XCTAssertEqual(grid?.pitch ?? 0, 0.15, accuracy: 0.001)
    }

    /// 中间漏了两位：`8 4 4 1 5` 只认出 `8 4 5`。
    /// 间距 0.15 / 0.45 / 0.30 → 步距 0.15，两个洞的位置是**算出来的**。
    func testInteriorHolesLandOnTheRightSlots() {
        let row = observed([(8, 0.10), (4, 0.25), (5, 0.70)])
        guard let grid = DigitRowReader.layout(row, expected: 5) else {
            return XCTFail("应该摆得上栅格")
        }
        XCTAssertEqual(grid.indices, [0, 1, 4])
        XCTAssertEqual(grid.slack, 0)
        let slots = DigitRowReader.slots(row, layout: grid, expected: 5, offset: 0)
        XCTAssertEqual(slots, [8, 4, nil, nil, 5])
    }

    /// 空槽的中心是算出来的，不是猜的 —— 单独裁图重认就按这个坐标去裁。
    func testPredictedSlotCenters() {
        let row = observed([(8, 0.10), (4, 0.25), (5, 0.70)])
        guard let grid = DigitRowReader.layout(row, expected: 5) else {
            return XCTFail("应该摆得上栅格")
        }
        XCTAssertEqual(DigitRowReader.center(of: 2, layout: grid, offset: 0, first: 0.10),
                       0.40, accuracy: 0.001)
        XCTAssertEqual(DigitRowReader.center(of: 3, layout: grid, offset: 0, first: 0.10),
                       0.55, accuracy: 0.001)
    }

    /// 只认出三位、栅格只铺得下三格：剩下两格在两头，具体哪一头栅格说了不算，
    /// 所以 `slack` 要如实报出来，由调用方裁图去试。
    func testSlackWhenGridIsShorterThanExpected() {
        let row = observed([(3, 0.30), (6, 0.45), (7, 0.60)])
        let grid = DigitRowReader.layout(row, expected: 5)
        XCTAssertEqual(grid?.indices, [0, 1, 2])
        XCTAssertEqual(grid?.slack, 2)
    }

    /// `slack` 往右挪一格，认出来的三位就落在第 2、3、4 位上。
    func testOffsetShiftsTheWholeGrid() {
        let row = observed([(3, 0.30), (6, 0.45), (7, 0.60)])
        guard let grid = DigitRowReader.layout(row, expected: 5) else {
            return XCTFail("应该摆得上栅格")
        }
        XCTAssertEqual(DigitRowReader.slots(row, layout: grid, expected: 5, offset: 0),
                       [3, 6, 7, nil, nil])
        XCTAssertEqual(DigitRowReader.slots(row, layout: grid, expected: 5, offset: 2),
                       [nil, nil, 3, 6, 7])
    }

    // MARK: - 摆不上就一个都别摆

    /// 间距根本不是整数倍（票没印在等距栅格上，或者混进了别的字符）。
    func testRejectsNonUniformSpacing() {
        let row = observed([(1, 0.10), (2, 0.25), (3, 0.47)])
        XCTAssertNil(DigitRowReader.layout(row, expected: 5))
    }

    /// 认出来的比该有的还多 —— 裁条里混了倍数或机号残字。
    func testRejectsMoreCharactersThanExpected() {
        let row = observed([(1, 0.1), (2, 0.2), (3, 0.3), (4, 0.4)])
        XCTAssertNil(DigitRowReader.layout(row, expected: 3))
    }

    /// 只认出一个字符时估不出步距，摆哪儿都是瞎猜。
    func testRejectsSingleCharacterWhenMoreExpected() {
        XCTAssertNil(DigitRowReader.layout(observed([(7, 0.4)]), expected: 3))
    }

    /// 字符必须按横坐标排好才谈得上栅格。
    func testRejectsUnsortedInput() {
        let row = observed([(1, 0.4), (2, 0.1)])
        XCTAssertNil(DigitRowReader.layout(row, expected: 3))
    }

    /// 栅格铺出来比该有的还长，说明步距估错了（多半是把两位数的两个字符
    /// 当成了两个号）。这时候一个都别摆。
    func testRejectsGridLongerThanExpected() {
        let row = observed([(1, 0.10), (2, 0.25), (3, 0.70)])
        XCTAssertNil(DigitRowReader.layout(row, expected: 3))
    }

    // MARK: - 七星彩：特别号印成两位时必须自己判不成立

    /// `3 9 5 4 7 7 13` —— 最后那个 `13` 的两个字符挨得比印刷步距近得多，
    /// 最小间距被它带偏，其余间距就成了两格，栅格铺出来比七位长。
    /// 这时候必须退回文本那一遍（那条路读得出两位的特别号）。
    func testQixingcaiTwoDigitTailFallsBack() {
        let row = observed([(3, 0.10), (9, 0.20), (5, 0.30), (4, 0.40),
                            (7, 0.50), (7, 0.60), (1, 0.70), (3, 0.74)])
        XCTAssertNil(DigitRowReader.layout(row, expected: 7))
    }

    /// 特别号是一位数时（约七成的票）栅格是成立的。
    func testQixingcaiSingleDigitTailFitsTheGrid() {
        let row = observed([(3, 0.10), (9, 0.20), (5, 0.30), (4, 0.40),
                            (7, 0.50), (7, 0.60), (8, 0.70)])
        XCTAssertEqual(DigitRowReader.layout(row, expected: 7)?.slack, 0)
    }
}

/// 问号要能一路走到复核页：解析、计数、导入闸门。
final class UnknownDigitPlumbingTests: XCTestCase {

    /// 排列5 少认一位，从前整注丢掉、用户看到「没有识别到彩票」。
    /// 现在带着问号读出来，另外四位照样是对的。
    func testPositionalLineKeepsUnknownSlot() {
        let numbers = TicketTextParser.singleLineForTesting("① 8 4 ? 1 5", game: .pl5)
        XCTAssertEqual(numbers?[.nums5], [8, 4, NumberSet.unknown, 1, 5])
    }

    /// 顺序不能动：`0 4 4` 和 `4 0 4` 是两注不同的号。
    func testPositionalLineKeepsOrderAndRepeats() {
        XCTAssertEqual(TicketTextParser.singleLineForTesting("组六: 4 0 4", game: .fc3d)?[.nums3],
                       [4, 0, 4])
    }

    /// 七星彩：特别号是一位数时问号也落得下。
    func testQixingcaiKeepsUnknownSlot() {
        let numbers = TicketTextParser.singleLineForTesting("① 3 9 ? 4 7 7 8", game: .qxc)
        XCTAssertEqual(numbers?[.nums6], [3, 9, NumberSet.unknown, 4, 7, 7])
        XCTAssertEqual(numbers?[.tail], [8])
    }

    /// 特别号印成两位时仍然走原来那条路，不受问号改动影响。
    func testQixingcaiTwoDigitTailStillParses() {
        let numbers = TicketTextParser.singleLineForTesting("① 3 9 5 4 7 7 13", game: .qxc)
        XCTAssertEqual(numbers?[.nums6], [3, 9, 5, 4, 7, 7])
        XCTAssertEqual(numbers?[.tail], [13])
    }

    /// 位数不齐的行照旧读不成一注 —— 问号只补"知道位置但不知道值"的那一位，
    /// 不是把什么都放进来。
    func testShortLineStillRejected() {
        XCTAssertNil(TicketTextParser.singleLineForTesting("① 8 4 1", game: .pl5))
    }

    /// 有问号的票不许导入，而且要数得出还差几位。
    func testTicketCountsUnknownsAndBlocksImport() {
        var ticket = ScannedTicket(game: .pl5)
        ticket.lines = [NumberSet([.nums5: [8, 4, NumberSet.unknown, 1, NumberSet.unknown]])]
        XCTAssertTrue(ticket.hasUnknown)
        XCTAssertEqual(ticket.unknownCount, 2)
        // 注数照算 —— 这一注是存在的，只是还没填完
        XCTAssertEqual(ticket.count, 1)
    }

    /// 补齐之后就不再拦着。
    func testFilledTicketIsClean() {
        var ticket = ScannedTicket(game: .pl5)
        ticket.lines = [NumberSet([.nums5: [8, 4, 4, 1, 5]])]
        XCTAssertFalse(ticket.hasUnknown)
        XCTAssertEqual(ticket.unknownCount, 0)
    }

    /// 栅格铺成文本：认不出的那一位写成 `?`，解析器才接得住。
    func testSlotTextUsesQuestionMarks() {
        XCTAssertEqual(TicketVisionScanner.slotText([8, 4, nil, 1, 5]), "8 4 ? 1 5")
        XCTAssertEqual(TicketVisionScanner.slotText([nil, nil]), "? ?")
    }

    /// 只有每一位恰好印一个字符的彩种才摆得上栅格。
    /// 七乐彩、快乐8 印的是两位数，双色球、大乐透还带分隔符 —— 都不走这条路，
    /// 它们本来也不需要：两位数 + 窄值域 + 定长注自带纠错冗余。
    func testOnlySingleDigitGamesUsePositionalRecovery() {
        XCTAssertEqual(TicketVisionScanner.positionalDigitCount(.pl3), 3)
        XCTAssertEqual(TicketVisionScanner.positionalDigitCount(.fc3d), 3)
        XCTAssertEqual(TicketVisionScanner.positionalDigitCount(.pl5), 5)
        XCTAssertEqual(TicketVisionScanner.positionalDigitCount(.qxc), 7)
        XCTAssertNil(TicketVisionScanner.positionalDigitCount(.qlc))
        XCTAssertNil(TicketVisionScanner.positionalDigitCount(.k8))
        XCTAssertNil(TicketVisionScanner.positionalDigitCount(.ssq))
        XCTAssertNil(TicketVisionScanner.positionalDigitCount(.dlt))
    }
}
