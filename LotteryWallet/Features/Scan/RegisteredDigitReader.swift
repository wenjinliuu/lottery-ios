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
        // 1. 划格子时判断某一列里**有没有数字** —— 注序号那一列没有，
        //    靠这一条把它和号码列分开（几何上分不开，实测列距 62.5 对 65）
        // 2. 划完之后按位置落进各自的格子
        let chars = await DigitMatrixReader.allDigits(in: zone)
        let centers = chars.map { Double($0.box.midX) * Double(mask.width) }
        guard let grid = NumberGrid.build(mask: mask, within: span,
                                          layout: layout, digitCenters: centers) else {
            // 划不出格子时，把中间量到的数报出来 —— 否则只能盯着识别结果猜
            let rough = NumberGrid.candidates(in: mask, within: span, columns: layout.columns)
            let consensus = NumberGrid.betRows(rough, columns: layout.columns)
            let shape = consensus.map { String($0.segments.count) }.joined(separator: "/")
            return Outcome(reading: nil,
                           note: "格子路：划不齐（要 \(layout.columns) 位）。"
                               + "号码区 \(mask.width)×\(mask.height)，"
                               + "候选行 \(rough.count) 条，对得齐 \(consensus.count) 条，"
                               + "每行切出 \(shape.isEmpty ? "—" : shape) 段")
        }

        var values = [[Int?]](repeating: [Int?](repeating: nil, count: layout.columns),
                              count: grid.rows.count)

        // 先一遍过：整块号码区认一次，每个数字按位置落进它该落的格子。
        //
        // 不逐格去认是因为太贵 —— 5 注 × 7 位 × 几个放大倍数，一张票要跑
        // 上百次 Vision。整块认一遍再分配，效果一样而且快得多；
        // 「这个数字属于哪一格」依然是**按位置**定的，不是按顺序猜的。
        for (cell, digits) in bucket(chars, grid: grid) {
            guard values.indices.contains(cell.row),
                  values[cell.row].indices.contains(cell.column) else { continue }
            let maximum = cell.column == layout.columns - 1 ? layout.trailingMaximum : 9
            let value = digits.reduce(0) { $0 * 10 + $1 }
            // 超过这一列的上限说明落进来的不是这一格的东西，当没认出来
            guard digits.count <= 2, value <= maximum else { continue }
            values[cell.row][cell.column] = value
        }

        // 空格子单独补认。只剩几个，慢一点无所谓。
        for row in values.indices {
            for column in values[row].indices where values[row][column] == nil {
                guard let rect = grid.cell(row: row, column: column) else { continue }
                let maximum = column == layout.columns - 1 ? layout.trailingMaximum : 9
                values[row][column] = await reread(zone: zone, rect: rect, maximum: maximum)
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
                + "\(total) 格里认出 \(known) 格")
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
    static func reread(zone: UIImage, rect: CGRect, maximum: Int) async -> Int? {
        guard let cgImage = zone.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let padX = rect.width * 0.8
        let padY = rect.height * 0.3
        let left = Swift.max(rect.minX - padX, 0) * width
        let right = Swift.min(rect.maxX + padX, 1) * width
        let top = Swift.max(rect.minY - padY, 0) * height
        let bottom = Swift.min(rect.maxY + padY, 1) * height
        let box = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard box.width > 6, box.height > 6, let cropped = cgImage.cropping(to: box) else {
            return nil
        }
        let slice = UIImage(cgImage: cropped, scale: 1, orientation: .up)

        // **取认得最全的那一遍，不是第一遍成功的那一遍。**
        // 先成功先返回的话，"只认出个位"的那一遍一旦先跑出来，
        // 后面本来能认出两位的就再也没机会了 —— 七星彩的 `13` 一直读成 `3`
        // 就是这么来的。
        var best: Int?
        var bestCount = 0
        for factor in [10.0, 16.0] as [CGFloat] {
            for boosted in [false, true] {
                let source = boosted ? (TicketVisionScanner.contrastBoosted(slice) ?? slice) : slice
                guard let big = TicketVisionScanner.upscaled(source, factor: factor) else { continue }
                let chars = await TicketVisionScanner.recognizeDigits(in: big, fast: true)
                    .filter { (0.15...0.85).contains($0.box.midY) }
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
