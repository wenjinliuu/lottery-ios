import XCTest
@testable import LotteryWallet

/// 票面文本解析测试。
///
/// 用例是照着**真实样票**逐字抄下来的（用户提供的十六张双色球/大乐透照片），
/// 包括单式、复式、胆拖、号码换行、一张照片多张票。每个用例都用票面印的
/// 「合计 N 元」当作独立答案来验注数 —— 这是唯一不依赖我自己怎么解析的证据。
final class TicketTextParserTests: XCTestCase {

    /// 展开注数 × 单价 × 倍数 × 期数，必须等于票面合计。
    private func assertMatchesPrintedTotal(_ ticket: ScannedTicket,
                                           _ expected: Double,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        XCTAssertEqual(ticket.totalCost, expected, accuracy: 0.01,
                       "\(ticket.count) 注 × \(ticket.unitPrice) 元 × \(ticket.multiple) 倍 × \(ticket.periods) 期",
                       file: file, line: line)
    }

    // MARK: - 双色球复式

    /// 红单 6 个 + 蓝复 16 个 = 16 注 = 32 元。
    /// 这张票的蓝球是**一位数**打头（1 2 3 … 9 10 …），而且换了行。
    func testSSQSystemWithSingleDigitBlueAcrossTwoLines() {
        let text = """
        玩法:双色球-复式 46013721
        2BB4-E956-ED50-8170-03E0/42157673/07613
        红单:12 14 18 19 22 31
        蓝复: 1 2 3 4 5 6 7 8 9 10 11 12 13 14
        15 16
        倍数: 1
        开奖期:2026029 2026/03/17 ￥:32.00元
        销售期:2026029-2470 2026-03-17 19:47:33
        奖池余额:2403784926.00元
        028期开奖号码:02 06 09 17 25 28+15
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.game, .ssq)
        XCTAssertEqual(ticket.play, .system)
        XCTAssertEqual(ticket.selections[.red]?.selected, [12, 14, 18, 19, 22, 31])
        XCTAssertEqual(ticket.selections[.blue]?.selected, Array(1...16))
        XCTAssertEqual(ticket.issue, "2026029")
        XCTAssertEqual(ticket.count, 16)
        assertMatchesPrintedTotal(ticket, 32)
    }

    /// 票尾那行「028期开奖号码:…」是上一期的开奖号，绝不能当成本票号码。
    func testIgnoresPreviousDrawLine() {
        let text = """
        玩法:双色球-复式
        红单:12 14 18 19 22 31
        蓝复:01 02
        开奖期:2026029
        028期开奖号码:02 06 09 17 25 28+15
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.selections[.red]?.selected, [12, 14, 18, 19, 22, 31])
        XCTAssertEqual(ticket.selections[.blue]?.selected, [1, 2])
        XCTAssertEqual(ticket.count, 2)
    }

    /// 红复 7 个 + 蓝复 2 个 = C(7,6) × 2 = 14 注 = 28 元。
    func testSSQSystemRedSeven() {
        let text = """
        玩法:双色球-复式 机号:32030192
        8053-53AE-1CE9-E4D3-F960/40256562/B020E
        红复: 4 8 12 15 19 23 29
        蓝复: 9 11
        倍数:1
        开奖期:2025039
        合计28元
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.play, .system)
        XCTAssertEqual(ticket.selections[.red]?.selected, [4, 8, 12, 15, 19, 23, 29])
        XCTAssertEqual(ticket.count, 14)
        assertMatchesPrintedTotal(ticket, 28)
    }

    // MARK: - 双色球胆拖

    /// 红胆 4 + 红拖 3 → C(3,2)=3；蓝复 2 → 6 注 = 12 元。
    func testSSQDantuo() {
        let text = """
        玩法:双色球-胆拖 机号:31090329
        4F07-8512-85CF-E990-06A1/61955820/E020C
        红胆:05 14 22 27
        红拖:06 18 29
        蓝复:05 07
        倍数:1
        开奖期:2026034 26-03-29 合计12元
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.play, .dantuo)
        XCTAssertEqual(ticket.selections[.red]?.dan, [5, 14, 22, 27])
        XCTAssertEqual(ticket.selections[.red]?.tuo, [6, 18, 29])
        XCTAssertEqual(ticket.count, 6)
        assertMatchesPrintedTotal(ticket, 12)
    }

    /// 红胆 3 + 红拖 10（换行）→ C(10,3)=120；蓝单 1 → 120 注 = 240 元。
    func testSSQDantuoWithWrappedTuoLine() {
        let text = """
        玩法:双色球-胆拖 52010122
        E38E-A0AF-0E02-F736-1170/94351292/A050F
        红胆:03 09 17
        红拖:01 02 05 06 07 16 24 26
        27 33
        蓝单:02
        倍数:1
        开奖期:2024025 24-03-07 合计240元
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.selections[.red]?.dan, [3, 9, 17])
        XCTAssertEqual(ticket.selections[.red]?.tuo, [1, 2, 5, 6, 7, 16, 24, 26, 27, 33])
        XCTAssertEqual(ticket.selections[.blue]?.selected, [2])
        XCTAssertEqual(ticket.count, 120)
        assertMatchesPrintedTotal(ticket, 240)
    }

    // MARK: - 大乐透

    /// 前区 11 个 + 后区 3 个 = C(11,5) × C(3,2) = 462 × 3 = 1386 注 = 2772 元。
    /// 前区号码换了行。
    func testDLTSystemWithWrappedFrontLine() {
        let text = """
        体彩 超级大乐透
        第 26083期 2026年07月25日开奖
        110340-279661 285797 B3YYig
        复式票 1倍 合计2772元
        前区 07 09 11 12 14 23 28
        29 30 31 34
        后区 07 09 10
        感谢您为公益事业贡献 997.92元
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.game, .dlt)
        XCTAssertEqual(ticket.play, .system)
        XCTAssertEqual(ticket.issue, "26083")
        XCTAssertEqual(ticket.selections[.front]?.selected, [7, 9, 11, 12, 14, 23, 28, 29, 30, 31, 34])
        XCTAssertEqual(ticket.selections[.back]?.selected, [7, 9, 10])
        XCTAssertEqual(ticket.count, 1386)
        XCTAssertFalse(ticket.addOn, "单价 2 元，不是追加票")
        assertMatchesPrintedTotal(ticket, 2772)
    }

    /// 前区 6 + 后区 2，5 倍 = 6 注 × 2 元 × 5 = 60 元。
    func testDLTSystemWithMultiple() {
        let text = """
        体彩 超级大乐透
        第 26019期 2026年02月25日开奖
        复式票 5倍 合计60元
        前区 07 09 11 12 14 23
        后区 06 09
        感谢您为公益事业贡献 21.60元
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.multiple, 5)
        XCTAssertEqual(ticket.count, 6)
        assertMatchesPrintedTotal(ticket, 60)
    }

    /// 前区胆 4 + 前区拖 10（换行）→ C(10,1)=10；后区胆**是空行**、后区拖 2 → 1。
    /// 空的「后区胆」不能把下一行的号码吞掉。
    func testDLTDantuoWithEmptyBackDanLine() {
        let text = """
        体彩 超级大乐透
        第 26071期 2026年05月11日开奖
        胆拖票 1倍 合计20元
        前区胆 04 11 13 22
        前区拖 02 07 08 14 17 24 26
        28 30 35
        后区胆
        后区拖 03 09
        感谢您为公益事业贡献 7.20元
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.play, .dantuo)
        XCTAssertEqual(ticket.selections[.front]?.dan, [4, 11, 13, 22])
        XCTAssertEqual(ticket.selections[.front]?.tuo, [2, 7, 8, 14, 17, 24, 26, 28, 30, 35])
        XCTAssertEqual(ticket.selections[.back]?.dan, [])
        XCTAssertEqual(ticket.selections[.back]?.tuo, [3, 9])
        XCTAssertEqual(ticket.count, 10)
        assertMatchesPrintedTotal(ticket, 20)
    }

    /// 前区胆 2 + 前区拖 6 → C(6,3)=20；后区胆 1 + 后区拖 2 → C(2,1)=2 → 40 注 = 80 元。
    func testDLTDantuoWithBackDan() {
        let text = """
        体彩 超级大乐透
        第 26005期 2026年01月12日开奖
        胆拖票 1倍 合计80元
        前区胆 02 27
        前区拖 07 10 11 12 20 21
        后区胆 03
        后区拖 04 12
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.selections[.back]?.dan, [3])
        XCTAssertEqual(ticket.selections[.back]?.tuo, [4, 12])
        XCTAssertEqual(ticket.count, 40)
        assertMatchesPrintedTotal(ticket, 80)
    }

    // MARK: - 追加

    /// 追加是 3 元一注。前区 7 个 → C(7,5)=21 注，21 × 3 = 63 元。
    func testDLTAddOnUnitPriceIsThree() {
        let text = """
        体彩 超级大乐透
        第 26011期 2026年01月26日开奖
        追加票 1倍 合计63元
        前区 01 04 19 21 24 30 35
        后区 06 11
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertTrue(ticket.addOn)
        XCTAssertEqual(ticket.unitPrice, 3)
        XCTAssertEqual(ticket.count, 21)
        assertMatchesPrintedTotal(ticket, 63)
    }

    /// 「追加」两个字糊掉时，用合计 ÷ 注数 反推出 3 元一注，自动补上追加标志。
    func testAddOnRecoveredFromPrintedTotal() {
        let text = """
        体彩 超级大乐透
        第 26011期 2026年01月26日开奖
        复式票 1倍 合计18元
        前区 01 04 19 21 24 35
        后区 06 11
        """
        guard var ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.count, 6)
        XCTAssertFalse(ticket.addOn)
        TicketTextParser.reconcileAddOn(&ticket)
        XCTAssertTrue(ticket.addOn, "18 元 ÷ 6 注 = 3 元，只能是追加票")
        assertMatchesPrintedTotal(ticket, 18)
    }

    /// 连打三期：票面合计是三期总额，导入时要拆成三张。
    func testDLTMultiPeriod() {
        let text = """
        体彩 超级大乐透
        第 26011期 2026年01月26日开奖
        追加票 3期 1倍 合计54元
        前区 01 04 19 21 24 35
        后区 06 11
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.periods, 3)
        XCTAssertEqual(ticket.count, 6)
        XCTAssertEqual(ticket.costPerPeriod, 18, accuracy: 0.01, "每期 6 注 × 3 元")
        assertMatchesPrintedTotal(ticket, 54)
    }

    /// 「开奖期」「第26005期」「028期开奖号码」里的「期」都不是期数。
    func testPeriodsDefaultsToOne() {
        XCTAssertEqual(TicketTextParser.extractPeriods("开奖期:2026029\n028期开奖号码:02 06"), 1)
        XCTAssertEqual(TicketTextParser.extractPeriods("第 26083期 2026年07月25日开奖\n复式票 1倍"), 1)
    }

    // MARK: - 单式与多票

    /// A/B/C 三注单式，D/E 是空注；括号里的 (3) 是每注倍数。
    func testSSQSingleWithLineLabels() {
        let text = """
        玩法:双色球-单式 机号:31130622
        209A-6B15-7F8B-C986-5379/99038554/4EE01
        A.04 08 14 24 26 29-03 (3)
        B.06 07 12 27 30 33-15 (3)
        C.04 07 16 17 30 31-04 (3)
        D.-- -- -- -- -- ---- (-)
        E.-- -- -- -- -- ---- (-)
        开奖期:2026101 26-09-01 合计18元
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.play, .single)
        XCTAssertEqual(ticket.count, 3, "D、E 是空注，不能算进来")
        XCTAssertEqual(ticket.multiple, 3)
        XCTAssertEqual(ticket.lines.first?[.red], [4, 8, 14, 24, 26, 29])
        XCTAssertEqual(ticket.lines.first?[.blue], [3])
        assertMatchesPrintedTotal(ticket, 18)
    }

    /// 一张照片里三张票：每张各有自己的期号。
    func testSplitsMultipleTicketsInOnePhoto() {
        let text = """
        玩法:双色球-单式 机号:31130622
        A.04 08 14 24 26 29-03 (3)
        开奖期:2026101 26-09-01 合计18元
        玩法:双色球-单式 机号:31130622
        A.04 08 14 24 26 29-03 (3)
        开奖期:2026102 26-09-03 合计18元
        玩法:双色球-单式 机号:31130622
        A.04 08 14 24 26 29-03 (3)
        开奖期:2026103 26-09-06 合计18元
        """
        let result = TicketTextParser.parse(text)
        XCTAssertEqual(result.tickets.count, 3)
        XCTAssertEqual(result.tickets.map(\.issue), ["2026101", "2026102", "2026103"])
    }

    // MARK: - 号码抽取本身

    /// 一位数的号码不能被吞掉 —— 蓝球复式经常印成 `1 2 3 … 9 10`。
    func testNumbersKeepsSingleDigits() {
        XCTAssertEqual(TicketTextParser.numbers(in: "1 2 3 4 5 6 7 8 9 10 11", range: 1...16),
                       [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    }

    /// 热敏票把号码粘在一起时按两位一组拆。
    func testNumbersSplitsGluedDigits() {
        XCTAssertEqual(TicketTextParser.numbers(in: "010512182230", range: 1...33),
                       [1, 5, 12, 18, 22, 30])
    }

    /// `numbers` 只按取值范围过滤，**挡不住**机号这种长数字串 ——
    /// `32030192` 拆成两位是 32、03、01，全都落在红球的 1–33 里。
    /// 这正是为什么续行判断不能只看「这一行是不是只有数字」。
    func testNumbersOnlyFiltersByRange() {
        XCTAssertEqual(TicketTextParser.numbers(in: "32030192", range: 1...33), [32, 3, 1])
    }

    /// 机号、条码、销售期流水号都是一长串数字，不能被当成号码续行吞进来。
    func testRejectsLongDigitRunAsContinuation() {
        XCTAssertFalse(TicketTextParser.isNumberOnlyLine("32030192"))
        XCTAssertFalse(TicketTextParser.isNumberOnlyLine("2026029 2470"))
        XCTAssertTrue(TicketTextParser.isNumberOnlyLine("27 33"))
    }

    /// OCR 把「机号:」几个字漏掉时，那一行不能接到上一行的号码后面。
    func testMachineNumberLineDoesNotExtendPreviousZone() {
        let text = """
        玩法:双色球-复式
        红复: 4 8 12 15 19 23 29
        32030192
        蓝复: 9 11
        开奖期:2025039
        合计28元
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.selections[.red]?.selected, [4, 8, 12, 15, 19, 23, 29],
                       "机号那一行不能并进红球")
        XCTAssertEqual(ticket.count, 14)
    }

    /// 只有数字和空格的行才算续行。
    func testNumberOnlyLineDetection() {
        XCTAssertTrue(TicketTextParser.isNumberOnlyLine("27 33"))
        XCTAssertTrue(TicketTextParser.isNumberOnlyLine("  15 16  "))
        XCTAssertFalse(TicketTextParser.isNumberOnlyLine("028期开奖号码:02 06 09"))
        XCTAssertFalse(TicketTextParser.isNumberOnlyLine("倍数: 1"))
        XCTAssertFalse(TicketTextParser.isNumberOnlyLine(""))
    }
}
