import XCTest
@testable import LotteryWallet

/// Vision 的读数和模型的读数怎么合成一个结论。
///
/// 这里的规矩只有一条总纲：**不能因为多了一个读数而多出一个错号**。
/// 所以每一种「采纳模型」的情况旁边，都有一个「这时候不能采纳」的测试。
final class ModelFusionTests: XCTestCase {

    /// 一行号码的模型读数。空格是空隙，x 是「不是数字」，小写 l 是「没把握的 1」。
    private func row(_ text: String) -> [GlyphRows.Token] {
        var out: [GlyphRows.Token] = []
        var x = 0
        for character in text {
            defer { x += 30 }
            guard character != " " else { continue }
            let unsure = character == "l"
            let digit = character == "x" ? DigitClassifier.reject : (unsure ? 1 : Int(String(character))!)
            out.append(.init(digit: digit, confidence: unsure ? 0.5 : 0.99,
                             segment: .init(x0: x, x1: x + 24, y0: 0, y1: 40)))
        }
        return out
    }

    private func dlt(_ lines: [([Int], [Int])]) -> ScannedTicket {
        var ticket = ScannedTicket(game: .dlt)
        ticket.lines = lines.map { NumberSet([.front: $0.0, .back: $0.1]) }
        return ticket
    }

    private let rows = ["x 05 12 23 30 35 02 11", "x 01 08 17 26 34 06 09", "x 03 04 16 20 26 04 11"]

    func testAgreementLeavesTheTicketAlone() {
        var ticket = dlt([([5, 12, 23, 30, 35], [2, 11]), ([1, 8, 17, 26, 34], [6, 9]), ([3, 4, 16, 20, 26], [4, 11])])
        let before = ticket
        let report = ModelFusion.fuse(&ticket, rows: rows.map(row))
        XCTAssertEqual(ticket.lines, before.lines)
        XCTAssertEqual(report.read, 3)
        XCTAssertEqual(report.confirmed, 21)
        XCTAssertEqual(report.filled, 0)
        XCTAssertEqual(report.disputed, 0)
    }

    func testModelFillsWhatVisionMissed() {
        var ticket = dlt([([5, -1, 23, 30, 35], [2, -1]), ([1, 8, 17, 26, 34], [6, 9]), ([-1, 4, 16, 20, 26], [4, 11])])
        let report = ModelFusion.fuse(&ticket, rows: rows.map(row))
        XCTAssertEqual(ticket.lines[0][.front], [5, 12, 23, 30, 35])
        XCTAssertEqual(ticket.lines[0][.back], [2, 11])
        XCTAssertEqual(ticket.lines[2][.front], [3, 4, 16, 20, 26])
        XCTAssertEqual(report.filled, 3)
        XCTAssertFalse(ticket.hasUnknown)
    }

    func testDisagreementBecomesAQuestionMarkNotEitherReading() {
        // Vision 把 23 读成了 28
        var ticket = dlt([([5, 12, 28, 30, 35], [2, 11]), ([1, 8, 17, 26, 34], [6, 9]), ([3, 4, 16, 20, 26], [4, 11])])
        let report = ModelFusion.fuse(&ticket, rows: rows.map(row))
        XCTAssertEqual(ticket.lines[0][.front], [5, 12, -1, 30, 35])
        XCTAssertEqual(report.disputed, 1)
    }

    func testUnsureModelNeitherFillsNorOverrules() {
        // 模型对「12」里的 1 没把握
        var ticket = dlt([([5, -1, 23, 30, 35], [2, 11]), ([1, 8, 17, 26, 34], [6, 9]), ([3, 4, 16, 20, 26], [4, 11])])
        ModelFusion.fuse(&ticket, rows: ["x 05 l2 23 30 35 02 11", rows[1], rows[2]].map(row))
        XCTAssertEqual(ticket.lines[0][.front], [5, -1, 23, 30, 35])

        var other = dlt([([5, 13, 23, 30, 35], [2, 11]), ([1, 8, 17, 26, 34], [6, 9]), ([3, 4, 16, 20, 26], [4, 11])])
        ModelFusion.fuse(&other, rows: ["x 05 l2 23 30 35 02 11", rows[1], rows[2]].map(row))
        XCTAssertEqual(other.lines[0][.front], [5, 13, 23, 30, 35], "模型没把握的时候不能推翻 Vision")
    }

    /// 号码区里有一行模型没读成：下面的行**不能**往上错一行去配。
    func testUnreadRowDoesNotShiftTheRowsBelow() {
        var ticket = dlt([([-1, -1, -1, -1, -1], [-1, -1]), ([-1, -1, -1, -1, -1], [-1, -1]), ([-1, -1, -1, -1, -1], [-1, -1])])
        // 第一行多读出一位，读不成；后两行读得成
        ModelFusion.fuse(&ticket, rows: ["x 05 12 23 30 35 02 111", rows[1], rows[2]].map(row))
        XCTAssertTrue(ticket.lines.allSatisfy { $0[.front].allSatisfy { $0 == -1 } }, "没有锚、行数又对不上，一个都不能补")
    }

