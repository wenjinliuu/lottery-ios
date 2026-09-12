import XCTest
@testable import LotteryWallet

/// 号码矩阵的重建。
///
/// 下面这些坐标不是编的 —— 是把一张真实的七星彩票（第 26042 期，5 注单式）
/// 的号码区一个像素一个像素量出来的：
///
/// - 单个数字 21 宽 × 29 高
/// - 左右相邻两个号码 间距 76（空白 **55**）
/// - 上下相邻两注   间距 41（空白 **12**）
///
/// 上下的空隙比左右的窄 4.5 倍。这就是为什么 Vision 把这张票**按竖列**读，
/// 也是为什么之前按横行切的流水线怎么调都不对。
final class DigitMatrixReaderTests: XCTestCase {

    // 票面实测（像素，左上角为原点）
    private let blockWidth: CGFloat = 720
    private let blockHeight: CGFloat = 220
    private let glyphWidth: CGFloat = 21
    private let glyphHeight: CGFloat = 29
    /// 六个单字符列的左边界
    private let columnLefts: [CGFloat] = [105.5, 181.5, 258.5, 334.5, 409.5, 486.5]
    /// 注序号那一列（`①②③④⑤`）。实测它和第一列号码的间距是 62.5，
    /// 和号码之间的 65 几乎一样 —— 几何上分不开，只能靠标签位置切。
    private let rowIndexLeft: CGFloat = 39.5
    /// 第七列（特别号）是**右对齐**的：两位数的十位往左探出去
    private let tailUnitsLeft: CGFloat = 614
    private let tailTensLeft: CGFloat = 594
    private let tailTensWidth: CGFloat = 7
    private let rowTops: [CGFloat] = [12.5, 53.5, 94.5, 135.5, 181.5]

    /// 票面上真实印的 5 注。
    private let ticket = [[3, 9, 5, 4, 7, 7, 13],
                          [2, 9, 7, 3, 4, 0, 4],
                          [7, 8, 1, 7, 1, 5, 9],
                          [6, 8, 7, 4, 6, 0, 10],
                          [5, 4, 9, 4, 4, 8, 2]]

    /// 票面像素 → Vision 的归一化坐标（原点左下，y 向上）。
    private func char(_ value: Int, left: CGFloat, top: CGFloat,
                      width: CGFloat? = nil) -> TicketVisionScanner.DigitChar {
        let w = width ?? glyphWidth
        return TicketVisionScanner.DigitChar(
            value: value,
            box: CGRect(x: left / blockWidth,
                        y: (blockHeight - top - glyphHeight) / blockHeight,
                        width: w / blockWidth,
                        height: glyphHeight / blockHeight))
    }

    private var normalizedGlyphWidth: CGFloat { glyphWidth / blockWidth }
    private var normalizedGlyphHeight: CGFloat { glyphHeight / blockHeight }

    /// 按票面排版摆出全部字符，可以指定哪几个"没认出来"。
    private func layout(dropping missing: Set<[Int]> = []) -> [TicketVisionScanner.DigitChar] {
        var chars: [TicketVisionScanner.DigitChar] = []
        for (rowIndex, row) in ticket.enumerated() {
            let top = rowTops[rowIndex]
            for (columnIndex, value) in row.enumerated() {
                guard !missing.contains([rowIndex, columnIndex]) else { continue }
                if columnIndex < columnLefts.count {
                    chars.append(char(value, left: columnLefts[columnIndex], top: top))
                } else if value >= 10 {
                    chars.append(char(value / 10, left: tailTensLeft, top: top, width: tailTensWidth))
                    chars.append(char(value % 10, left: tailUnitsLeft, top: top))
                } else {
                    chars.append(char(value, left: tailUnitsLeft, top: top))
                }
            }
        }
        return chars
    }

    /// 纯几何那一段流水线，不碰 Vision。
    private func rebuild(_ chars: [TicketVisionScanner.DigitChar], columns: Int = 7) -> [[Int?]]? {
        let bands = DigitMatrixReader.groupIntoBands(chars, glyphHeight: normalizedGlyphHeight)
        let candidates = bands
            .map { DigitMatrixReader.tokenize($0, glyphWidth: normalizedGlyphWidth) }
            .filter { DigitMatrixReader.isBetRow($0, columns: columns, glyphWidth: normalizedGlyphWidth) }
        guard let grid = DigitMatrixReader.columnGrid(candidates, columns: columns,
                                                      glyphWidth: normalizedGlyphWidth) else { return nil }
        return candidates.map { DigitMatrixReader.assign($0, to: grid,
                                                         glyphWidth: normalizedGlyphWidth) ?? [] }
    }

