import XCTest
import CoreGraphics
@testable import LotteryWallet

/// 配准后的号码区里怎么划格子。
///
/// 这一层是阶段 2 的地基：**先有格子，再去认**。格子的位置只来自墨迹投影，
/// 和识别结果无关 —— 老路那个"认得越差、几何估得越偏"的死结就是在这儿解开的。
///
/// 下面这些坐标按七星彩的实测版式摆：字 21 宽 29 高、列距 76、行距 41。
final class NumberGridTests: XCTestCase {

    private let width = 700
    private let height = 260

    private final class Zone {
        var ink: [Bool]
        let width: Int
        let height: Int
        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            ink = [Bool](repeating: false, count: width * height)
        }
        func fill(x: Range<Int>, y: Range<Int>) {
            for row in y where row >= 0 && row < height {
                for column in x where column >= 0 && column < width {
                    ink[row * width + column] = true
                }
            }
        }
        var mask: InkMask { InkMask(width: width, height: height, ink: ink) }
    }

    /// 五注 × 七位。列距 76、字宽 21、行距 41、字高 29，全是实测值。
    private func ticket(dropping missing: Set<[Int]> = [],
                        wideTail: Bool = false) -> Zone {
        let zone = Zone(width: width, height: height)
        for row in 0..<5 {
            let top = 20 + row * 41
            for column in 0..<7 {
                guard !missing.contains([row, column]) else { continue }
                let left = 60 + column * 76
                // 最后一列是两位数时往左探出去一点（七星彩的特别号 0–14）
                let start = (wideTail && column == 6) ? left - 20 : left
                zone.fill(x: start..<(left + 21), y: top..<(top + 29))
            }
        }
        return zone
    }

    private let layout = DigitTicketLayout(columns: 7, trailingPitch: 1, trailingMaximum: 14)

    /// 一张干净的票：五行七列，行列都切得出来。
    func testGridFromCleanMatrix() {
        guard let grid = NumberGrid.build(mask: ticket().mask,
                                          within: 0...(width - 1),
                                          layout: layout) else {
            return XCTFail("格子应该划得出来")
        }
        XCTAssertEqual(grid.rows.count, 5)
        XCTAssertEqual(grid.columns.count, 7)
        // 第一注第一位应该落在 (60,20)-(81,49) 那一格上
        guard let cell = grid.cell(row: 0, column: 0) else { return XCTFail("取不到格子") }
        XCTAssertEqual(cell.minX * CGFloat(width), 60, accuracy: 1.5)
        XCTAssertEqual(cell.minY * CGFloat(height), 20, accuracy: 1.5)
        // 列距 76：第二列的中心比第一列右 76
        guard let next = grid.cell(row: 0, column: 1) else { return XCTFail("取不到格子") }
        XCTAssertEqual((next.midX - cell.midX) * CGFloat(width), 76, accuracy: 2)
    }

    /// **中文那几行不能被当成投注行。**
    ///
    /// 号码区里夹着「单式票 / 1倍 / 合计10元」和促销语 —— 它们的段数
    /// 可能凑巧落在范围里，但落不到同一批列上。判据就是"互相对得齐"。
    func testChineseRowsAreNotBetRows() {
        let zone = ticket()
        // 号码上面一行：三块中文，位置和号码列对不上
        zone.fill(x: 30..<90, y: 0..<14)
        zone.fill(x: 300..<360, y: 0..<14)
        zone.fill(x: 560..<640, y: 0..<14)
        // 号码下面一行：两块中文
        zone.fill(x: 200..<300, y: 232..<248)
        zone.fill(x: 400..<470, y: 232..<248)

        guard let grid = NumberGrid.build(mask: zone.mask, within: 0...(width - 1),
                                          layout: layout) else {
            return XCTFail("格子应该划得出来")
        }
        XCTAssertEqual(grid.rows.count, 5, "只认五注，中文那两行不算")
        XCTAssertEqual(grid.columns.count, 7)
    }

    /// 某一格没印出来（或者没切出墨）时，那一格空着，**其余的位置不动**。
    ///
    /// 这一条是老毛病的解药：以前少认一个字符，整行就往前挪一位，
    /// 用户看到的是"每注前面凭空多个 0"。
    func testMissingCellDoesNotShiftTheRow() {
        let zone = ticket(dropping: [[2, 3]])
        guard let grid = NumberGrid.build(mask: zone.mask, within: 0...(width - 1),
                                          layout: layout) else {
            return XCTFail("格子应该划得出来")
        }
        XCTAssertEqual(grid.columns.count, 7)
        XCTAssertEqual(grid.rows.count, 5, "缺一位的那一注要留下来 —— 那一格标问号，不是整注消失")
        guard let clean = grid.cell(row: 0, column: 6),
              let gapped = grid.cell(row: 2, column: 6) else { return XCTFail("取不到格子") }
        XCTAssertEqual(clean.midX, gapped.midX, accuracy: 1e-9, "缺一位不会让后面的列挪位")
    }

    /// 最后一整列都没切出墨时，按版式**算**出它在哪儿。
    ///
    /// 七星彩的特别号印得比别的号码远，而且经常整列一个墨点都抓不到。
    func testTrailingColumnIsComputedWhenMissing() {
        let zone = Zone(width: width, height: height)
        for row in 0..<5 {
            let top = 20 + row * 41
            for column in 0..<6 {
                let left = 60 + column * 76
                zone.fill(x: left..<(left + 21), y: top..<(top + 29))
            }
        }
        guard let grid = NumberGrid.build(mask: zone.mask, within: 0...(width - 1),
                                          layout: layout) else {
            return XCTFail("最后一列该算出来")
        }
        XCTAssertEqual(grid.columns.count, 7)
        guard let sixth = grid.cell(row: 0, column: 5),
              let seventh = grid.cell(row: 0, column: 6) else { return XCTFail("取不到格子") }
        XCTAssertEqual((seventh.midX - sixth.midX) * CGFloat(width), 76, accuracy: 3,
                       "按列距算出来的位置")
    }

    /// 一张票只有一注也要认得出来 —— 排列3/5 经常只打一注。
    func testSingleBetRow() {
        let zone = Zone(width: width, height: height)
        for column in 0..<7 {
            let left = 60 + column * 76
            zone.fill(x: left..<(left + 21), y: 20..<49)
        }
        let grid = NumberGrid.build(mask: zone.mask, within: 0...(width - 1), layout: layout)
        XCTAssertEqual(grid?.rows.count, 1)
        XCTAssertEqual(grid?.columns.count, 7)
    }

    /// 空白的号码区划不出格子，要老实返回 nil ——
    /// 硬约束二：摆不上栅格宁可整个作废，绝不允许错位。
    func testBlankZoneRefuses() {
        let zone = Zone(width: width, height: height)
        XCTAssertNil(NumberGrid.build(mask: zone.mask, within: 0...(width - 1), layout: layout))
    }

    /// 只切得出四列时（离七列差太多）整个作废，不硬凑。
    func testTooFewColumnsRefuses() {
        let zone = Zone(width: width, height: height)
        for row in 0..<3 {
            let top = 20 + row * 41
            for column in 0..<4 {
                let left = 60 + column * 76
                zone.fill(x: left..<(left + 21), y: top..<(top + 29))
            }
        }
        XCTAssertNil(NumberGrid.build(mask: zone.mask, within: 0...(width - 1), layout: layout))
    }
}
