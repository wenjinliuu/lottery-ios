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
        let chars = await TicketVisionScanner.allDigits(in: zone)
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
                values[row][column] = await reread(zone: zone, rect: rect,
                                                   maximum: maximums[column])
                if values[row][column] != nil { filled += 1 }
            }
        }

        // 一多半都是问号就别拿出来了，那多半根本没划对地方
        let known = values.reduce(0) { $0 + $1.compactMap { $0 }.count }
        let total = values.count * layout.columns
        guard known * 2 >= total else {
            return Outcome(reading: nil,
                           note: "格子路：\(total) 格里只认出 \(known) 格，一多半是问号，不敢用")
        }

        // 号码区右边单独分出去的那一块（七星彩的特别号）：**整条喂一次**。
        //
        // 上一版是一注裁一块、每块试 6 遍 —— 五注就是 30 次 Vision 调用，
        // 一张票光这一项就要好几秒。而这五个号码在票面上本来就是一竖排、
        // 左右什么都没有，裁成一条窄带一次喂过去，Vision 返回的字符带着坐标，
        // 按行带对号入座就行了。**30 次变 1 次，而且认得更准** ——
        // 窄带里只有这五个数，没有别的字符来抢坐标。
        var tailValues = [Int?](repeating: nil, count: grid.rows.count)
        var tailNote = ""
        if let trailing = layout.trailing, let strip = grid.trailingStrip(trailing) {
            let outcome = await readTrailingStrip(zone: zone, grid: grid,
                                                  strip: strip, maximum: trailing.maximum)
            tailValues = outcome.values
            let read = outcome.values.compactMap { $0 }.count
            tailNote = "，特别号整条读出 \(read)/\(grid.rows.count)"
            if !outcome.raw.isEmpty { tailNote += "，Vision 给的是「\(outcome.raw)」" }
        } else if layout.trailing != nil {
            tailNote = "，特别号那一块划不出来"
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
        return Outcome(
            reading: Reading(matrix: .init(rows: rows, span: low...high), grid: grid),
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

    // MARK: - 特别号那一条

    /// 整条特别号带**喂一次**，返回每一注的值 + Vision 给的原文。
    ///
    /// 原文一并带出来是这一版特意加的：前面五轮都在猜「Vision 到底认出了什么」，
    /// 而调试图只报得出「认出几格」。有了原文，下一轮不管哪儿出问题都是一眼的事。
    static func readTrailingStrip(zone: UIImage,
                                  grid: NumberGrid,
                                  strip: ClosedRange<CGFloat>,
                                  maximum: Int) async -> (values: [Int?], raw: String) {
        var values = [Int?](repeating: nil, count: grid.rows.count)
        guard let cgImage = zone.cgImage,
              let first = grid.rows.first, let last = grid.rows.last else {
            return (values, "")
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        // 上下各让半行，免得第一注和最后一注贴着裁图边缘
        let rowHeight = first.upperBound - first.lowerBound
        let top = Swift.max(first.lowerBound - rowHeight / 2, 0)
        let bottom = Swift.min(last.upperBound + rowHeight / 2, 1)
        let box = CGRect(x: strip.lowerBound * width, y: top * height,
                         width: (strip.upperBound - strip.lowerBound) * width,
                         height: (bottom - top) * height)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard box.width > 6, box.height > 6, let cropped = cgImage.cropping(to: box) else {
            return (values, "")
        }
        let slice = UIImage(cgImage: cropped, scale: 1, orientation: .up)
        // 窄带很小，放大 6 倍也不贵；一次就够，不再搞多倍数淘汰赛
        guard let big = TicketVisionScanner.upscaled(slice, factor: 6) else {
            return (values, "")
        }
        let chars = await TicketVisionScanner.recognizeDigits(in: big, fast: true)
        guard !chars.isEmpty else { return (values, "") }

        // 每个字符按**纵坐标**归到它那一注：行带是墨迹投影切出来的，可信；
        // Vision 自己的分行不可信（整个项目的奠基测量：上下空隙比左右窄 4.6 倍）。
        var buckets = [[(x: CGFloat, value: Int)]](repeating: [], count: grid.rows.count)
        for char in chars {
            // Vision 的 y 向上为正，翻成左上原点，再换算回整张配准图
            let y = top + (1 - char.box.midY) * (bottom - top)
            guard let row = grid.rows.firstIndex(where: { $0.contains(y) }) else { continue }
            buckets[row].append((char.box.midX, char.value))
        }
        for row in buckets.indices {
            let digits = buckets[row].sorted { $0.x < $1.x }.map(\.value)
            guard (1...2).contains(digits.count) else { continue }
            let value = digits.reduce(0) { $0 * 10 + $1 }
            // **超上限不降级成个位数。** 上一版在这儿把 `13` 读成 `73` 之后
            // 整个扔掉、拿只认出个位的那一遍顶上，屏幕显示 `3` 而票面是 `13` ——
            // 认错了还看起来对，正是硬约束要挡的那种。读不成就是问号。
            guard value <= maximum else { continue }
            values[row] = value
        }
        let raw = grid.rows.indices.map { row in
            buckets[row].sorted { $0.x < $1.x }.map { String($0.value) }.joined()
        }.joined(separator: "/")
        return (values, raw)
    }

    // MARK: - 补认


    /// 把一格单独裁出来再认一遍 —— 只给整块那一遍**漏掉的**格子用。
    ///
    /// 裁得比格子宽一点：Vision 按「词」工作，贴着字边裁它经常什么都不给。
    /// 认出来的字符再按格子自己的范围筛一道，邻居的数字不算数 ——
    /// 格子在哪儿是墨迹量出来的、可信；认出几个字符是 OCR 说的、不可信。
    static func reread(zone: UIImage, rect: CGRect, maximum: Int) async -> Int? {
        guard let cgImage = zone.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        // 左右留白：Vision 贴着字边裁经常什么都不给，所以要让一点。
        // 但**格子本身很宽时不能按宽度让** —— 七星彩的特别号那一块是一条宽带
        // （见 `NumberGrid.trailingStrip`），按 0.8 倍宽让出去会一直让到
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

        // **认出什么就拼什么，拼不成就是问号。**
        //
        // 上一版这里是「3 种放大 × 2 种对比度 = 6 遍识别打淘汰赛」，还带两道闸：
        // 认出 3 个字符整遍扔、拼出来超上限整遍扔。结果是**认全了反而被丢** ——
        // 七星彩的 `13` 有一遍把细竖认成 `7`、拼出 `73` 超上限，整遍作废，
        // 于是只认出个位的那一遍夺冠，屏幕显示 `3`。而一张票要为此跑上百次 Vision。
        //
        // 现在只跑两遍：原图一遍、加对比度一遍（热敏票印在银灰纸上，
        // 有些笔画淡到原图上看不见，这一条是实测有用的）。
        // 两遍的字符**按位置取并集**，不再比谁认得多。
        var picked: [(x: CGFloat, value: Int)] = []
        for boosted in [false, true] {
            let source = boosted ? (TicketVisionScanner.contrastBoosted(slice) ?? slice) : slice
            guard let big = TicketVisionScanner.upscaled(source, factor: 12) else { continue }
            let chars = await TicketVisionScanner.recognizeDigits(in: big, fast: true)
                .filter { (0.15...0.85).contains($0.box.midY) }
                .filter { cellLow <= $0.box.midX && $0.box.midX <= cellHigh }
            for char in chars where !picked.contains(where: { abs($0.x - char.box.midX) < 0.05 }) {
                picked.append((char.box.midX, char.value))
            }
        }
        let digits = picked.sorted { $0.x < $1.x }.map(\.value)
        guard (1...2).contains(digits.count) else { return nil }
        let value = digits.reduce(0) { $0 * 10 + $1 }
        // 超上限说明认错了 —— 报问号，不拿其中一位顶上
        return value <= maximum ? value : nil
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
    /// 号码区右边**单独分出去的那一块**在标准矩形里的横向范围。
    ///
    /// 分界线 = 最后一列中心 + `divider` × 列距，列距是这张票自己的
    /// （六列一算就有）。线右边一直到号码区右沿，全算这一块的。
    ///
    /// 右边没边界时（七星彩的行尾不印倍数）就取到 1.0 —— 特别号右边什么都没有，
    /// 多圈一点进来不会圈到别的号码，反而能接住印得靠右、被裁到边上的那种票。
    func trailingStrip(_ trailing: DigitTicketLayout.Trailing) -> ClosedRange<CGFloat>? {
        guard let last = columns.last, columns.count >= 2 else { return nil }
        let centers = columns.map { ($0.lowerBound + $0.upperBound) / 2 }
        let gaps = zip(centers, centers.dropFirst()).map { $1 - $0 }
        guard !gaps.isEmpty else { return nil }
        let pitch = gaps.sorted()[gaps.count / 2]
        guard pitch > 0 else { return nil }
        let low = (last.lowerBound + last.upperBound) / 2 + trailing.divider * pitch
        guard low < 1 else { return nil }
        return low...1
    }


    /// 把格子映射回票面，画到调试图上。
    ///
    /// 画得出来就等于「这个号码来自票面哪个像素格子」答得上来 ——
    /// 硬约束一在界面上的样子就是这些框。
    func debugCells(frame: TicketFrame,
                    trailing: DigitTicketLayout.Trailing? = nil) -> [ScanDebugReport.Cell] {
        var out: [ScanDebugReport.Cell] = []
        for row in rows.indices {
            for column in columns.indices {
                guard let rect = cell(row: row, column: column),
                      let corners = frame.restore(rect) else { continue }
                out.append(.init(corners: corners, row: row, column: column))
            }
            // 分出去的那一块也画出来 —— 它是一条宽带，正没正、有没有咬到
            // 前一位，一眼就能判。硬约束一要的"说得出来自哪块像素"就是这个框。
            guard let trailing, let strip = trailingStrip(trailing) else { continue }
            let rect = CGRect(x: strip.lowerBound, y: rows[row].lowerBound,
                              width: strip.upperBound - strip.lowerBound,
                              height: rows[row].upperBound - rows[row].lowerBound)
            if let corners = frame.restore(rect) {
                out.append(.init(corners: corners, row: row, column: columns.count))
            }
        }
        return out
    }
}