    // MARK: - 核心：读出来的必须是「行」，不是「列」

    /// 整张票重建出来就是票面印的那 5 注。
    ///
    /// 这一条是整件事的要害：Vision 把这张票按竖列读出来的是
    /// `32765` `99884` `57179`…，而票面真正的第一注是 `3 9 5 4 7 7 13`。
    func testRebuildsRowsNotColumns() {
        XCTAssertEqual(rebuild(layout()), ticket.map { row in row.map { Optional($0) } })
    }

    /// 上下聚成 5 条横带，每条 7 个号码 —— 而不是左右聚成 7 条竖带。
    func testBandsFollowRows() {
        let bands = DigitMatrixReader.groupIntoBands(layout(), glyphHeight: normalizedGlyphHeight)
        XCTAssertEqual(bands.count, 5)
        // 两位数的特别号占两个字符：第 ① 注是 13、第 ④ 注是 10，
        // 这两带各有 8 个字符，其余三带 7 个。
        XCTAssertEqual(bands.map(\.count), [8, 7, 7, 8, 7])
    }

    /// 特别号 `13` `10` 必须当成**一个号码**。
    ///
    /// 按字符摆栅格的话它会占掉两列，第七位就被拆开、整行跟着错位。
    func testTwoDigitSpecialNumberStaysOneNumber() {
        let bands = DigitMatrixReader.groupIntoBands(layout(), glyphHeight: normalizedGlyphHeight)
        let first = DigitMatrixReader.tokenize(bands[0], glyphWidth: normalizedGlyphWidth)
        XCTAssertEqual(first.count, 7)
        XCTAssertEqual(first.map(\.value), [3, 9, 5, 4, 7, 7, 13])
    }

    // MARK: - 缺号：位置不能挪

    /// 第 2 注的第 4 位没认出来 —— 那一格是问号，**其余六位一个都不许挪**。
    func testMissingDigitLeavesTheHoleInPlace() {
        let rows = rebuild(layout(dropping: [[1, 3]]))
        XCTAssertEqual(rows?[1], [2, 9, 7, nil, 4, 0, 4])
        XCTAssertEqual(rows?[0], ticket[0].map { value in Optional(value) })
        XCTAssertEqual(rows?[2], ticket[2].map { value in Optional(value) })
    }

    /// 行首那一位没认出来同样不会让整行左移。
    ///
    /// 列栅格是**所有行汇总**estimate 出来的：7 列 5 行 35 个样本，
    /// 少一个不影响列位，所以缺的就落在第 1 位上。
    func testMissingLeadingDigitDoesNotShiftTheRow() {
        let rows = rebuild(layout(dropping: [[2, 0]]))
        XCTAssertEqual(rows?[2], [nil, 8, 1, 7, 1, 5, 9])
    }

    /// 缺的是两位数的特别号也一样。
    func testMissingTailNumber() {
        let rows = rebuild(layout(dropping: [[3, 6]]))
        XCTAssertEqual(rows?[3], [6, 8, 7, 4, 6, 0, nil])
    }

    // MARK: - 票面上别的数字一个都不许混进来

    private func token(_ value: Int, left: CGFloat, width: CGFloat) -> DigitMatrixReader.Token {
        DigitMatrixReader.Token(value: value,
                                box: CGRect(x: left / blockWidth, y: 0.5,
                                            width: width / blockWidth,
                                            height: normalizedGlyphHeight))
    }

    /// 票号 `110310-251461-120958-368897 772489`：数字是挨着印的。
    /// token 个数凑巧落在范围里，但每个 token 有六位那么宽，而且间距只有一个短横。
    func testSerialNumberRowIsNotABetRow() {
        var left: CGFloat = 20
        let serial = [110310, 251461, 120958, 368897, 772489].map { value -> DigitMatrixReader.Token in
            let t = token(value, left: left, width: 96)
            left += 96 + 14
            return t
        }
        XCTAssertFalse(DigitMatrixReader.isBetRow(serial, columns: 7, glyphWidth: normalizedGlyphWidth))
    }

    /// 出票时间 `26/04/17 16:21:04`：六个两位数，但挤在一起。
    func testTimestampRowIsNotABetRow() {
        var left: CGFloat = 20
        let stamp = [26, 4, 17, 16, 21, 4].map { value -> DigitMatrixReader.Token in
            let t = token(value, left: left, width: 42)
            left += 42 + 12
            return t
        }
        XCTAssertFalse(DigitMatrixReader.isBetRow(stamp, columns: 7, glyphWidth: normalizedGlyphWidth))
    }

