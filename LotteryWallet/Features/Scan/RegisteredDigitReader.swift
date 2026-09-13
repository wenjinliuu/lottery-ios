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
        var matrix: DigitMatrixReader.Matrix
        /// 划出来的格子，画在调试图上。
        var grid: NumberGrid
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
        let chars = await DigitMatrixReader.allDigits(in: zone)
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
            return Outcome(reading: nil,
                           note: "格子路：划不齐（要 \(layout.columns) 位）。"
                               + "号码区 \(mask.width)×\(mask.height)，"
                               + "墨迹带 \(bands.isEmpty ? "—" : bands) 段，"
                               + "候选行 \(rough.count) 条，对得齐 \(consensus.count) 条，"
                               + "每行切出 \(shape.isEmpty ? "—" : shape) 段，"
                               + "定出 \(cut) 列，挑列\(choice)，"
                               + "Vision 认出 \(chars.count) 个数字")
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

        // 空格子单独补认。只剩几个，慢一点无所谓。
        var blanks = 0
        var filled = 0
        for row in values.indices {
            for column in values[row].indices where values[row][column] == nil {
                guard let rect = grid.cell(row: row, column: column),
                      maximums.indices.contains(column) else { continue }
                blanks += 1
                values[row][column] = await reread(zone: zone, rect: rect,
                                                   maximum: maximums[column])
                if values[row][column] != nil { filled += 1 }
            }
        }

        // **印得下两位、却只读出一位的格子，也要再认一遍。**
        //
        // 七星彩的特别号 `13` `10` 真机上还是读成 `3` `0`：格子画得好好的
        // （调试图上那一列明明白白框住了两位），整块认那一遍却只交回一个 `3` ——
        // 十位那一竖又细又淡，在整块图里 Vision 直接漏掉了。
        // 而 `reread` 会把这一格单独裁出来放大好几倍、再加一遍对比度，
        // 十位就出来了。上一版只给**空格子**补认，这一格有值（`3`），
        // 于是永远轮不到它 —— 错得看起来还挺对，正是硬约束要防的那种。
        //
        // 只查"这一列印得下两位、却只读出一位"的格子：七星彩每张票最多 5 格，
        // 大乐透的 `05` 本来就读出两位，不会进来。
        var widened = 0
        for row in values.indices {
            for column in values[row].indices {
                guard maximums.indices.contains(column), maximums[column] > 9,
                      let value = values[row][column], value < 10,
                      let rect = grid.cell(row: row, column: column) else { continue }
                guard let better = await reread(zone: zone, rect: rect,
                                                maximum: maximums[column]),
                      better >= 10 else { continue }
                // 只在补认真的读出两位时才换 —— 读回同一个一位数就别动
                values[row][column] = better
                widened += 1
            }
        }

        // 一多半都是问号就别拿出来了，那多半根本没划对地方
        let known = values.reduce(0) { $0 + $1.compactMap { $0 }.count }
        let total = values.count * layout.columns
        guard known * 2 >= total else {
            return Outcome(reading: nil,
                           note: "格子路：\(total) 格里只认出 \(known) 格，一多半是问号，不敢用")
        }

        var rows: [DigitMatrixReader.Row] = []
        for (index, line) in values.enumerated() {
            guard let band = visionBand(of: grid.rows[index], frame: frame) else {
                return Outcome(reading: nil, note: "格子路：格子映射不回票面")
            }
            rows.append(DigitMatrixReader.Row(band: band, values: line))
        }
        guard !rows.isEmpty else {
            return Outcome(reading: nil, note: "格子路：一注都没切出来")
        }
        let low = rows.map(\.band.lowerBound).min() ?? 0
        let high = rows.map(\.band.upperBound).max() ?? 1
        return Outcome(
            reading: Reading(matrix: .init(rows: rows, span: low...high), grid: grid),
            note: "号码按配准后的格子读：\(rows.count) 注 × \(layout.columns) 位，"
                + "\(total) 格里认出 \(known) 格"
                + "（整块认一遍剩 \(blanks) 格空的，补认补上 \(filled) 格"
                + (widened > 0 ? "，\(widened) 格补成两位" : "") + "）")
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

    // MARK: - 补认

    /// 把一格单独裁出来再认一遍。
    ///
    /// 裁得比格子宽一点：Vision 按「词」工作，贴着字边裁它经常什么都不给。
    /// 允许两位是为了七星彩的特别号（0–14 印成 `13` `10`）。
    ///
    /// **认出来的字符要按格子自己的范围再筛一道。** 裁的时候左右各让了
    /// 0.8 个格宽，邻居的一位数很容易跟着进来；上一版是「认出超过两位就整个丢掉」，
    /// 于是本来认对了的那一格反而变成问号 —— 真机上七星彩五注里三注的特别号
    /// 就是这么丢的。格子在哪儿是墨迹量出来的、可信；认出几个字符是 OCR 说的、
    /// 不可信。所以拿可信的那个去筛不可信的那个，而不是一票作废。
    static func reread(zone: UIImage, rect: CGRect, maximum: Int) async -> Int? {
        guard let cgImage = zone.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        // 左右留白：Vision 贴着字边裁经常什么都不给，所以要让一点。
        // 但**格子本身很宽时不能按宽度让** —— 七星彩的末列现在是个大格
        // （见 `NumberGrid.catchAllTail`），按 0.8 倍宽让出去会一直让到
        // 前一个号码上，邻居跟着进来。按字高让就和格子宽度无关了。
        let padX = Swift.min(rect.width * 0.8, rect.height * 0.6)
        let padY = rect.height * 0.3
        let cropLeft = Swift.max(rect.minX - padX, 0)
        let cropRight = Swift.min(rect.maxX + padX, 1)
        let left = cropLeft * width
        let right = cropRight * width
        let top = Swift.max(rect.minY - padY, 0) * height
        let bottom = Swift.min(rect.maxY + padY, 1) * height
        let box = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard box.width > 6, box.height > 6, cropRight > cropLeft,
              let cropped = cgImage.cropping(to: box) else {
            return nil
        }
        // 格子本身在这张裁图里占的横向范围（0–1）。认出来的字符落在这以外的
        // 就是邻居，不是这一格的。两边各松 5%，让贴着格边的笔画还算数。
        let span = cropRight - cropLeft
        let cellLow = (rect.minX - cropLeft) / span - 0.05
        let cellHigh = (rect.maxX - cropLeft) / span + 0.05
        let slice = UIImage(cgImage: cropped, scale: 1, orientation: .up)

        // **取认得最全的那一遍，不是第一遍成功的那一遍。**
        // 先成功先返回的话，"只认出个位"的那一遍一旦先跑出来，
        // 后面本来能认出两位的就再也没机会了 —— 七星彩的 `13` 一直读成 `3`
        // 就是这么来的。
        var best: Int?
        var bestCount = 0
        for factor in [8.0, 12.0, 18.0] as [CGFloat] {
            for boosted in [false, true] {
                let source = boosted ? (TicketVisionScanner.contrastBoosted(slice) ?? slice) : slice
                guard let big = TicketVisionScanner.upscaled(source, factor: factor) else { continue }
                let chars = await TicketVisionScanner.recognizeDigits(in: big, fast: true)
                    .filter { (0.15...0.85).contains($0.box.midY) }
                    .filter { cellLow <= $0.box.midX && $0.box.midX <= cellHigh }
                guard (1...2).contains(chars.count) else { continue }
                let value = chars.reduce(0) { $0 * 10 + $1.value }
                guard value <= maximum, chars.count > bestCount else { continue }
                bestCount = chars.count
                best = value
            }
        }
        return best
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
    func debugCells(frame: TicketFrame) -> [ScanDebugReport.Cell] {
        var out: [ScanDebugReport.Cell] = []
        for row in rows.indices {
            for column in columns.indices {
                guard let rect = cell(row: row, column: column),
                      let corners = frame.restore(rect) else { continue }
                out.append(.init(corners: corners, row: row, column: column))
            }
        }
        return out
    }
}
