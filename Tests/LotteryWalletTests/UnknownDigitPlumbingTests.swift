import XCTest
@testable import LotteryWallet

/// 注序号那一列的右边界，和「圈码不是数字」这条。
///
/// 这两件事原来是「按字符坐标估几何」那条老路的地基。**那条路已经删掉了** ——
/// 它的方向是反的（认得越差、几何估得越偏），更要命的是它会**盖住格子路的失败**：
/// 格子划不出来时它给出一个看起来差不多的答案，于是真正的问题在真机上
/// 连着几轮都看不出来。
///
/// 但这两条判据配准那一层还在用：左边界决定号码区从哪儿切，
/// 而 `plainDigitValue` 不认圈码这件事，是防止注序号被当成一列号码的底线。
final class RowLabelBoundaryTests: XCTestCase {

    /// 圈码本身不能被当成数字。
    ///
    /// `①` 在 Unicode 里**是个有数值的数字字符**（numericValue 就是 1），
    /// 所以按坐标取字符时不能用宽容的 `digitValue`。
    func testCircledNumeralsAreNotDigits() {
        XCTAssertEqual(TicketTextParser.digitValue("①"), 1)
        XCTAssertNil(TicketTextParser.plainDigitValue("①"))
        XCTAssertNil(TicketTextParser.plainDigitValue("⑤"))
        // 半角数字和热敏票常见的误读字母照常认
        XCTAssertEqual(TicketTextParser.plainDigitValue("7"), 7)
        XCTAssertEqual(TicketTextParser.plainDigitValue("O"), 0)
        XCTAssertEqual(TicketTextParser.plainDigitValue("l"), 1)
    }

    /// 标签右边界取的是**窄而且靠左**的那些碎片。
    func testRowLabelBoundaryPicksTheIndexColumn() {
        let labels = [
            fragment("②", x: 0.05, width: 0.03),
            fragment("③", x: 0.05, width: 0.03),
            // 整行号码也可能以 A. 开头 —— 太宽，不能拿来当边界
            fragment("A.05 16 24 33 45 52", x: 0.05, width: 0.5),
            // 右半张票上的东西更不能
            fragment("(1)", x: 0.8, width: 0.04)
        ]
        let boundary = TicketVisionScanner.rowLabelBoundary(labels)
        XCTAssertEqual(boundary ?? 0, 0.08, accuracy: 0.001)
    }

    /// 一张没有注序号的票不该凭空造出边界。
    func testRowLabelBoundaryIsNilWithoutLabels() {
        XCTAssertNil(TicketVisionScanner.rowLabelBoundary([
            fragment("合计10元", x: 0.7, width: 0.2),
            fragment("26/04/17 16:21:04", x: 0.3, width: 0.4)
        ]))
    }

    /// 标签右边界是**相对票面内容**算的，不是相对整张照片。
    ///
    /// 用户裁得松、票只占画面一半时，按整张图算的比例全都会偏 ——
    /// 这正是「裁切稍微不准就识别失败」的来源之一。
    func testRowLabelBoundaryIsRelativeToTheTicketNotThePhoto() {
        // 票只占画面右半边：注序号在 0.52，号码在 0.58 往右
        let fragments = [
            fragment("②", x: 0.52, width: 0.02),
            fragment("③", x: 0.52, width: 0.02),
            fragment("3 9 5 4 7 7 13", x: 0.58, width: 0.34)
        ]
        let boundary = TicketVisionScanner.rowLabelBoundary(fragments)
        XCTAssertEqual(boundary ?? 0, 0.54, accuracy: 0.001)
    }

    private func fragment(_ text: String, x: CGFloat, width: CGFloat) -> TicketVisionScanner.TextFragment {
        TicketVisionScanner.TextFragment(
            text: text,
            box: CGRect(x: x, y: 0.5, width: width, height: 0.02))
    }
}