    /// 金额 `3.70元` 只有两个数字，凑不成一注。
    func testAmountRowIsNotABetRow() {
        let amount = [token(3, left: 20, width: 21), token(70, left: 120, width: 42)]
        XCTAssertFalse(DigitMatrixReader.isBetRow(amount, columns: 7, glyphWidth: normalizedGlyphWidth))
    }

    /// 真正的一注要过得去。
    func testRealBetRowIsAccepted() {
        let bands = DigitMatrixReader.groupIntoBands(layout(), glyphHeight: normalizedGlyphHeight)
        for band in bands {
            let tokens = DigitMatrixReader.tokenize(band, glyphWidth: normalizedGlyphWidth)
            XCTAssertTrue(DigitMatrixReader.isBetRow(tokens, columns: 7,
                                                     glyphWidth: normalizedGlyphWidth))
        }
    }

    // MARK: - 摆不上就整个作废

    /// 有一个号码落在任何一列之外 —— 整行归不进栅格，`assign` 必须返回 nil，
    /// 调用方据此把**整个矩阵**作废退回旧办法。
    ///
    /// 不能悄悄跳过那一行：用户手里五注的票在票夹里变成四注，
    /// 而且哪里少了完全看不出来。
    func testAssignRejectsAStrayNumber() {
        let bands = DigitMatrixReader.groupIntoBands(layout(), glyphHeight: normalizedGlyphHeight)
        let candidates = bands.map { DigitMatrixReader.tokenize($0, glyphWidth: normalizedGlyphWidth) }
        guard let grid = DigitMatrixReader.columnGrid(candidates, columns: 7,
                                                      glyphWidth: normalizedGlyphWidth) else {
            return XCTFail("应该估得出列栅格")
        }
        let stray = [token(9, left: 300, width: 21)] + candidates[0].dropFirst()
        XCTAssertNil(DigitMatrixReader.assign(stray, to: grid, glyphWidth: normalizedGlyphWidth))
    }

    /// 两个号码抢同一列同样作废 —— 那说明栅格估错了。
    func testAssignRejectsTwoNumbersInOneColumn() {
        let bands = DigitMatrixReader.groupIntoBands(layout(), glyphHeight: normalizedGlyphHeight)
        let candidates = bands.map { DigitMatrixReader.tokenize($0, glyphWidth: normalizedGlyphWidth) }
        guard let grid = DigitMatrixReader.columnGrid(candidates, columns: 7,
                                                      glyphWidth: normalizedGlyphWidth) else {
            return XCTFail("应该估得出列栅格")
        }
        let doubled = candidates[0] + [token(9, left: columnLefts[2], width: 21)]
        XCTAssertNil(DigitMatrixReader.assign(doubled, to: grid, glyphWidth: normalizedGlyphWidth))
    }

    /// 列栅格优先用**号码齐全**的那几行来定列位。
    /// 缺号的行会把某一列的中心带偏，用它定位就会连累别的行。
    func testColumnGridPrefersCompleteRows() {
        let full = DigitMatrixReader.tokenize(
            DigitMatrixReader.groupIntoBands(layout(), glyphHeight: normalizedGlyphHeight)[1],
            glyphWidth: normalizedGlyphWidth)
        let short = Array(full.dropLast(2))
        let grid = DigitMatrixReader.columnGrid([full, short], columns: 7,
                                                glyphWidth: normalizedGlyphWidth)
        XCTAssertEqual(grid?.count, 7)
    }

