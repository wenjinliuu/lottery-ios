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

    private let layout = DigitTicketLayout(groups: [.init(count: 6, maximum: 9, gap: 0),
                                                   .init(count: 1, maximum: 14, gap: 1)])

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

    // MARK: - 真机上栽过的三个跟头

    /// **七星彩的特别号那一列是右对齐的：两位数的十位往左探出去。**
    ///
    /// 五注里三注是一位数、两注是两位数，列位取中位数的话就落在个位那一段上，
    /// 十位的 `1` 落在列外面被丢掉 —— `13` 读成 `3`、`10` 读成 `0`。
    /// build 32/33/34 和阶段 2 第一版都栽在这儿。这一列只能取并集。
    func testTrailingColumnCoversTheTensDigit() {
        let zone = Zone(width: width, height: height)
        var centers: [Double] = []
        let tails = [13, 4, 9, 10, 2]
        for row in 0..<5 {
            let top = 20 + row * 41
            for column in 0..<6 {
                let left = 60 + column * 76
                zone.fill(x: left..<(left + 21), y: top..<(top + 29))
                centers.append(Double(left) + 10.5)
            }
            if tails[row] >= 10 {
                // 十位的 `1` 又窄又靠左
                zone.fill(x: 496..<503, y: top..<(top + 29))
                centers.append(499.5)
            }
            zone.fill(x: 516..<537, y: top..<(top + 29))
            centers.append(526.5)
        }
        guard let grid = NumberGrid.build(mask: zone.mask, within: 0...(width - 1),
                                          layout: layout, digitCenters: centers) else {
            return XCTFail("格子应该划得出来")
        }
        XCTAssertEqual(grid.rows.count, 5)
        XCTAssertEqual(grid.columns.count, 7)
        let last = grid.columns[6]
        XCTAssertLessThanOrEqual(last.lowerBound * CGFloat(width), 497, "末列要容得下十位")
        XCTAssertGreaterThanOrEqual(last.upperBound * CGFloat(width), 536, "也要容得下个位")
    }

    /// **注序号那一列不是号码列。**
    ///
    /// 实测它和第一位号码的列距（62.5）和号码之间的列距（65）几乎一样 ——
    /// 只差 4%，靠列距一项分不开，还要靠字宽（`①` 带个圈，比数字宽）。
    /// 这里离得远一些（2 个列距），列距一项就够了。
    func testLabelColumnIsTrimmed() {
        let three = DigitTicketLayout(groups: [.init(count: 3, maximum: 9, gap: 0)])
        let zone = Zone(width: width, height: height)
        var centers: [Double] = []
        for row in 0..<3 {
            let top = 20 + row * 36
            zone.fill(x: 10..<31, y: top..<(top + 24))          // ① —— 不是数字
            for column in 0..<3 {
                let left = 93 + column * 40
                zone.fill(x: left..<(left + 15), y: top..<(top + 24))
                centers.append(Double(left) + 7.5)
            }
        }
        guard let grid = NumberGrid.build(mask: zone.mask, within: 0...(width - 1),
                                          layout: three, digitCenters: centers) else {
            return XCTFail("格子应该划得出来")
        }
        XCTAssertEqual(grid.rows.count, 3)
        XCTAssertEqual(grid.columns.count, 3)
        XCTAssertGreaterThan(grid.columns[0].lowerBound * CGFloat(width), 80, "注序号那一列裁掉了")
    }

    /// **行尾的倍数 `(N)` 不是号码。**
    ///
    /// 这就是文档里那个「福彩 3D 的矩阵路径从来没跑起来过」的老 bug：
    /// `(1)` 里的 `1` 被当成第 4 个号码。
    ///
    /// 判据是实测的版式关系：`(N)` 离号码 **2.7 个列距**（而七星彩的特别号
    /// ——离得最远的那个号码——才 1.58 个），而且 `(1)` 连括号 35px 宽，
    /// 是数字的两倍多。列距和字宽两项都对不上，`window` 挑不中它。
    func testMultiplierColumnIsTrimmed() {
        let three = DigitTicketLayout(groups: [.init(count: 3, maximum: 9, gap: 0)])
        let zone = Zone(width: width, height: height)
        var centers: [Double] = []
        for row in 0..<3 {
            let top = 20 + row * 36
            for column in 0..<3 {
                let left = 93 + column * 40
                zone.fill(x: left..<(left + 15), y: top..<(top + 24))
                centers.append(Double(left) + 7.5)
            }
            // `(1)` 在 2.7 个列距开外，里面那个 `1` 是**真数字**，
            // 所以挡不住它的只能是距离
            zone.fill(x: 295..<329, y: top..<(top + 24))
            centers.append(312)
        }
        guard let grid = NumberGrid.build(mask: zone.mask, within: 0...(width - 1),
                                          layout: three, digitCenters: centers) else {
            return XCTFail("格子应该划得出来")
        }
        XCTAssertEqual(grid.rows.count, 3)
        XCTAssertEqual(grid.columns.count, 3)
        XCTAssertLessThan(grid.columns[2].upperBound * CGFloat(width), 200, "倍数那一列裁掉了")
    }

    /// 两位数的两个数字要合成一段 —— 它们挨得比号码之间近得多。
    ///
    /// 实测：号码之间空 55px，`13` 里的 `1` 和 `3` 只空 14px，字宽 21px。
    func testAdjacentDigitsMergeIntoOneNumber() {
        let merged = NumberGrid.merging([60...81, 136...157, 496...503, 517...538])
        XCTAssertEqual(merged.count, 3, "十位和个位合成一段")
        XCTAssertEqual(merged[2], 496...538)
    }

    /// **七星彩真机上卡死的那一步。**
    ///
    /// 五行各切出 8 段（`①` + 6 位 + 特别号），格子划得好好的，却裁不到 7 列。
    /// 原因是老判据「这一列里没有数字字符就是注序号列」撞上了文档第七节记的
    /// 那个坑：`.fast` 会把 `①` 读成 `0` —— 注序号列里"有数字"，判据失效。
    ///
    /// 所以这里**故意把 `①` 的中心也放进 `digitCenters`**，复现那个误读。
    /// 能挑对就说明裁剪不再依赖 OCR 了。
    ///
    /// 版式按实测摆：注序号列距 ÷ 号码列距 = 62.5 ÷ 65 = 0.96，
    /// 特别号偏移 1.58 个列距。
    func testSerialColumnIsTrimmedEvenWhenMisreadAsDigit() {
        let seven = DigitTicketLayout(groups: [.init(count: 6, maximum: 9, gap: 0),
                                          .init(count: 1, maximum: 14, gap: 1.58)])
        let zone = Zone(width: width, height: height)
        let pitch = 76
        var centers: [Double] = []
        for row in 0..<5 {
            let top = 20 + row * 41
            // `①` 带个圈，比数字宽；离第一位 0.96 个列距
            zone.fill(x: 44..<71, y: top..<(top + 29))
            centers.append(57.5)                       // ← `.fast` 把它读成 `0`
            for column in 0..<6 {
                let left = 120 + column * pitch
                zone.fill(x: left..<(left + 21), y: top..<(top + 29))
                centers.append(Double(left) + 10.5)
            }
            // 特别号：1.58 个列距开外
            zone.fill(x: 620..<641, y: top..<(top + 29))
            centers.append(630.5)
        }
        guard let grid = NumberGrid.build(mask: zone.mask, within: 0...(width - 1),
                                          layout: seven, digitCenters: centers) else {
            return XCTFail("格子应该划得出来")
        }
        XCTAssertEqual(grid.rows.count, 5)
        XCTAssertEqual(grid.columns.count, 7)
        XCTAssertGreaterThan(grid.columns[0].lowerBound * CGFloat(width), 100,
                             "注序号那一列应该裁掉了")
        XCTAssertGreaterThan(grid.columns[6].lowerBound * CGFloat(width), 560,
                             "末列应该是特别号那一列")
    }

    /// **福彩 3D 真机上"候选行 0 条"的那一步。**
    ///
    /// 中文玩法标签会被切成好几段（`组` 是 纟 + 且），一行于是切出十来段。
    /// 段数上限卡在 `columns + 2` = 5 的时候，每一行都被判掉，一注都读不出来。
    ///
    /// 上限放宽之后该留哪几列交给 `window` 按版式挑：
    /// 标签那几段里一个数字都没有（被那道否决挡掉），`(1)` 的列距和字宽都对不上。
    func testWideLabelRowsSurviveTheSegmentCeiling() {
        let three = DigitTicketLayout(groups: [.init(count: 3, maximum: 9, gap: 0)])
        let zone = Zone(width: width, height: height)
        var centers: [Double] = []
        for row in 0..<5 {
            let top = 20 + row * 36
            // `组六:` 切成三段，段与段之间比字宽窄不了多少，合不上
            for left in [20, 48, 76] {
                zone.fill(x: left..<(left + 12), y: top..<(top + 24))
            }
            for column in 0..<3 {
                let left = 130 + column * 40
                zone.fill(x: left..<(left + 15), y: top..<(top + 24))
                centers.append(Double(left) + 7.5)
            }
            zone.fill(x: 330..<365, y: top..<(top + 24))   // `(1)`
            centers.append(347)
        }
        let rough = NumberGrid.candidates(in: zone.mask, within: 0...(width - 1), columns: 3)
        XCTAssertEqual(rough.count, 5, "七段一行，不该被段数上限判掉")
        XCTAssertEqual(rough.first?.segments.count, 7)

        guard let grid = NumberGrid.build(mask: zone.mask, within: 0...(width - 1),
                                          layout: three, digitCenters: centers) else {
            return XCTFail("格子应该划得出来")
        }
        XCTAssertEqual(grid.rows.count, 5)
        XCTAssertEqual(grid.columns.count, 3)
        XCTAssertGreaterThan(grid.columns[0].lowerBound * CGFloat(width), 100, "标签那几列裁掉了")
        XCTAssertLessThan(grid.columns[2].upperBound * CGFloat(width), 300, "倍数那一列裁掉了")
    }

    /// **福彩 3D 实测版式**（文档 3.3 节，500px 裁图上逐像素量的）。
    ///
    /// | 内容 | x 范围 |
    /// |---|---|
    /// | `组六:` | 29–78 |
    /// | 第1位 | 93–107 |
    /// | 第2位 | 133–147（列距 40，字宽 15） |
    /// | 第3位 | 173–186 |
    /// | `(1)` | 295–329（距号码 2.7 个列距） |
    ///
    /// 这是阶段 3 的验收线：五注全出，玩法标签和倍数都不能混进号码里。
    func testWelfare3DMeasuredLayout() {
        let three = DigitTicketLayout(groups: [.init(count: 3, maximum: 9, gap: 0)])
        let zone = Zone(width: width, height: height)
        var centers: [Double] = []
        for row in 0..<5 {
            let top = 20 + row * 36
            zone.fill(x: 29..<79, y: top..<(top + 24))            // 组六:
            for left in [93, 133, 173] {
                zone.fill(x: left..<(left + 15), y: top..<(top + 24))
                centers.append(Double(left) + 7.5)
            }
            zone.fill(x: 295..<330, y: top..<(top + 24))          // (1)
            centers.append(312)                                    // 括号里那个 1 是真数字
        }
        guard let grid = NumberGrid.build(mask: zone.mask, within: 0...(width - 1),
                                          layout: three, digitCenters: centers) else {
            return XCTFail("格子应该划得出来")
        }
        XCTAssertEqual(grid.rows.count, 5, "五注全出")
        XCTAssertEqual(grid.columns.count, 3)
        XCTAssertEqual(grid.columns[0].lowerBound * CGFloat(width), 93, accuracy: 2,
                       "第一列压在第 1 位号码上，不是玩法标签")
        XCTAssertEqual(grid.columns[2].upperBound * CGFloat(width), 188, accuracy: 3,
                       "末列压在第 3 位号码上，不是倍数")
    }

    /// **大乐透 26102 实测版式**（照片摆正 3.6° 之后逐像素量的）。
    ///
    /// ```
    /// ① 12 15 19 31 33  +  05 09
    /// ```
    /// 注序号 39–58，五个前区号码列距 43.4、两位数宽 27，
    /// `+` 在 301–310（宽 10），后区第一个号码离前区最后一个 101.5px = **2.34 个列距**。
    ///
    /// 这张票说明了两件老架构做不到的事：
    /// 1. 号码矩阵**中间夹着一段不是号码的墨**（`+`）—— 挑列要跳过它，
    ///    收行时它落在号码区里面也不能算数，否则每一行都被判掉。
    /// 2. 一格印**两位数** —— 同一个号码的两位要合成一段，而号码与号码之间不能合。
    func testSuperLottoMeasuredLayout() {
        let dlt = DigitTicketLayout(groups: [.init(count: 5, maximum: 35, gap: 0),
                                             .init(count: 2, maximum: 12, gap: 2.34)],
                                    separated: true)
        // 实测列段，原样摆进来（两位数的两个数字是分开的两段）
        let digits = [(69, 81), (84, 96), (113, 124), (127, 139), (156, 168), (171, 182),
                      (200, 211), (214, 225), (243, 254), (257, 269),
                      (345, 356), (359, 370), (388, 400), (403, 415)]
        let zone = Zone(width: width, height: height)
        var centers: [Double] = []
        for row in 0..<3 {
            let top = 20 + row * 23
            zone.fill(x: 39..<59, y: top..<(top + 16))            // ①
            for (left, right) in digits {
                zone.fill(x: left..<(right + 1), y: top..<(top + 16))
                centers.append(Double(left + right) / 2)
            }
            zone.fill(x: 301..<311, y: top..<(top + 16))          // +
        }
        let rough = NumberGrid.candidates(in: zone.mask, within: 0...(width - 1), columns: 7)
        XCTAssertEqual(rough.first?.segments.count, 9,
                       "两位数各合成一段：① + 5 个前区 + `+` + 2 个后区")

        guard let grid = NumberGrid.build(mask: zone.mask, within: 0...(width - 1),
                                          layout: dlt, digitCenters: centers) else {
            return XCTFail("格子应该划得出来")
        }
        XCTAssertEqual(grid.rows.count, 3, "三注全出 —— `+` 落在前后区之间，不算数")
        XCTAssertEqual(grid.columns.count, 7)
        let lefts = grid.columns.map { Int(($0.lowerBound * CGFloat(width)).rounded()) }
        XCTAssertEqual(lefts, [69, 113, 156, 200, 243, 345, 388],
                       "七列正好压在七个号码上，注序号和 `+` 都不在里面")
    }

    /// 组与组之间隔多远是**版式**说了算，不是一路等距。
    func testPitchesFollowTheGroups() {
        let qxc = DigitTicketLayout(groups: [.init(count: 6, maximum: 9, gap: 0),
                                             .init(count: 1, maximum: 14, gap: 1.58)])
        XCTAssertEqual(qxc.columns, 7)
        XCTAssertEqual(qxc.pitches, [1, 1, 1, 1, 1, 1.58])
        XCTAssertEqual(qxc.maximums, [9, 9, 9, 9, 9, 9, 14])
        XCTAssertEqual(qxc.trailingPitch, 1.58)
        XCTAssertFalse(qxc.separated)
        XCTAssertTrue(qxc.singleDigit, "前六位都是 0–9，配准失败还能退回老路")

        let dlt = DigitTicketLayout.of(.dlt)
        XCTAssertEqual(dlt?.columns, 7)
        XCTAssertEqual(dlt?.pitches, [1, 1, 1, 1, 2.34, 1])
        XCTAssertEqual(dlt?.maximums, [35, 35, 35, 35, 35, 12, 12])
        XCTAssertEqual(dlt?.trailingPitch, 1, "末列是后区组内的，和前一位等距")
        XCTAssertEqual(dlt?.separated, true)
        XCTAssertEqual(dlt?.singleDigit, false, "印的是两位数，不能退回按一格一位写的老路")
    }

    /// 挑法枚举：组内连续，组与组之间可以跳过几段（那就是分隔符）。
    func testArrangementsSkipBetweenGroupsOnly() {
        XCTAssertEqual(NumberGrid.arrangements(count: 4, groups: [3]),
                       [[0, 1, 2], [1, 2, 3]])
        XCTAssertEqual(NumberGrid.arrangements(count: 4, groups: [2, 1]),
                       [[0, 1, 2], [0, 1, 3], [1, 2, 3]])
        XCTAssertTrue(NumberGrid.arrangements(count: 2, groups: [3]).isEmpty,
                      "段数不够就一种挑法都没有")
    }

    /// 格子路铺出来的一注，两区票也要读得进去 —— **连问号一起**。
    ///
    /// 大乐透和双色球以前只有「整行读成一注」或者「整行丢掉」两种结果：
    /// 少认一位，用户手里三注的票在票夹里就变成两注，而且看不出少在哪儿。
    /// 现在按位置读，认不出的那一格带着问号上复核页（硬约束一）。
    func testTwoZoneRowKeepsQuestionMarks() {
        XCTAssertEqual(TicketTextParser.singleLineForTesting("12 15 19 31 33 05 09",
                                                             game: .dlt)?[.front],
                       [12, 15, 19, 31, 33])
        XCTAssertEqual(TicketTextParser.singleLineForTesting("12 15 19 31 33 05 09",
                                                             game: .dlt)?[.back],
                       [5, 9])

        let holed = TicketTextParser.singleLineForTesting("12 ? 19 31 33 05 09", game: .dlt)
        XCTAssertEqual(holed?[.front], [12, NumberSet.unknown, 19, 31, 33],
                       "认不出的那一位是问号，整注不丢")
        XCTAssertEqual(holed?[.back], [5, 9])

        // 票面原文里前后区之间还印着 `+`，那条老路照旧走
        XCTAssertEqual(TicketTextParser.singleLineForTesting("12 15 19 31 33 + 05 09",
                                                             game: .dlt)?[.front],
                       [12, 15, 19, 31, 33])
        // 顺序错了的不能收 —— 前区必须升序
        XCTAssertNil(TicketTextParser.singleLineForTesting("15 12 19 31 33 05 09", game: .dlt))
    }

    /// 划不出格子的时候，调试图要说得出**每一条墨迹带切了几段** ——
    /// 否则"候选行 0 条"看不出是没切出带来、还是段数卡在上限外面。
    func testBandShapesReportsEveryBand() {
        let shapes = NumberGrid.bandShapes(in: ticket().mask, within: 0...(width - 1))
        XCTAssertEqual(shapes, [7, 7, 7, 7, 7])
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
