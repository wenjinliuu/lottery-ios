import XCTest
@testable import LotteryWallet

/// 号码个数对不上的那几注，以前是**一声不吭地消失**：用户手里三注的票变成两注，
/// 而且看不出少在哪儿。
///
/// 现在分两种走：
/// - **少认了** → 差几个补几个问号，那一注留着（问号补齐前不许导入）
/// - **多认了** → `trimStray` 救不回来就说不出哪个多余，整注还是丢，但要留警告
final class MissingNumberTests: XCTestCase {

    /// 双色球读出 5 个红球：补一颗问号球，而不是把这一注扔掉。
    ///
    /// 红球是**无序集合**，位置本身没有意义，所以「差一个」这件事说得完整 ——
    /// 用户看到 5 颗球 + 1 颗问号球，点一下就补上。
    func testShortRedSectionKeepsTheBetWithAQuestionMark() {
        let text = """
        玩法: 双色球-单式   机号:31130622
        A.03 08 11 19 26-12 (1)
        B.06 08 13 21 29 32-04 (1)
        开奖期:2026106 26-09-13   合计4元
        """
        guard let ticket = TicketTextParser.parseTickets(text).first else {
            return XCTFail("整张票都没解析出来")
        }
        XCTAssertEqual(ticket.count, 2, "少一个红球的那一注不能丢")
        XCTAssertEqual(ticket.lines.first?[.red], [3, 8, 11, 19, 26, NumberSet.unknown])
        XCTAssertEqual(ticket.lines.first?[.blue], [12])
        XCTAssertTrue(ticket.hasUnknown, "补齐之前不许导入")
        XCTAssertEqual(ticket.unknownCount, 1)
    }

    /// **蓝球整个没读出来的那一类补不了，这里记一笔。**
    ///
    /// 票面印了 `-` 但后面什么都没认出来时，代码走的是「没找到分隔符、
    /// 按个数拆」那条兜底（`tail.isEmpty` 判的是内容不是有没有分隔符），
    /// 而按个数拆遇到 6 个号码根本分不清是"6 红缺蓝"还是"5 红 1 蓝" ——
    /// 说不清就不补，整注丢掉。这是有意的，不是漏掉的。
    func testMissingWholeBlueSectionIsAmbiguousAndDropped() {
        XCTAssertNil(TicketTextParser.singleLineForTesting("A.03 08 11 19 26 30-", game: .ssq))
    }

    /// **读出来还不到一半就不补。** 那多半根本不是号码行，
    /// 补一排问号只会凭空多出一注（硬约束二：宁可少认，不可错认）。
    func testTooFewNumbersIsNotABetAtAll() {
        XCTAssertNil(TicketTextParser.singleLineForTesting("A.03 08-12", game: .ssq))
    }

    /// 多认了就是丢 —— 但要留一句话，不能一声不吭。
    func testOverfullBetIsDroppedButReported() {
        let text = """
        玩法: 双色球-单式   机号:31130622
        A.03 08 11 19 26 30 31 33-12 (1)
        B.06 08 13 21 29 32-04 (1)
        开奖期:2026106 26-09-13   合计4元
        """
        guard let ticket = TicketTextParser.parseTickets(text).first else {
            return XCTFail("整张票都没解析出来")
        }
        XCTAssertEqual(ticket.count, 1, "八个红球那一注说不出哪个多余，只能丢")
        XCTAssertTrue(ticket.warnings.contains { $0.contains("比一注还多") },
                      "丢了就得说出来，实际警告：\(ticket.warnings)")
    }

    /// **机号行不许触发那条警告。**
    ///
    /// `110310-251461-120958-368897` 去掉分隔符之后同样是"一排数字"，
    /// 按两位拆开还有好几个落在红球值域里。分隔符最多一个这条界就是挡它的。
    func testMachineNumberLineDoesNotRaiseTheWarning() {
        XCTAssertFalse(TicketTextParser.looksLikeOverfullBet(
            "110310-251461-120958-368897 772489 Tc5xcQ", game: .ssq))
        XCTAssertFalse(TicketTextParser.looksLikeOverfullBet(
            "20-020689-102 00011 26/04/17 16:21:04", game: .ssq))
        XCTAssertTrue(TicketTextParser.looksLikeOverfullBet(
            "A.03 08 11 19 26 30 31 33-12", game: .ssq))
    }

    /// 数字型彩种不走这条路 —— 它们任何数字都合法，位置由格子路负责。
    func testDigitGamesAreNotJudgedByCount() {
        XCTAssertFalse(TicketTextParser.looksLikeOverfullBet("3 9 5 4 7 7 13", game: .qxc))
        XCTAssertFalse(TicketTextParser.looksLikeOverfullBet("8 4 4 1 5", game: .pl5))
    }

    /// 七乐彩（单区 7 个）少认一个也补问号。
    func testSingleZoneGameAlsoPads() {
        let set = TicketTextParser.singleLineForTesting("01 05 12 19 23 28", game: .qlc)
        XCTAssertEqual(set?[.nums7].count, 7)
        XCTAssertEqual(set?[.nums7].last, NumberSet.unknown)
    }
}
