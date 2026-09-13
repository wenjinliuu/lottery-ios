import Foundation
import UIKit

/// 阶段 2：**先有格子，再去认**。
///
/// 老路是「认出一堆字符 → 从字符坐标估几何 → 按估出来的几何摆号码」。
/// 这条路有个死结：认得越差，几何估得越偏；几何越偏，摆得越错。
/// 七星彩的特别号丢十位、排列5 把票底流水号读成一注，都是从这个死结里长出来的。
///
/// 现在顺序反过来：
///
/// 1. 基准（票面印的机号行 / 哈希行）→ 配准 → 号码区摆成标准矩形
/// 2. 在标准矩形里按**墨迹投影**划格子 —— 和识别结果无关
/// 3. Vision 认出来的每个数字，按位置落进它该落的那一格
/// 4. 空着的格子单独裁出来再认一遍；还是空的就是问号
///
/// 每一个号码都答得出「你来自票面哪一格」，硬约束一就是这么落地的。
/// 摆不上格子的**整个矩阵作废**、退回上一层（硬约束二）——
/// 少认一注用户看得见，摆错位用户看不见。
enum RegisteredDigitReader {

    /// 一次读数的产物。
    struct Reading {
        var matrix: DigitMatrix
        /// 划出来的格子，画在调试图上。
        var grid: NumberGrid
        /// 特别号那一块切出来的字形，也要画出来 —— 切对没切对一眼就看得见。
        var trailing: NumberGrid.TrailingColumns? = nil
    }

    /// 读数的结果 + **一句说明**。
    ///
    /// 说明是这一版专门加的。上一轮我对着识别结果猜"到底走的哪条路、卡在哪一步"，
    /// 猜错了两次 —— 因为「退回老路」和「新路读错」在结果上长得一模一样。
    /// 现在每一步都留一句话，调试图上直接写出来，不用再猜。
    struct Outcome {
        var reading: Reading?
        var note: String
    }

