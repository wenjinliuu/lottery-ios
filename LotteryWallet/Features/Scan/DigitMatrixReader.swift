import Foundation
import UIKit

/// 数字型彩种的号码**矩阵**：完全丢掉 Vision 的分行结果，只用字符坐标重建。
///
/// 这是被一张实体七星彩票逼出来的。把票面量一遍就知道为什么之前怎么调都不对：
///
/// | | 像素 |
/// |---|---|
/// | 单个数字 | 21 宽 × 29 高 |
/// | 左右相邻两个号码 | 间距 76（空白 **55**）|
/// | 上下相邻两注 | 间距 41（空白 **12**）|
///
/// **上下的空隙比左右的空隙窄 4.5 倍。** 票面上这 5 注 × 7 位是印成一个
/// 紧密的竖排矩阵的，任何「先找文本行」的 OCR 在这种排版下都会把**竖列**
/// 当成一行读 —— 相册里点文本识别，高亮框就是一条条竖的。
///
/// 也就是说：Vision 并不是认不出这些数字，它认出来了，但是**按列读的**。
/// 我们整条流水线按横行切，前提从第一步就是错的，后面再怎么补都是白费。
///
/// 所以这里不再问 Vision「这一行是什么」，只问「每个数字在哪儿」：
///
/// 1. 用 `.fast` 拿到**逐字符**的框。必须是 `.fast` ——
///    `.accurate` 下 `boundingBox(for:)` 对一个词里的每个字符返回**同一个框**
///    （Apple DTS 确认的 bug），拿它做几何分析等于拿一堆相同的坐标做分析。
/// 2. 按纵坐标聚成一条条横带，横带内按横向空隙聚成一个个号码。
/// 3. 号码之间的空隙有两个半字宽，而流水号 `110310-251461` 里的数字是挨着的 ——
///    这个差别就是把投注矩阵从票号、期号、金额里挑出来的判据。
/// 4. 把所有横带的号码位置汇到一起估出列栅格（5 行 × 7 列 = 35 个样本估 7 个列位，
///    丢掉一小半也稳），再把每个号码归到自己的列上。
/// 5. 栅格上空着的格子单独裁出来重认；还是认不出的标成问号交给用户补。
enum DigitMatrixReader {

    /// 矩阵里的一注。
    struct Row {
        /// 这一行占的纵向区间（归一化，Vision 的 y 向上为正）。
        let band: ClosedRange<CGFloat>
        /// 每一列上的号码，认不出的是 nil。
        var values: [Int?]
    }

    struct Matrix {
        let rows: [Row]
        /// 整个矩阵占的纵向区间。复原文本时这一段的原始行要整段换掉。
        let span: ClosedRange<CGFloat>
    }

    /// 一个号码：挨在一起的一到两个数字字符。
    ///
    /// 按「号码」而不是「字符」聚类是关键的一步：七星彩的特别号印的是
    /// `13` `10` 这种两位数，两个字符挨得比印刷步距近得多。
    /// 按字符摆栅格的话，这一位会被拆成两列，整行就错位了。
    struct Token: Equatable {
        let value: Int
        let box: CGRect
        var center: CGFloat { box.midX }
    }

    // MARK: - 入口

    static func read(image: UIImage, columns: Int) async -> Matrix? {
        guard columns > 0 else { return nil }
        let chars = await allDigits(in: image)
        guard chars.count >= columns else { return nil }

        let glyphHeight = median(chars.map(\.box.height))
        let glyphWidth = median(chars.map(\.box.width))
        guard glyphHeight > 0, glyphWidth > 0 else { return nil }

        let bands = groupIntoBands(chars, glyphHeight: glyphHeight)
        let candidates = bands.compactMap { band -> (band: ClosedRange<CGFloat>, tokens: [Token])? in
            let tokens = tokenize(band, glyphWidth: glyphWidth)
            guard isBetRow(tokens, columns: columns, glyphWidth: glyphWidth) else { return nil }
            return (bandRange(band), tokens)
        }
        guard !candidates.isEmpty else { return nil }

        guard let grid = columnGrid(candidates.map(\.tokens),
                                    columns: columns,
                                    glyphWidth: glyphWidth) else { return nil }

        var rows: [Row] = []
        for candidate in candidates {
            // 有一行归不进栅格就**整个矩阵作废**。悄悄跳过那一行的话，
            // 用户手里五注的票在票夹里变成四注，而且哪里少了完全看不出来 ——
            // 那比退回旧办法糟得多。
            guard var values = assign(candidate.tokens, to: grid, glyphWidth: glyphWidth) else {
                return nil
            }
            for index in values.indices where values[index] == nil {
                values[index] = await readCell(image: image,
                                               column: grid[index],
                                               band: candidate.band,
                                               width: glyphWidth)
            }
            rows.append(Row(band: candidate.band, values: values))
        }
        guard !rows.isEmpty else { return nil }
        // 一多半都是问号就别拿出来了，那多半根本没找对地方
        let known = rows.reduce(0) { $0 + $1.values.compactMap { $0 }.count }
        guard known * 2 >= rows.count * columns else { return nil }

        let low = rows.map(\.band.lowerBound).min() ?? 0
        let high = rows.map(\.band.upperBound).max() ?? 1
        return Matrix(rows: rows, span: low...high)
    }