    /// 排列3 / 3D 是三列的矩阵，同一套算法照样成立。
    func testThreeColumnMatrix() {
        var chars: [TicketVisionScanner.DigitChar] = []
        let rows = [[0, 4, 4], [1, 8, 9], [3, 3, 7]]
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, value) in row.enumerated() {
                chars.append(char(value, left: columnLefts[columnIndex], top: rowTops[rowIndex]))
            }
        }
        XCTAssertEqual(rebuild(chars, columns: 3), rows.map { row in row.map { Optional($0) } })
    }

    // MARK: - 注序号那一列（实测到的错位）

    /// 复现 build 30 在真机上的错位，并钉住修法。
    ///
    /// 实测原文是每一注前面凭空多一个数字、特别号整列消失：
    /// `0 3 9 5 4 7 7`，而票面是 `3 9 5 4 7 7 13`。
    ///
    /// 两件事凑在一起才出这个结果：
    /// 1. 特别号那一列离前六位远（间距是号码间距的 1.6 倍），Vision 的
    ///    文本行到那儿就断了，**整列一个字符都没拿到**。
    /// 2. 左边那一竖排注序号被当成了一列号码 —— `.fast` 把 `①` 读成 `0`、
    ///    `③` 读成 `1`，而它和号码列的间距几乎一样（62.5 对 65），
    ///    几何上根本分不开。
    ///
    /// 于是正好还是 7 列，栅格照样成立，整排右移一格。
    func testRowIndexColumnMustNotBecomeANumberColumn() {
        let tailColumn: Set<[Int]> = Set((0..<5).map { [$0, 6] })
        // `.fast` 实际把五个圈码读成了这些
        let misread = [0, 0, 1, 0, 0]
        let indexColumn = misread.enumerated().map { index, value in
            char(value, left: rowIndexLeft, top: rowTops[index])
        }

        // 不挡：和真机上一模一样地错位
        let wrong = rebuild(indexColumn + layout(dropping: tailColumn))
        XCTAssertEqual(wrong?[0], [0, 3, 9, 5, 4, 7, 7])
        XCTAssertEqual(wrong?[2], [1, 7, 8, 1, 7, 1, 5])

        // 按标签右边界挡掉注序号之后：特别号找回来了就完全正确
        XCTAssertEqual(rebuild(keptRightOfLabels(indexColumn + layout())),
                       ticket.map { row in row.map { Optional($0) } })
    }

    /// 挡掉注序号、而特别号那一列**又没找回来**时，只剩 6 列 ——
    /// 这时候必须**整个矩阵作废**退回旧办法，绝不能拿 6 列硬凑成 7 列。
    ///
    /// 少认一列是可以接受的（退回去还有别的路），摆错位不行。
    func testSixColumnsIsRejectedRatherThanShifted() {
        let tailColumn: Set<[Int]> = Set((0..<5).map { [$0, 6] })
        XCTAssertNil(rebuild(keptRightOfLabels(layout(dropping: tailColumn))))
    }

    /// 模拟「按注序号的右边界过滤」。
    private func keptRightOfLabels(_ chars: [TicketVisionScanner.DigitChar])
        -> [TicketVisionScanner.DigitChar] {
        let boundary = (rowIndexLeft + glyphWidth) / blockWidth
        return chars.filter { $0.box.minX > boundary }
    }

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

    private func fragment(_ text: String, x: CGFloat, width: CGFloat) -> TicketVisionScanner.TextFragment {
        TicketVisionScanner.TextFragment(
            text: text,
            box: CGRect(x: x, y: 0.5, width: width, height: 0.02))
    }

    /// 列距用来到右边找丢失的那一列。
    func testPitchOfGrid() {
        let grid: [ClosedRange<CGFloat>] = [0.1...0.14, 0.2...0.24, 0.3...0.34]
        XCTAssertEqual(DigitMatrixReader.pitch(of: grid), 0.1, accuracy: 0.0001)
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

    /// 只有最后一列可能印成两位数的彩种，才需要回头去找丢掉的十位。
    ///
    /// 七星彩的特别号是 0-14，`13` `10` 在票面上占两个字符、整列右对齐，
    /// 十位那个又窄又靠左，实测就是被丢掉的那一个。
    /// 排列3/5、福彩3D 每一位都是 0-9，不存在这回事 ——
    /// 给它们开这一步只会平白多出误判的机会。
    func testTrailingColumnMaximum() {
        XCTAssertEqual(TicketVisionScanner.trailingColumnMaximum(.qxc), 14)
        XCTAssertEqual(TicketVisionScanner.trailingColumnMaximum(.pl5), 9)
        XCTAssertEqual(TicketVisionScanner.trailingColumnMaximum(.pl3), 9)
        XCTAssertEqual(TicketVisionScanner.trailingColumnMaximum(.fc3d), 9)
    }

    /// 十位补回来之后，整行要能照常解析成一注。
    func testRecoveredTensParsesBack() {
        let line = TicketVisionScanner.slotText([3, 9, 5, 4, 7, 7, 13])
        XCTAssertEqual(line, "3 9 5 4 7 7 13")
        let numbers = TicketTextParser.singleLineForTesting(line, game: .qxc)
        XCTAssertEqual(numbers?[.nums6], [3, 9, 5, 4, 7, 7])
        XCTAssertEqual(numbers?[.tail], [13])
    }

    /// 只有**每一位印一个号码**的彩种才走矩阵重建。
    /// 七乐彩、快乐8 印的是两位数且号码之间间距正常，双色球、大乐透还带分隔符 ——
    /// 它们的行本来就横着读得好好的，不该去动。
    func testOnlyDigitGamesUseMatrixRebuild() {
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