    static func read(image: UIImage,
                     frame: TicketFrame,
                     layout: DigitTicketLayout) async -> Outcome {
        guard let cgImage = image.cgImage else {
            return Outcome(reading: nil, note: "格子路：图片读不出来")
        }
        guard let zoneImage = TicketRegistration.rectified(cgImage, frame: frame) else {
            return Outcome(reading: nil, note: "格子路：号码区裁不出正片")
        }
        guard let mask = InkMask.make(zoneImage), mask.width > 8, mask.height > 8 else {
            return Outcome(reading: nil, note: "格子路：配准后的号码区量不出墨迹")
        }

        let span = TicketRegistration.zoneColumns(frame: frame, width: mask.width)
        let zone = UIImage(cgImage: zoneImage)

        // 整块号码区认一遍，只认一次。这些字符有两个用处：
        // 1. 划格子时当一道**否决**：挑中的那一段列里至少一半得有数字，
        //    否则是整段压在中文标签上了。注意只是否决 —— 注序号列靠它
        //    分不出来（`.fast` 会把 `①` 读成 `0`），那件事交给 `window` 的几何判据
        // 2. 划完之后按位置落进各自的格子
        let pass = await TicketVisionScanner.allDigits(in: zone)
        let chars = pass.chars
        var conflicts = pass.conflicts
        let centers = chars.map { Double($0.box.midX) * Double(mask.width) }
        guard let grid = NumberGrid.build(mask: mask, within: span,
                                          layout: layout, digitCenters: centers) else {
            // 划不出格子时，把中间量到的数报出来 —— 否则只能盯着识别结果猜
            let rough = NumberGrid.candidates(in: mask, within: span, columns: layout.columns)
            let consensus = NumberGrid.betRows(rough, columns: layout.columns)
            let shape = consensus.map { String($0.segments.count) }.joined(separator: "/")
            // 连候选行都没有时，段数上下限是最可能的凶手 —— 把没过筛子的
            // 原始段数也报出来，下一轮不用再猜
            let bands = NumberGrid.bandShapes(in: mask, within: span)
                .map(String.init).joined(separator: "/")
            // `build` 里每一步都可能返回 nil，只报到"划不齐"分不出是哪一步。
            // 大乐透那一轮就卡在这儿：段数、候选行、对齐全对，还是划不齐，
            // 只能靠猜。把后面两步的结果也摊开。
            let ranges = NumberGrid.columnRanges(consensus)
            let cut = ranges.map { "\($0.count)" } ?? "—"
            let picked = ranges.flatMap {
                NumberGrid.select($0, layout: layout, digitCenters: centers)
            }
            let choice = picked.map { "挑中 \($0.count) 列" } ?? "没成"
            var note = "格子路：划不齐（要 \(layout.columns) 位）。"
            note += "号码区 \(mask.width)×\(mask.height)，"
            note += "墨迹带 \(bands.isEmpty ? "—" : bands) 段，"
            note += "候选行 \(rough.count) 条，对得齐 \(consensus.count) 条，"
            note += "每行切出 \(shape.isEmpty ? "—" : shape) 段，"
            note += "定出 \(cut) 列，挑列\(choice)，"
            note += "Vision 认出 \(chars.count) 个数字"
            return Outcome(reading: nil, note: note)
        }

        var values = [[Int?]](repeating: [Int?](repeating: nil, count: layout.columns),
                              count: grid.rows.count)

        // 先一遍过：整块号码区认一次，每个数字按位置落进它该落的格子。
        //
        // 不逐格去认是因为太贵 —— 5 注 × 7 位 × 几个放大倍数，一张票要跑
        // 上百次 Vision。整块认一遍再分配，效果一样而且快得多；
        // 「这个数字属于哪一格」依然是**按位置**定的，不是按顺序猜的。
        // 每一列的上限按版式来：数字型是 0–9，七星彩的特别号 0–14，
        // 大乐透前区 1–35、后区 1–12。超出上限说明落进来的不是这一格的东西。
        let maximums = layout.maximums
        for (cell, digits) in bucket(chars, grid: grid) {
            guard values.indices.contains(cell.row),
                  values[cell.row].indices.contains(cell.column),
                  maximums.indices.contains(cell.column) else { continue }
            let value = digits.reduce(0) { $0 * 10 + $1 }
            guard digits.count <= 2, value <= maximums[cell.column] else { continue }
            values[cell.row][cell.column] = value
        }

        // 整块那一遍漏掉的格子单独补认。
        //
        // **封顶 6 格。** 漏得比这还多说明格子多半没划对地方，再补也是白费 ——
        // 而每一格要跑两次 Vision，不封顶的话一张糊票能跑出几十次调用，
        // 用户等十秒还是一屏问号。超出的那些直接留问号，让人点一下补。
        var blanks = 0
        var filled = 0
        let budget = 6
        for row in values.indices {
            for column in values[row].indices where values[row][column] == nil {
                guard let rect = grid.cell(row: row, column: column),
                      maximums.indices.contains(column) else { continue }
                blanks += 1
                guard filled < budget, blanks <= budget else { continue }
                let outcome = await reread(zone: zone, rect: rect, maximum: maximums[column])
                conflicts += outcome.conflicts
                values[row][column] = outcome.value
                if outcome.value != nil { filled += 1 }
            }
        }

        // 一多半都是问号就别拿出来了，那多半根本没划对地方
        let known = values.reduce(0) { $0 + $1.compactMap { $0 }.count }
        let total = values.count * layout.columns
        guard known * 2 >= total else {
            return Outcome(reading: nil,
                           note: "格子路：\(total) 格里只认出 \(known) 格，一多半是问号，不敢用")
        }

        // 号码区右边单独分出去的那一块（七星彩的特别号）。
        //
        // 先按墨迹切成字形，再决定拿什么去认 —— 见 `NumberGrid.trailingGlyphs`。
        // 两个字形就是 1X（特别号 0–14，十位只能是 1），一个字形就是它自己。
        // 交给 Vision 的永远只有一件它最擅长的事：认一个孤零零的 0–9。
        var tailValues = [Int?](repeating: nil, count: grid.rows.count)
        var tailColumns: NumberGrid.TrailingColumns?
        var tailNote = ""
        if let trailing = layout.trailing {
            if let tail = grid.trailingColumns(mask: mask, within: span,
                                               divider: trailing.divider) {
                tailColumns = tail
                let outcome = await readTrailing(zone: zone, grid: grid, tail: tail,
                                                 maximum: trailing.maximum)
                tailValues = outcome.values
                conflicts += outcome.conflicts
                let read = outcome.values.compactMap { $0 }.count
                tailNote = "，特别号读出 \(read)/\(grid.rows.count)"
                tailNote += "（每注 \(tail.shape) 位，读出「\(outcome.raw)」"
                tailNote += "；\(tail.note)）"
            } else {
                tailNote = "，特别号那一块定不出列"
            }
        }

        var rows: [DigitMatrix.Row] = []
        for (index, line) in values.enumerated() {
            guard let band = visionBand(of: grid.rows[index], frame: frame) else {
                return Outcome(reading: nil, note: "格子路：格子映射不回票面")
            }
            // 特别号接在六位后面，拼成票面上那一注的完整顺序
            let full = layout.trailing == nil ? line : line + [tailValues[index]]
            rows.append(DigitMatrix.Row(band: band, values: full))
        }
        guard !rows.isEmpty else {
            return Outcome(reading: nil, note: "格子路：一注都没切出来")
        }
        let low = rows.map(\.band.lowerBound).min() ?? 0
        let high = rows.map(\.band.upperBound).max() ?? 1
        // 一句一句拼。整句写成一长串 `+` 的话 Swift 的类型检查器会当场罢工
        // （"unable to type-check this expression in reasonable time"）。
        let digits = layout.columns + (layout.trailing == nil ? 0 : 1)
        var note = "号码按配准后的格子读：\(rows.count) 注 × \(digits) 位，"
        note += "\(total) 格里认出 \(known) 格"
        note += "（整块认一遍剩 \(blanks) 格空的，补认补上 \(filled) 格\(tailNote)）"
        // 两遍识别在同一位置给出不同答案的次数。**这一版只数不改** ——
        // 先看真机上到底多久打一次架，再决定要不要把打架的格子标成问号。
        if conflicts > 0 { note += "；两遍识别有 \(conflicts) 处不一致（这一版只统计，不改结果）" }
        return Outcome(
            reading: Reading(matrix: .init(rows: rows, span: low...high),
                             grid: grid, trailing: tailColumns),
            note: note)
    }

