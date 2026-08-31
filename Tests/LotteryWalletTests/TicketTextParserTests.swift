import XCTest
@testable import LotteryWallet

/// 票面文本解析测试。用例来自真实热敏票的常见排版和 OCR 误识别。
final class TicketTextParserTests: XCTestCase {

    func testParsesSSQTicket() {
        let text = """
        中国福利彩票 双色球
        第2026050期 开奖日 2026-05-06
        A 01 05 12 18 22 30 - 06
        B 03 09 11 24 28 33 - 14
        合计 4 元
        """
        let result = TicketTextParser.parse(text)
        XCTAssertEqual(result.game, .ssq)
        XCTAssertEqual(result.issue, "2026050")
        XCTAssertEqual(result.tickets.count, 2)
        XCTAssertEqual(result.tickets.first?.numbers[.red], [1, 5, 12, 18, 22, 30])
        XCTAssertEqual(result.tickets.first?.numbers[.blue], [6])
    }

    func testParsesDLTTicketWithoutPlusSign() {
        // 热敏票上的 "+" 常被吃掉，七个两位数要能按 5+2 拆
        let text = """
        中国体育彩票 超级大乐透
        第26050期
        01 05 12 18 22 03 11
        追加投注 2倍
        """
        let result = TicketTextParser.parse(text)
        XCTAssertEqual(result.game, .dlt)
        XCTAssertEqual(result.issue, "26050")
        XCTAssertEqual(result.tickets.first?.numbers[.front], [1, 5, 12, 18, 22])
        XCTAssertEqual(result.tickets.first?.numbers[.back], [3, 11])
        XCTAssertTrue(result.addOn)
        XCTAssertEqual(result.multiple, 2)
    }

    func testRejectsNonAscendingNumbers() {
        // 号码必须递增，乱序说明识别错了，宁可不认
        let tickets = TicketTextParser.parseSSQ("A 30 05 12 18 22 01 - 06")
        XCTAssertTrue(tickets.isEmpty)
    }

    func testRejectsOutOfRangeNumbers() {
        let tickets = TicketTextParser.parseSSQ("A 01 05 12 18 22 40 - 06")
        XCTAssertTrue(tickets.isEmpty)
    }

    func testCompactSequenceRecoversGluedNumbers() {
        // 号码粘连成一串时的兜底拆分
        let values = TicketTextParser.compactSequence("010512182230", count: 6, max: 33)
        XCTAssertEqual(values, [1, 5, 12, 18, 22, 30])
    }

    func testWarnsWhenTotalDoesNotMatch() {
        let text = """
        双色球 第2026050期
        A 01 05 12 18 22 30 - 06
        合计 6 元
        """
        let result = TicketTextParser.parse(text)
        XCTAssertEqual(result.tickets.count, 1)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testDetectsGameFromKeywords() {
        XCTAssertEqual(TicketTextParser.detectGame("中国福利彩票", ssq: [], dlt: []), .ssq)
        XCTAssertEqual(TicketTextParser.detectGame("中国体育彩票", ssq: [], dlt: []), .dlt)
        XCTAssertNil(TicketTextParser.detectGame("随便什么字", ssq: [], dlt: []))
    }
}
