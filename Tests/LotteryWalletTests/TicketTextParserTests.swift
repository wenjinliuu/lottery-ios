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

    // MARK: - 体彩单式票的圈码注序号

    /// 大乐透单式票的行首是 **①②③**，不是福彩那样的 A./B./C.。
    ///
    /// 圈码在 Unicode 里是带数值的数字字符（`①` 的 numericValue 就是 1），
    /// 会被当成一个前区号读进来 —— 前区变成 6 个号，整行判无效丢掉。
    /// 这张票以前是**一注都进不来**。
    func testDLTSingleWithCircledLineNumbers() {
        let text = """
        wenjin
        体彩 超级大乐透
        第 26089期 2026年08月08日开奖
        110310-283661-111909-977872 410541 6ycSgw
        单式票 追加投注2倍 合计18元
        ① 12 15 17 24 33 + 04 12
        ② 07 13 16 26 30 + 01 10
        ③ 01 05 09 29 33 + 01 11
        支付宝或微信扫码进入官方小程序
        感谢您为公益事业贡献 6.48元
        20-020689-101 00654 26/08/08 12:18:20
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.game, .dlt)
        XCTAssertEqual(ticket.play, .single)
        XCTAssertEqual(ticket.issue, "26089")
        XCTAssertEqual(ticket.count, 3)
        XCTAssertEqual(ticket.lines[0][.front], [12, 15, 17, 24, 33])
        XCTAssertEqual(ticket.lines[0][.back], [4, 12])
        XCTAssertEqual(ticket.lines[1][.front], [7, 13, 16, 26, 30])
        XCTAssertEqual(ticket.lines[2][.front], [1, 5, 9, 29, 33])
        XCTAssertEqual(ticket.lines[2][.back], [1, 11])
        XCTAssertTrue(ticket.addOn, "「追加投注2倍」")
        XCTAssertEqual(ticket.multiple, 2)
        XCTAssertEqual(ticket.periods, 1, "「2倍」不能被当成期数")
        // 3 注 × 3 元（追加）× 2 倍 = 18 元
        assertMatchesPrintedTotal(ticket, 18)
    }

    /// 同一批样票的另外两张，号码不同、结构一样。
    func testDLTSingleAddOnSamples() {
        let samples: [(text: String, issue: String, front: [Int], back: [Int])] = [
            ("""
             体彩 超级大乐透
             第 26087期 2026年08月03日开奖
             110310-282261-111900-298308 059607 QyqjNQ
             单式票 追加投注2倍 合计18元
             ① 01 11 14 16 17 + 10 11
             ② 03 04 10 12 17 + 07 09
             ③ 03 07 09 15 17 + 09 11
             感谢您为公益事业贡献 6.48元
             """, "26087", [1, 11, 14, 16, 17], [10, 11]),
            ("""
             体彩 超级大乐透
             第 26085期 2026年07月29日开奖
             110310-281061-111891-295552 729610 Fy9gDQ
             单式票 追加投注2倍 合计18元
             ① 01 03 13 14 23 + 02 06
             ② 10 15 16 26 35 + 06 09
             ③ 08 22 27 30 35 + 08 12
             感谢您为公益事业贡献 6.48元
             """, "26085", [1, 3, 13, 14, 23], [2, 6])
        ]
        for sample in samples {
            guard let ticket = TicketTextParser.parse(sample.text).tickets.first else {
                return XCTFail("第 \(sample.issue) 期没解析出票")
            }
            XCTAssertEqual(ticket.issue, sample.issue)
            XCTAssertEqual(ticket.count, 3, "第 \(sample.issue) 期注数不对")
            XCTAssertEqual(ticket.lines[0][.front], sample.front)
            XCTAssertEqual(ticket.lines[0][.back], sample.back)
            XCTAssertTrue(ticket.addOn)
            XCTAssertEqual(ticket.multiple, 2)
            assertMatchesPrintedTotal(ticket, 18)
        }
    }

    /// 福彩单式票：A/B/C 三注 + 每注 (3) 倍，D/E 是空注。
    func testSSQSingleSamples() {
        let samples: [(text: String, issue: String, red: [Int], blue: Int)] = [
            ("""
             wen
             中国福利彩票 CHINA WELFARE LOTTERY
             玩法: 双色球-单式 机号: 31130622
             D33C-990B-B696-FD36-0878/28340987/4AB52
             A.11 15 23 24 25 27-10 (3)
             B.08 09 17 18 20 28-11 (3)
             C.02 04 11 17 24 30-06 (3)
             D.-- -- -- -- -- ----- (-)
             E.-- -- -- -- -- ----- (-)
             开奖期:2026089 26-08-04 合计18元
             销售期:2026089-67 26-08-04 09:38:12
             亭知路272-1号
             感谢您为公益慈善事业贡献6.48元
             """, "2026089", [11, 15, 23, 24, 25, 27], 10),
            ("""
             wen
             中国福利彩票 CHINA WELFARE LOTTERY
             玩法: 双色球-单式 机号:31130622
             03C6-2000-87CF-8EA0-262D/76217677/1E911
             A.20 22 26 28 29 33-07 (3)
             B.03 05 11 17 23 25-06 (3)
             C.01 05 07 12 19 21-07 (3)
             D.-- -- -- -- -- ----- (-)
             E.-- -- -- -- -- ----- (-)
             开奖期:2026084 26-07-23 合计18元
             销售期:2026084-122 26-07-23 11:46:53
             亭知路272-1号
             感谢您为公益慈善事业贡献6.48元
             """, "2026084", [20, 22, 26, 28, 29, 33], 7)
        ]
        for sample in samples {
            guard let ticket = TicketTextParser.parse(sample.text).tickets.first else {
                return XCTFail("第 \(sample.issue) 期没解析出票")
            }
            XCTAssertEqual(ticket.game, .ssq)
            XCTAssertEqual(ticket.issue, sample.issue)
            XCTAssertEqual(ticket.count, 3, "D、E 是空注，不能算进来")
            XCTAssertEqual(ticket.lines[0][.red], sample.red)
            XCTAssertEqual(ticket.lines[0][.blue], [sample.blue])
            XCTAssertEqual(ticket.multiple, 3)
            XCTAssertFalse(ticket.addOn)
            assertMatchesPrintedTotal(ticket, 18)
        }
    }

    /// 五张样票的公益金都是面额的 36%（6.48 / 18），和首页那条统计口径一致。
    func testWelfareShareMatchesPrintedAmount() {
        XCTAssertEqual(18 * 0.36, 6.48, accuracy: 0.001)
    }

    /// 注序号只摘明确的形式，绝不摘裸的数字 —— 摘掉「11 15 23」开头那个 1
    /// 会让整注红球全错。
    func testDoesNotStripBareLeadingNumber() {
        let text = """
        玩法:双色球-单式
        11 15 23 24 25 27-10
        开奖期:2026089
        合计2元
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.lines.first?[.red], [11, 15, 23, 24, 25, 27])
    }

    /// 行首的 `(1)` 是注序号，不是倍数 —— 倍数只认行尾那个括号。
    func testLeadingParenthesisIsNotAMultiple() {
        let text = """
        体彩 超级大乐透
        第 26089期
        单式票 合计2元
        (1) 12 15 17 24 33 + 04 12
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.lines.first?[.front], [12, 15, 17, 24, 33])
        XCTAssertEqual(ticket.multiple, 1)
        assertMatchesPrintedTotal(ticket, 2)
    }

    // MARK: - 追加连打多期

    /// 「追加投注3期2倍」：同一组号码往后连打三期，票面合计是三期总额。
    ///
    /// 3 注 × 3 元（追加）× 2 倍 × 3 期 = 54 元，和票面「合计54元」对上；
    /// 公益金 54 × 36% = 19.44 元，也和票面印的一致。
    func testDLTAddOnThreePeriods() {
        let text = """
        wen
        体彩 超级大乐透
        第 26099期 2026年08月31日开奖
        110310-290261-111954-115593 472728 NxxmsQ
        单式票 追加投注3期2倍 合计54元
        ① 07 08 12 22 26 + 05 09
        ② 04 12 13 23 31 + 05 07
        ③ 01 03 11 14 34 + 04 12
        扫码参与"迈开步 动出彩"
        线上活动赢好礼
        感谢您为公益事业贡献 19.44元
        20-020689-101 00251 26/08/31 11:49:00
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.game, .dlt)
        XCTAssertEqual(ticket.issue, "26099")
        XCTAssertEqual(ticket.count, 3)
        XCTAssertEqual(ticket.lines[0][.front], [7, 8, 12, 22, 26])
        XCTAssertEqual(ticket.lines[0][.back], [5, 9])
        XCTAssertEqual(ticket.lines[1][.front], [4, 12, 13, 23, 31])
        XCTAssertEqual(ticket.lines[2][.front], [1, 3, 11, 14, 34])
        XCTAssertEqual(ticket.lines[2][.back], [4, 12])
        XCTAssertTrue(ticket.addOn)
        XCTAssertEqual(ticket.periods, 3, "「3期」是期数")
        XCTAssertEqual(ticket.multiple, 2, "「2倍」是倍数，别和期数搞反")
        XCTAssertEqual(ticket.costPerPeriod, 18, accuracy: 0.01, "每期 3 注 × 3 元 × 2 倍")
        assertMatchesPrintedTotal(ticket, 54)
        // 票面印的公益金 19.44 元 = 54 × 36%
        XCTAssertEqual(ticket.totalCost * 0.36, 19.44, accuracy: 0.01)
    }

    /// 「追加投注2期2倍」：3 注 × 3 元 × 2 倍 × 2 期 = 36 元，公益金 12.96 元。
    func testDLTAddOnTwoPeriods() {
        let text = """
        wenjin
        体彩 超级大乐透
        第 26097期 2026年08月26日开奖
        110310-289061-111943-846513 259907 w/iScg
        单式票 追加投注2期2倍 合计36元
        ① 03 12 13 26 29 + 04 05
        ② 04 15 16 26 29 + 02 04
        ③ 01 16 23 33 35 + 05 06
        感谢您为公益事业贡献 12.96元
        20-020689-101 00311 26/08/25 11:49:28
        """
        guard let ticket = TicketTextParser.parse(text).tickets.first else { return XCTFail("没解析出票") }
        XCTAssertEqual(ticket.issue, "26097")
        XCTAssertEqual(ticket.count, 3)
        XCTAssertEqual(ticket.lines[0][.front], [3, 12, 13, 26, 29])
        XCTAssertEqual(ticket.lines[2][.back], [5, 6])
        XCTAssertTrue(ticket.addOn)
        XCTAssertEqual(ticket.periods, 2)
        XCTAssertEqual(ticket.multiple, 2)
        assertMatchesPrintedTotal(ticket, 36)
        XCTAssertEqual(ticket.totalCost * 0.36, 12.96, accuracy: 0.01)
    }

    /// 期数和倍数写在同一段里（`3期2倍`），不能互相串。
    func testPeriodsAndMultipleAreNotConfused() {
        XCTAssertEqual(TicketTextParser.extractPeriods("单式票 追加投注3期2倍 合计54元"), 3)
        XCTAssertEqual(TicketTextParser.extractMultiple("单式票 追加投注3期2倍 合计54元"), 2)
        XCTAssertEqual(TicketTextParser.extractPeriods("单式票 追加投注2期2倍 合计36元"), 2)
        XCTAssertEqual(TicketTextParser.extractMultiple("单式票 追加投注2期2倍 合计36元"), 2)
        // 没写期数的追加票就是一期
        XCTAssertEqual(TicketTextParser.extractPeriods("单式票 追加投注2倍 合计18元"), 1)
        XCTAssertEqual(TicketTextParser.extractMultiple("单式票 追加投注2倍 合计18元"), 2)
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