    // MARK: - 把数字分进格子

    struct Cell: Hashable {
        var row: Int
        var column: Int
    }

    /// 每个数字按**中心落在哪一格**归位。
    ///
    /// 归位靠的是坐标，不是顺序 —— 少认一个字符只会让那一格空着，
    /// 不会让整行往前挪一位（那正是「每注前面凭空多个 0」的老毛病）。
    static func bucket(_ chars: [TicketVisionScanner.DigitChar],
                       grid: NumberGrid) -> [(Cell, [Int])] {
        var buckets: [Cell: [(x: CGFloat, value: Int)]] = [:]
        for char in chars {
            // Vision 的 y 向上为正，翻成左上原点再和格子比
            let x = char.box.midX
            let y = 1 - char.box.midY
            guard let column = grid.columns.firstIndex(where: { $0.contains(x) }),
                  let row = grid.rows.firstIndex(where: { $0.contains(y) }) else { continue }
            buckets[Cell(row: row, column: column), default: []].append((x, char.value))
        }
        return buckets.map { cell, digits in
            (cell, digits.sorted { $0.x < $1.x }.map(\.value))
        }
    }

    // MARK: - 特别号

    /// 特别号：**十位看有没有墨，只有个位交给 Vision**。
    ///
    /// 取值 0–14 ⇒ 两位数的十位必然是 1，0 又不打头。所以十位列上落了墨
    /// 就是 10+，没落就是个位数本身 —— 见 `NumberGrid.trailingColumns`。
    ///
    /// 个位那一格认不出来（Vision 给 0 个或 2 个字符）就是问号，
    /// 不拿十位顶上凑一个数出来：`1` 比 `13` 更像对的，也就更危险。
    ///
    /// **这里没有宽度判据。** 一度想加一条"十位那一竖必须比个位窄一半"，
    /// 但特别号是 11 的时候两列一样窄，那条判据会把一注对的号判成问号 ——
    /// 又是"认全了反而被丢"。有没有墨本身已经够了。
    static func readTrailing(zone: UIImage,
                             grid: NumberGrid,
                             tail: NumberGrid.TrailingColumns,
                             maximum: Int) async -> (values: [Int?], raw: String, conflicts: Int) {
        var values = [Int?](repeating: nil, count: grid.rows.count)
        var raws: [String] = []
        var clashes = 0
        for row in grid.rows.indices {
            guard tail.hasUnits.indices.contains(row), tail.hasUnits[row] else {
                raws.append("没墨")
                continue
            }
            let tens = tail.hasTens.indices.contains(row) && tail.hasTens[row] ? 10 : 0
            let band = grid.rows[row]
            let rect = CGRect(x: tail.units.lowerBound, y: band.lowerBound,
                              width: tail.units.upperBound - tail.units.lowerBound,
                              height: band.upperBound - band.lowerBound)
            // 十位就贴在左边，裁图往左让的时候不许越过两列的中线，
            // 否则半根竖道进了画面，Vision 会连个位一起读歪。
            var stop: CGFloat = 0
            if tens == 10, let tensColumn = tail.tens {
                stop = (tensColumn.upperBound + tail.units.lowerBound) / 2
            }
            let outcome = await digits(in: zone, rect: rect, notLeftOf: stop)
            let read = outcome.values
            clashes += outcome.conflicts
            let prefix = tens == 10 ? "1" : ""
            raws.append(read.isEmpty ? prefix + "?" : prefix + read.map(String.init).joined())
            guard read.count == 1, let digit = read.first else { continue }
            let value = tens + digit
            guard value <= maximum else { continue }
            values[row] = value
        }
        return (values, raws.joined(separator: "/"), clashes)
    }