    // MARK: - 取字符

    /// 整张票上所有的数字字符。
    ///
    /// 跑两遍：原图一遍、**加了对比度**的一遍，按位置取并集。
    /// 热敏票印在银灰纸上，票面反光、纸还是弯的，原图上有些笔画淡到模型看不见；
    /// 拉一把对比度就出来了。反过来对比度拉过头又会糊掉另一些，所以两遍都要。
    private static func allDigits(in image: UIImage) async -> [TicketVisionScanner.DigitChar] {
        var kept: [TicketVisionScanner.DigitChar] = []
        var sources = [image]
        if let boosted = TicketVisionScanner.contrastBoosted(image) { sources.append(boosted) }
        for source in sources {
            for char in await TicketVisionScanner.recognizeDigits(in: source, fast: true) {
                guard !kept.contains(where: { $0.box.intersects(char.box) }) else { continue }
                kept.append(char)
            }
        }
        return kept
    }

    // MARK: - 聚类

    /// 按纵坐标聚成一条条横带。
    static func groupIntoBands(_ chars: [TicketVisionScanner.DigitChar],
                                       glyphHeight: CGFloat) -> [[TicketVisionScanner.DigitChar]] {
        // Vision 的 y 向上为正，从上往下排就是 midY 递减
        let sorted = chars.sorted { $0.box.midY > $1.box.midY }
        let tolerance = glyphHeight * 0.6
        var bands: [[TicketVisionScanner.DigitChar]] = []
        for char in sorted {
            if let last = bands.last, let anchor = last.first,
               abs(anchor.box.midY - char.box.midY) <= tolerance {
                bands[bands.count - 1].append(char)
            } else {
                bands.append([char])
            }
        }
        return bands
    }

    /// 一条横带里的字符按横向空隙聚成一个个号码。
    static func tokenize(_ band: [TicketVisionScanner.DigitChar],
                                 glyphWidth: CGFloat) -> [Token] {
        let sorted = band.sorted { $0.box.minX < $1.box.minX }
        var tokens: [Token] = []
        var digits: [TicketVisionScanner.DigitChar] = []

        func flush() {
            guard let first = digits.first else { return }
            let box = digits.dropFirst().reduce(first.box) { $0.union($1.box) }
            let value = digits.reduce(0) { $0 * 10 + $1.value }
            tokens.append(Token(value: value, box: box))
            digits = []
        }

        for char in sorted {
            if let previous = digits.last, char.box.minX - previous.box.maxX > glyphWidth * 0.9 {
                flush()
            }
            digits.append(char)
        }
        flush()
        return tokens
    }

    static func bandRange(_ band: [TicketVisionScanner.DigitChar]) -> ClosedRange<CGFloat> {
        let low = band.map(\.box.minY).min() ?? 0
        let high = band.map(\.box.maxY).max() ?? 0
        return Swift.min(low, high)...Swift.max(low, high)
    }

    /// 这一条横带像不像一注投注号码。
    ///
    /// 两个判据缺一不可：
    /// - **个数**：不能多于该有的列数，也不能少太多。
    /// - **间距**：号码之间要有两个多字宽的空白。这一条才是真正管用的 ——
    ///   票号行 `110310-251461-120958` 的 token 个数也可能凑巧落在范围里，
    ///   但它的数字是挨着印的，中间只有一个短横的宽度。
    static func isBetRow(_ tokens: [Token], columns: Int, glyphWidth: CGFloat) -> Bool {
        guard tokens.count <= columns, tokens.count >= Swift.max(2, columns - 2) else { return false }
        // 每个号码最多两位（七星彩的特别号）
        guard tokens.allSatisfy({ $0.box.width <= glyphWidth * 2.6 }) else { return false }
        guard tokens.count > 1 else { return false }
        let gaps = zip(tokens, tokens.dropFirst()).map { $1.box.minX - $0.box.maxX }
        return median(gaps) > glyphWidth * 1.5
    }