/// 问号要能一路走到复核页：解析、计数、导入闸门。
///
/// 矩阵重建出来的空格子写成 `?`，解析器接住它，复核页画成问号球，
/// 补齐之前不许导入 —— 所以它永远进不了票夹、不参与核对、不写进备份。
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

    /// 特别号印成两位（票面实测就是 `13` `10`）时走原来那条路。
    func testQixingcaiTwoDigitTailStillParses() {
        let numbers = TicketTextParser.singleLineForTesting("① 3 9 5 4 7 7 13", game: .qxc)
        XCTAssertEqual(numbers?[.nums6], [3, 9, 5, 4, 7, 7])
        XCTAssertEqual(numbers?[.tail], [13])
    }

    /// 位数不齐的行照旧读不成一注 —— 问号只补"知道位置但不知道值"的那一位。
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

    func testFilledTicketIsClean() {
        var ticket = ScannedTicket(game: .pl5)
        ticket.lines = [NumberSet([.nums5: [8, 4, 4, 1, 5]])]
        XCTAssertFalse(ticket.hasUnknown)
        XCTAssertEqual(ticket.unknownCount, 0)
    }

    /// 矩阵铺成文本：认不出的那一格写成 `?`，解析器才接得住。
    func testSlotTextUsesQuestionMarks() {
        XCTAssertEqual(TicketVisionScanner.slotText([8, 4, nil, 1, 5]), "8 4 ? 1 5")
        XCTAssertEqual(TicketVisionScanner.slotText([nil, nil]), "? ?")
    }

    /// 票底的流水号绝不能被当成一注号码。
    ///
    /// 真机上出过最严重的一次：一张排列5 的两注都因为少认一位被丢掉，
    /// 而票底那个 `00084`（流水号）**被读成了唯一的一注**，
    /// 票夹里于是躺着一注根本不存在的号码。
    ///
    /// 排列5 的值域是 0-9，`00084` 五个数字每一个都合法，光数个数拦不住。
    /// 唯一可靠的判据是：票面上号码是**一个个隔开印**的，流水号是连着印的。
    func testSerialNumberIsNotABet() {
        XCTAssertNil(TicketTextParser.positionalValues(in: "00084", count: 5))
        XCTAssertNil(TicketTextParser.singleLineForTesting("00084", game: .pl5))
        XCTAssertNil(TicketTextParser.singleLineForTesting("26088", game: .pl5))
        XCTAssertNil(TicketTextParser.singleLineForTesting("054049", game: .pl3))
        // 隔开印的才是号码
        XCTAssertEqual(TicketTextParser.positionalValues(in: "8 4 4 1 5", count: 5),
                       [8, 4, 4, 1, 5])
        XCTAssertEqual(TicketTextParser.singleLineForTesting("① 8 4 4 1 5", game: .pl5)?[.nums5],
                       [8, 4, 4, 1, 5])
    }

    /// 粘在一起的两位数不能顶替两个号码的位置。
    ///
    /// `84 4 1 5` 只有四组，读成一注就等于把 `8` 和 `4` 并成了 `84`。
    /// 宁可这一行读不出来（退回旧办法、或者标成问号），也不能读错。
    func testGluedDigitsAreRejectedForPositionalGames() {
        XCTAssertNil(TicketTextParser.singleLineForTesting("① 84 4 1 5", game: .pl5))
        XCTAssertNil(TicketTextParser.singleLineForTesting("组六: 01 5", game: .fc3d))
    }

    /// 票面版式：全是比值，一个像素数都没有。
    ///
    /// 真票逐像素量出来的：七星彩 列距÷字宽 3.62、排列5 3.74、排列3 3.43、
    /// 大乐透 1.61；七星彩的特别号偏 1.58 个列距，大乐透的后区偏 2.34。
    /// 不同的打票机比值几乎一样，说明这是**印刷版式**决定的，可以当先验用。
    func testLayoutCoversTheMatrixGames() {
        XCTAssertEqual(DigitTicketLayout.of(.pl3)?.columns, 3)
        XCTAssertEqual(DigitTicketLayout.of(.fc3d)?.columns, 3)
        XCTAssertEqual(DigitTicketLayout.of(.pl5)?.columns, 5)
        XCTAssertEqual(DigitTicketLayout.of(.qxc)?.columns, 6, "特别号不在矩阵里")
        // 两位数的那四种**都不走矩阵路**，界线是「号码自不自带校验」：
        // 它们的一注号码必须升序、不重复、落在值域内，号码集合本身就是校验和，
        // 解析器一卡就能发现读错；而上面那四种数字型是 0–9 任意数字、
        // 可重复、无顺序，读错了没有任何办法发现，格子是唯一的护栏。
        XCTAssertNil(DigitTicketLayout.of(.qlc))
        XCTAssertNil(DigitTicketLayout.of(.k8))
        XCTAssertNil(DigitTicketLayout.of(.ssq))
        XCTAssertNil(DigitTicketLayout.of(.dlt))
    }

    /// 只有七星彩在号码区右边**单独分出去一块**。
    ///
    /// 它的特别号 0–14、印一位或两位，而且离前六位远得多。硬塞进矩阵当第 7 列
    /// 试过三种办法都不行（取并集、按字宽往左让、单格补认），每加一层特例
    /// 还都动了收行的前提。分出去之后主矩阵就是规规矩矩的 6 列。
    func testOnlyQixingcaiSplitsOffATrailingZone() {
        XCTAssertEqual(DigitTicketLayout.of(.qxc)?.columns, 6, "主矩阵只有六位")
        XCTAssertEqual(DigitTicketLayout.of(.qxc)?.trailing?.maximum, 14)
        XCTAssertEqual(DigitTicketLayout.of(.qxc)?.trailing?.divider, 0.67)
        XCTAssertNil(DigitTicketLayout.of(.pl5)?.trailing)
        XCTAssertNil(DigitTicketLayout.of(.pl3)?.trailing)
        XCTAssertNil(DigitTicketLayout.of(.fc3d)?.trailing)
    }

    /// 最后一列整列没认出来时，位置是**算**出来的，不是找出来的。
    ///
    /// 七星彩的特别号在前一列右边 1.58 个列距处；之前是在右边扫一大片
    func testRecoveredTensParsesBack() {
        let line = TicketVisionScanner.slotText([3, 9, 5, 4, 7, 7, 13])
        XCTAssertEqual(line, "3 9 5 4 7 7 13")
        let numbers = TicketTextParser.singleLineForTesting(line, game: .qxc)
        XCTAssertEqual(numbers?[.nums6], [3, 9, 5, 4, 7, 7])
        XCTAssertEqual(numbers?[.tail], [13])
    }

}