    // MARK: - 补认


    /// 把一格单独裁出来再认一遍 —— 只给整块那一遍**漏掉的**格子用。
    ///
    /// 超上限说明认错了，报问号，不拿其中一位顶上。
    static func reread(zone: UIImage, rect: CGRect,
                       maximum: Int) async -> (value: Int?, conflicts: Int) {
        let found = await digits(in: zone, rect: rect)
        guard (1...2).contains(found.values.count) else { return (nil, found.conflicts) }
        let value = found.values.reduce(0) { $0 * 10 + $1 }
        return (value <= maximum ? value : nil, found.conflicts)
    }

    /// 裁一块出来认，返回**认出的数字本身**（从左到右），不做任何取舍。
    ///
    /// 裁得比格子宽一点：Vision 按「词」工作，贴着字边裁它经常什么都不给。
    /// 认出来的字符再按格子自己的范围筛一道，邻居的数字不算数 ——
    /// 格子在哪儿是墨迹量出来的、可信；认出几个字符是 OCR 说的、不可信。
    ///
    /// 跑两遍：原图一遍、加对比度一遍（热敏票印在银灰纸上，有些笔画淡到
    /// 原图上看不见，这一条实测有用），**按位置取并集**，不比谁认得多。
    /// `notLeftOf` 是裁图左沿的下限（标准矩形里的 0–1，0 = 不限）。
    /// 旁边紧挨着另一个字形时用它挡住，别把半个邻居裁进来。
    static func digits(in zone: UIImage, rect: CGRect,
                       notLeftOf stop: CGFloat = 0) async -> (values: [Int], conflicts: Int) {
        guard let cgImage = zone.cgImage else { return ([], 0) }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        // 左右留白按**字高**让，不按格宽 —— 特别号那一块是条宽带，
        // 按 0.8 倍宽让出去会一直让到前一个号码上，邻居跟着进来。
        let padX = Swift.min(rect.width * 0.8, rect.height * 0.6)
        let padY = rect.height * 0.3
        let cropLeft = Swift.max(rect.minX - padX, stop, 0)
        let cropRight = Swift.min(rect.maxX + padX, 1)
        let top = Swift.max(rect.minY - padY, 0) * height
        let bottom = Swift.min(rect.maxY + padY, 1) * height
        let box = CGRect(x: cropLeft * width, y: top,
                         width: (cropRight - cropLeft) * width, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard box.width > 6, box.height > 6, cropRight > cropLeft,
              let cropped = cgImage.cropping(to: box) else { return ([], 0) }
        // 格子本身在这张裁图里占的横向范围（0–1）。两边各松 5%，
        // 让贴着格边的笔画还算数。
        let span = cropRight - cropLeft
        let cellLow = (rect.minX - cropLeft) / span - 0.05
        let cellHigh = (rect.maxX - cropLeft) / span + 0.05
        let slice = UIImage(cgImage: cropped, scale: 1, orientation: .up)

        var picked: [(x: CGFloat, value: Int)] = []
        // 两遍在同一位置给出不同数字的次数。只数不改 —— 见
        // `TicketVisionScanner.allDigits` 上那段说明。
        var conflicts = 0
        for boosted in [false, true] {
            let source = boosted ? (TicketVisionScanner.contrastBoosted(slice) ?? slice) : slice
            guard let big = TicketVisionScanner.upscaled(source, factor: 12) else { continue }
            let chars = await TicketVisionScanner.recognizeDigits(in: big, fast: true)
                .filter { (0.15...0.85).contains($0.box.midY) }
                .filter { cellLow <= $0.box.midX && $0.box.midX <= cellHigh }
            for char in chars {
                if let seen = picked.first(where: { abs($0.x - char.box.midX) < 0.05 }) {
                    if seen.value != char.value { conflicts += 1 }
                    continue
                }
                picked.append((char.box.midX, char.value))
            }
        }
        return (picked.sorted { $0.x < $1.x }.map(\.value), conflicts)
    }

    // MARK: - 换算回票面

    /// 标准矩形里的一行 → 它在**整张票**上占的纵向区间（Vision 坐标，y 向上）。
    ///
    /// 复原文本时要按这个区间把原来那几行整段换掉。
    static func visionBand(of row: ClosedRange<CGFloat>,
                           frame: TicketFrame) -> ClosedRange<CGFloat>? {
        let rect = CGRect(x: 0, y: row.lowerBound, width: 1,
                          height: row.upperBound - row.lowerBound)
        guard let corners = frame.restore(rect) else { return nil }
        let ys = corners.map(\.y)
        guard let top = ys.min(), let bottom = ys.max() else { return nil }
        // 左上原点翻成 Vision 的左下原点
        return (1 - bottom)...(1 - top)
    }
}

extension NumberGrid {
    /// 把格子映射回票面，画到调试图上。
    ///
    /// 画得出来就等于「这个号码来自票面哪个像素格子」答得上来 ——
    /// 硬约束一在界面上的样子就是这些框。
    func debugCells(frame: TicketFrame,
                    trailing: TrailingColumns? = nil) -> [ScanDebugReport.Cell] {
        var out: [ScanDebugReport.Cell] = []
        for row in rows.indices {
            for column in columns.indices {
                guard let rect = cell(row: row, column: column),
                      let corners = frame.restore(rect) else { continue }
                out.append(.init(corners: corners, row: row, column: column))
            }
            // 特别号切出来的每一个字形也画一个框。切成一段还是两段，
            // 就是这一注读 4 还是读 14 的全部依据 —— 框画对了结论就对了。
            guard let trailing else { continue }
            var cells: [ClosedRange<CGFloat>] = []
            if let tens = trailing.tens, trailing.hasTens.indices.contains(row),
               trailing.hasTens[row] {
                cells.append(tens)
            }
            if trailing.hasUnits.indices.contains(row), trailing.hasUnits[row] {
                cells.append(trailing.units)
            }
            for (index, cell) in cells.enumerated() {
                let rect = CGRect(x: cell.lowerBound, y: rows[row].lowerBound,
                                  width: cell.upperBound - cell.lowerBound,
                                  height: rows[row].upperBound - rows[row].lowerBound)
                guard let corners = frame.restore(rect) else { continue }
                out.append(.init(corners: corners, row: row, column: columns.count + index))
            }
        }
        return out
    }
}