    /// 列栅格：把所有候选行的号码位置汇到一起估出来。
    ///
    /// 这是矩阵这条路比逐行分析强的地方 —— 7 列 5 行就是 35 个样本去估 7 个列位，
    /// 哪怕漏掉一小半，列的位置依然是稳的。
    static func columnGrid(_ rows: [[Token]],
                                   columns: Int,
                                   glyphWidth: CGFloat) -> [ClosedRange<CGFloat>]? {
        // 优先只用**号码个数正好齐**的那几行来定列位：它们每一列都有样本，
        // 缺号的行反而会把某一列的中心带偏。一行齐的都没有才退回全用。
        let complete = rows.filter { $0.count == columns }
        let pool = (complete.isEmpty ? rows : complete).flatMap { $0 }
        let sorted = pool.sorted { $0.center < $1.center }
        guard let first = sorted.first else { return nil }
        var clusters: [[Token]] = [[first]]
        for token in sorted.dropFirst() {
            let anchor = clusters[clusters.count - 1].map(\.center).reduce(0, +)
                / CGFloat(clusters[clusters.count - 1].count)
            if token.center - anchor <= glyphWidth * 1.2 {
                clusters[clusters.count - 1].append(token)
            } else {
                clusters.append([token])
            }
        }
        guard clusters.count == columns else { return nil }
        return clusters.map { cluster in
            let low = cluster.map(\.box.minX).min() ?? 0
            let high = cluster.map(\.box.maxX).max() ?? 0
            return Swift.min(low, high)...Swift.max(low, high)
        }
    }

    /// 把一行的号码归到各自的列上。归不进去的就整行作废 —— 摆错位比认不出更糟。
    static func assign(_ tokens: [Token],
                               to grid: [ClosedRange<CGFloat>],
                               glyphWidth: CGFloat) -> [Int?]? {
        var values = [Int?](repeating: nil, count: grid.count)
        for token in tokens {
            let index = grid.indices.min {
                abs(midpoint(grid[$0]) - token.center) < abs(midpoint(grid[$1]) - token.center)
            }
            guard let index,
                  abs(midpoint(grid[index]) - token.center) <= glyphWidth * 1.2,
                  values[index] == nil else { return nil }
            values[index] = token.value
        }
        return values
    }

    private static func midpoint(_ range: ClosedRange<CGFloat>) -> CGFloat {
        (range.lowerBound + range.upperBound) / 2
    }

    // MARK: - 补空格

    /// 把某一个空着的格子单独裁出来再认一遍。
    ///
    /// 位置是**行带 × 列位**交出来的，不是猜的。裁得比格子宽一点，
    /// Vision 按"词"工作，给它一点上下文它才肯认。
    private static func readCell(image: UIImage,
                                 column: ClosedRange<CGFloat>,
                                 band: ClosedRange<CGFloat>,
                                 width glyphWidth: CGFloat) async -> Int? {
        guard let cgImage = image.cgImage else { return nil }
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let padX = glyphWidth * 0.8
        let padY = (band.upperBound - band.lowerBound) * 0.35
        let left = Swift.max(column.lowerBound - padX, 0) * imageWidth
        let right = Swift.min(column.upperBound + padX, 1) * imageWidth
        // Vision 的 y 向上为正，位图向下
        let top = (1 - Swift.min(band.upperBound + padY, 1)) * imageHeight
        let bottom = (1 - Swift.max(band.lowerBound - padY, 0)) * imageHeight
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard rect.width > 6, rect.height > 6, let cell = cgImage.cropping(to: rect) else { return nil }

        let slice = UIImage(cgImage: cell, scale: 1, orientation: .up)
        for boosted in [false, true] {
            let source = boosted ? (TicketVisionScanner.contrastBoosted(slice) ?? slice) : slice
            guard let big = TicketVisionScanner.upscaled(source, factor: 10) else { continue }
            let chars = await TicketVisionScanner.recognizeDigits(in: big, fast: true)
            guard chars.count == 1, let only = chars.first else { continue }
            return only.value
        }
        return nil
    }

    // MARK: - 小工具

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