    func testRowWithoutAnyVisionDigitIsFilledWhenItsNeighbourIsAnchored() {
        var ticket = dlt([([5, 12, 23, 30, 35], [2, 11]), ([-1, -1, -1, -1, -1], [-1, -1]), ([3, 4, 16, 20, 26], [4, 11])])
        ModelFusion.fuse(&ticket, rows: rows.map(row))
        XCTAssertEqual(ticket.lines[1][.front], [1, 8, 17, 26, 34])
        XCTAssertEqual(ticket.lines[1][.back], [6, 9])
    }

    /// 补完之后整注不合规（前区不是升序）：刚补的全部退回问号。
    func testFillThatBreaksTheOrderIsTakenBack() {
        var ticket = dlt([([5, 12, 23, 30, 35], [2, 11]), ([1, 8, 17, 26, 34], [6, 9]), ([3, -1, 16, 20, 26], [4, 11])])
        ModelFusion.fuse(&ticket, rows: [rows[0], rows[1], "x 03 40 16 20 26 04 11"].map(row))
        XCTAssertEqual(ticket.lines[2][.front], [3, -1, 16, 20, 26])
    }

    // MARK: - 七星彩

    private func qxc(_ lines: [[Int]]) -> ScannedTicket {
        var ticket = ScannedTicket(game: .qxc)
        ticket.lines = lines.map { NumberSet([.nums6: Array($0.prefix(6)), .tail: [$0[6]]]) }
        return ticket
    }

    /// 真机上那张票：五注里 16 个问号，第四注只剩一个特别号。
    func testSevenStarsTicketFromTheDevice() {
        var ticket = qxc([[3, -1, -1, 7, -1, 0, -1], [2, 4, -1, -1, -1, -1, -1], [7, 9, 7, 4, 2, -1, 14],
                          [-1, -1, -1, -1, -1, -1, 8], [2, 9, 7, 4, 6, 2, 13]])
        let model = ["x 3 3 2 7 6 0   11", "x 2 4 7 3 1 1   11", "x 7 9 7 4 2 0   14",
                     "x 0 1 3 3 4 9   8", "x 2 9 7 4 6 2   13"].map(row)
        let report = ModelFusion.fuse(&ticket, rows: model)
        XCTAssertEqual(report.filled, 16)
        XCTAssertFalse(ticket.hasUnknown)
        XCTAssertEqual(ticket.lines[0][.nums6], [3, 3, 2, 7, 6, 0])
        XCTAssertEqual(ticket.lines[0][.tail], [11])
        XCTAssertEqual(ticket.lines[3][.nums6], [0, 1, 3, 3, 4, 9])
        XCTAssertEqual(ticket.lines[3][.tail], [8])
    }

    /// 特别号两位的时候十位只能是 1。读出「24」就是切错了，这一行不算。
    func testTwoDigitTailMustStartWithOne() {
        var ticket = qxc([[3, 3, 2, 7, 6, 0, -1]])
        ModelFusion.fuse(&ticket, rows: [row("x 3 3 2 7 6 0   24")])
        XCTAssertEqual(ticket.lines[0][.tail], [-1])
    }

    // MARK: - 套餐票

    func testPackageBlockIsRestoredWhenVisionLostTheFrontRow() {
        var ticket = dlt([([5, 12, 23, 30, 35], [2, 11])])
        ticket.isPackage = true
        ticket.selections[.back] = SectionSelection(selected: [2, 5, 11])
        XCTAssertTrue(ticket.packageBlockMissing)
        ModelFusion.fuse(&ticket, rows: [rows[0], "xx 02 15 30 31 33", "xx 02 05 11"].map(row))
        XCTAssertEqual(ticket.selections[.front]?.selected, [2, 15, 30, 31, 33])
        XCTAssertFalse(ticket.packageBlockMissing)
    }

    func testPackageBlockDisagreementIsReportedNotOverwritten() {
        var ticket = dlt([([5, 12, 23, 30, 35], [2, 11])])
        ticket.isPackage = true
        ticket.selections[.front] = SectionSelection(selected: [2, 15, 30, 31, 34])
        ticket.selections[.back] = SectionSelection(selected: [2, 5, 11])
        ModelFusion.fuse(&ticket, rows: [rows[0], "xx 02 15 30 31 33", "xx 02 05 11"].map(row))
        XCTAssertEqual(ticket.selections[.front]?.selected, [2, 15, 30, 31, 34])
        XCTAssertTrue(ticket.warnings.contains { $0.contains("两种读法不一致") })
    }

    func testSystemAndBankerTicketsAreLeftAlone() {
        var ticket = ScannedTicket(game: .dlt)
        ticket.play = .system
        ticket.selections[.front] = SectionSelection(selected: [1, 4, 19, 21, 24, 35])
        ticket.selections[.back] = SectionSelection(selected: [6, 11])
        let before = ticket
        let report = ModelFusion.fuse(&ticket, rows: rows.map(row))
        XCTAssertEqual(ticket, before)
        XCTAssertEqual(report.expected, 0)
    }
}
