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

    /// 复式票：号码区里没有哪一行对得上它的两个区，就原样不动。胆拖票根本不看。
    func testSystemTicketIsLeftAloneWhenNoRowMatchesAndBankerIsNeverTouched() {
        var ticket = ScannedTicket(game: .dlt)
        ticket.play = .system
        ticket.selections[.front] = SectionSelection(selected: [1, 4, 19, 21, 24, 35])
        ticket.selections[.back] = SectionSelection(selected: [6, 11])
        let before = ticket
        ModelFusion.fuse(&ticket, rows: rows.map(row))
        XCTAssertEqual(ticket, before)

        var banker = before
        banker.play = .dantuo
        let report = ModelFusion.fuse(&banker, rows: ["xx 01 04 19 21 24 35", "xx 06 11"].map(row))
        XCTAssertEqual(report.expected, 0)
        XCTAssertEqual(banker.selections, before.selections)
    }

    /// 真机上那张双色球复式：「蓝复」读成了「监复」，蓝球一个都没有。模型那一行读到 02 11，
    /// 前面的冒号被认成一个没把握的 1 —— 它不算号码。
    func testSystemTicketGetsItsMissingZoneFromTheModel() {
        var ticket = ScannedTicket(game: .ssq)
        ticket.play = .system
        ticket.selections[.red] = SectionSelection(selected: [9, 21, 22, 24, 26, 28, 33])
        ModelFusion.fuse(&ticket, rows: ["09 21 22 24 26 28 33", "xl 02 11", "xx l"].map(row))
        XCTAssertEqual(ticket.selections[.blue]?.selected, [2, 11])
        XCTAssertEqual(ticket.selections[.red]?.selected, [9, 21, 22, 24, 26, 28, 33])
    }

    /// 快乐8 选五：Vision 只认出一注，模型两行都读成了，2 注 4 元对得上。
    func testWelfareSingleTicketIsRebuiltToo() {
        var ticket = ScannedTicket(game: .k8)
        ticket.playMode = "5"
        ticket.lines = [NumberSet([.nums: [9, 15, 39, 58, 80]])]
        ticket.totalAmount = 4
        let report = ModelFusion.fuse(&ticket, rows: ["x 04 05 24 35 39      x1x", "x 09 15 39 58 80      x1x", "xxx"].map(row))
        XCTAssertTrue(report.rebuilt)
        XCTAssertEqual(ticket.lines.map { $0[.nums] }, [[4, 5, 24, 35, 39], [9, 15, 39, 58, 80]])
    }

    // MARK: - 模型读到的行当骨架

    private let packageRows = ["x 11 16 21 32 35 11 12", "x 09 12 13 23 28 03 11", "x 02 18 21 26 28 05 10",
                               "x 03 07 11 26 33 07 08", "x 07 12 18 19 27 02 12", "x 09 14 18 22 28 08 10",
                               "xx 02 15 30 31 33", "xx 02 05 11", "xxx"]

    /// 真机上那张套餐票：Vision 把第二注读成 `Q09 1213 23 28`（错开一位）、把第五注读成
    /// `07 12 118 19 27`（整注被丢）。模型六行都读对了，注数和合计 18 元也对得上 —— 以模型为准。
    func testTicketIsRebuiltFromTheModelWhenTheTotalAgrees() {
        var ticket = dlt([([11, 16, 21, 32, 35], [11, 12]), ([12, 13, 23, 28, -1], [3, 11]),
                          ([2, 18, 21, 26, 28], [5, 10]), ([3, 7, 11, 26, 33], [7, 8]),
                          ([9, 14, 18, 22, 28], [8, 10])])
        ticket.isPackage = true
        ticket.selections[.front] = SectionSelection(selected: [2, 15, 30, 31, 33])
        ticket.selections[.back] = SectionSelection(selected: [2, 5, 11])
        ticket.totalAmount = 18
        let report = ModelFusion.fuse(&ticket, rows: packageRows.map(row))
        XCTAssertTrue(report.rebuilt)
        XCTAssertEqual(ticket.lines.count, 6)
        XCTAssertEqual(ticket.lines[1][.front], [9, 12, 13, 23, 28])
        XCTAssertEqual(ticket.lines[4][.front], [7, 12, 18, 19, 27])
        XCTAssertEqual(ticket.lines[4][.back], [2, 12])
        XCTAssertFalse(ticket.hasUnknown)
        XCTAssertEqual(ticket.totalCost, 18)
    }

    /// 重建之后 Vision 的读数仍然算数：同一注里两边不一样的那个号码标问号。
    func testRebuiltTicketStillMarksDisagreements() {
        var ticket = dlt([([11, 16, 21, 32, 35], [11, 12]), ([9, 12, 13, 23, 28], [3, 11]),
                          ([2, 18, 21, 26, 29], [5, 10]), ([3, 7, 11, 26, 33], [7, 8]),
                          ([7, 12, 18, 19, 27], [2, 12]), ([9, 14, 18, 22, 28], [8, 10])])
        ticket.totalAmount = 12
        let report = ModelFusion.fuse(&ticket, rows: Array(packageRows.prefix(6)).map(row))
        XCTAssertTrue(report.rebuilt)
        XCTAssertEqual(ticket.lines[2][.front], [2, 18, 21, 26, -1], "Vision 读 29、模型读 28：标问号")
        XCTAssertEqual(report.disputed, 1)
    }

    /// 注数和票面合计对不上：模型这边站不住，不换骨架，照旧只补问号。
    func testNoRebuildWhenTheTotalDisagrees() {
        var ticket = dlt([([11, 16, 21, 32, 35], [11, 12]), ([9, 12, 13, 23, 28], [3, 11])])
        ticket.totalAmount = 4
        let report = ModelFusion.fuse(&ticket, rows: Array(packageRows.prefix(6)).map(row))
        XCTAssertFalse(report.rebuilt)
        XCTAssertEqual(ticket.lines.count, 2)
    }

    /// 没读到票面合计：没有第三个读数可对，不换骨架。
    func testNoRebuildWithoutAPrintedTotal() {
        var ticket = dlt([([11, 16, 21, 32, 35], [11, 12])])
        let report = ModelFusion.fuse(&ticket, rows: Array(packageRows.prefix(6)).map(row))
        XCTAssertFalse(report.rebuilt)
        XCTAssertEqual(ticket.lines.count, 1)
    }

    /// 追加票 3 元一注：三注 9 元也对得上。
    func testAddOnPriceAlsoCounts() {
        var ticket = dlt([([5, 12, 23, 30, 35], [2, 11])])
        ticket.totalAmount = 9
        let report = ModelFusion.fuse(&ticket, rows: rows.map(row))
        XCTAssertTrue(report.rebuilt)
        XCTAssertEqual(ticket.lines.count, 3)
    }

    /// 七星彩：Vision 丢了两注的特别号，另有一注整行没读出来。
    func testSevenStarsIsRebuiltWithItsTails() {
        var ticket = qxc([[3, 3, 2, 7, 6, 0, 11], [2, 4, 7, 3, 1, 1, -1], [7, 9, 7, 4, 2, 0, 14], [2, 9, 7, 4, 6, 2, -1]])
        ticket.totalAmount = 10
        let model = ["x 3 3 2 7 6 0   11", "x 2 4 7 3 1 1   11", "x 7 9 7 4 2 0   14",
                     "x 0 1 3 3 4 9   8", "x 2 9 7 4 6 2   13"].map(row)
        let report = ModelFusion.fuse(&ticket, rows: model)
        XCTAssertTrue(report.rebuilt)
        XCTAssertEqual(ticket.lines.count, 5)
        XCTAssertEqual(ticket.lines[1][.tail], [11])
        XCTAssertEqual(ticket.lines[3][.nums6], [0, 1, 3, 3, 4, 9])
        XCTAssertEqual(ticket.lines[4][.tail], [13])
    }

    func testDescribeShowsWhatTheModelRead() {
        XCTAssertEqual(ModelFusion.describe([row("x 05 l2"), row("xx")]), "x051?2\nxx")
    }

    // MARK: - 折行、胆拖、福彩的行尾倍数

    /// 大乐透复式前区 8 个号：一行印 7 个，第 8 个折到下一行。后区那一行的标签没切成段，
    /// 看起来也是一行纯数字，但它接上去不是升序，不能并进前区。
    func testWrappedZoneRowIsJoinedButTheNextZoneIsNot() {
        let joined = ModelFusion.joinWrapped(["xx 03 08 11 18 19 30 33", "35", "01 04"].map(row))
        XCTAssertEqual(joined.count, 2)
        XCTAssertEqual(joined[0].filter { $0.digit != DigitClassifier.reject }.map(\.digit),
                       [0, 3, 0, 8, 1, 1, 1, 8, 1, 9, 3, 0, 3, 3, 3, 5])
        XCTAssertEqual(joined[1].map(\.digit), [0, 1, 0, 4])
    }

    func testSystemTicketWithAWrappedFrontZoneGetsAllEightNumbers() {
        var ticket = ScannedTicket(game: .dlt)
        ticket.play = .system
        ticket.selections[.back] = SectionSelection(selected: [1, 4])
        ModelFusion.fuse(&ticket, rows: ["lxxxxxx", "xx 03 08 11 18 19 30 33", "35", "01 04"].map(row))
        XCTAssertEqual(ticket.selections[.front]?.selected, [3, 8, 11, 18, 19, 30, 33, 35])
        XCTAssertEqual(ticket.totalCost, 112)
    }

    /// 胆拖票四行都读成、C(6,3) × C(2,1) × 2 = 80 元对得上：以模型为准。
    func testBankerTicketIsRebuiltWhenTheTotalAgrees() {
        var ticket = ScannedTicket(game: .dlt)
        ticket.play = .dantuo
        ticket.totalAmount = 80
        // Vision 把前区拖读丢了两个号
        ticket.selections[.front] = SectionSelection(selected: [2, 7, 10, 11, 12, 27], dan: [2, 27])
        ticket.selections[.back] = SectionSelection(selected: [3, 4, 12], dan: [3])
        let model = ["xxx 02 27", "xxx 07 10 11 12 20 21", "xxx 03", "xxx 04 12"].map(row)
        let report = ModelFusion.fuse(&ticket, rows: model)
        XCTAssertTrue(report.rebuilt)
        XCTAssertEqual(ticket.selections[.front]?.dan, [2, 27])
        XCTAssertEqual(ticket.selections[.front]?.selected, [2, 7, 10, 11, 12, 20, 21, 27])
        XCTAssertEqual(ticket.selections[.back]?.dan, [3])
        XCTAssertEqual(ticket.selections[.back]?.selected, [3, 4, 12])
        XCTAssertEqual(ticket.totalCost, 80)
    }

    func testBankerTicketIsLeftAloneWhenTheTotalDisagrees() {
        var ticket = ScannedTicket(game: .dlt)
        ticket.play = .dantuo
        ticket.totalAmount = 80
        ticket.selections[.front] = SectionSelection(selected: [2, 7, 10, 11, 12, 20, 21, 27], dan: [2, 27])
        ticket.selections[.back] = SectionSelection(selected: [3, 4, 12], dan: [3])
        let before = ticket
        // 模型这边少读了一行
        let report = ModelFusion.fuse(&ticket, rows: ["xxx 02 27", "xxx 07 10 11 12 20 21", "xxx 04 12"].map(row))
        XCTAssertFalse(report.rebuilt)
        XCTAssertEqual(ticket, before)
    }

    /// 双色球单式三注都是 2 倍、合计 12 元。Vision 把行尾的「(2)」读丢了，倍数成了 1。
    /// 模型每一行行尾都读到 2，3 注 × 2 元 × 2 倍对得上：倍数改成 2。
    func testWelfareMultipleComesFromTheBracketsWhenVisionLostThem() {
        var ticket = ScannedTicket(game: .ssq)
        ticket.lines = [NumberSet([.red: [5, 6, 8, 10, 11, 30], .blue: [1]])]
        ticket.totalAmount = 12
        let model = ["x 05 06 08 10 11 30 01     x2x", "x 05 08 12 15 22 31 15     x2x",
                     "x 08 13 25 28 29 32 16     x2x", "xxx", "xxx"].map(row)
        let report = ModelFusion.fuse(&ticket, rows: model)
        XCTAssertTrue(report.rebuilt)
        XCTAssertEqual(ticket.lines.count, 3)
        XCTAssertEqual(ticket.multiple, 2)
        XCTAssertEqual(ticket.totalCost, 12)
        XCTAssertEqual(ModelFusion.trailingMultiple(row("x 05 06 08 10 11 30 01")), nil)
    }
}
