import Foundation
import UIKit

/// 自己训练的数字模型：给一小块票面，说它是 0–9 里的哪一个，或者「不是数字」。
///
/// 它不单独拿主意，只当**第二个读数的**：Apple Vision 读一遍、它读一遍，
/// 两边说的不一样就把那一格标成问号（见 `DigitCrossCheck`）。数字型彩种任何数字都合法，
/// 读错了没有别的办法发现 —— 两个互不相干的读法对一遍，是唯一能抓住「认错了还看起来对」的手段。
///
/// 模型在 `lottery-ocr` 仓库里训练（`tools/train_digits.py`），权重是 `DigitNet.bin`：
/// 四个字节的标记后面跟着全部参数。两层卷积加两层全连接，约六万个参数，
/// 这里用纯 Swift 算，不依赖任何机器学习框架。
///
/// **预处理和网络必须与 `tools/digit_model.py` 逐步一致**，
/// `DigitClassifierTests` 拿训练时导出的样例逐个对拍。改一边必须改另一边。
struct DigitClassifier {
    static let side = 28
    static let classes = 11
    /// 第 11 类：不是数字（字母、括号、圈码、汉字的一部分）。
    static let reject = 10

    private static let shapes = [12 * 9, 12, 24 * 12 * 9, 24, 48 * 1176, 48, 11 * 48, 11]

    private let conv1Weight: [Float], conv1Bias: [Float]
    private let conv2Weight: [Float], conv2Bias: [Float]
    private let fc1Weight: [Float], fc1Bias: [Float]
    private let fc2Weight: [Float], fc2Bias: [Float]

    /// 安装包里的那一份。读不出来就是 nil —— 交叉校验整个跳过，识别照旧。
    static let shared: DigitClassifier? = {
        guard let url = Bundle(for: AppDelegate.self).url(forResource: "DigitNet", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        return DigitClassifier(data: data)
    }()

    init?(data: Data) {
        let total = Self.shapes.reduce(0, +)
        guard data.count == 4 + total * 4, data.prefix(4) == Data("DGN1".utf8) else { return nil }
        var floats = [Float](repeating: 0, count: total)
        floats.withUnsafeMutableBytes { buffer in
            _ = data.subdata(in: 4..<data.count).copyBytes(to: buffer)
        }
        var offset = 0
        func take(_ count: Int) -> [Float] {
            defer { offset += count }
            return Array(floats[offset..<offset + count])
        }
        conv1Weight = take(Self.shapes[0]); conv1Bias = take(Self.shapes[1])
        conv2Weight = take(Self.shapes[2]); conv2Bias = take(Self.shapes[3])
        fc1Weight = take(Self.shapes[4]); fc1Bias = take(Self.shapes[5])
        fc2Weight = take(Self.shapes[6]); fc2Bias = take(Self.shapes[7])
    }

    // MARK: - 预处理

    /// 一小块灰度图（深色墨、浅色纸）→ 28×28，墨是 1、纸是 0。
    ///
    /// 1. 取第 5 和第 95 百分位当黑白两端，线性拉伸；
    /// 2. 放进边长为 max(宽, 高) × 1.25 的正方形中央；
    /// 3. 缩到 28×28：每个输出像素取原图上对应矩形里的平均，矩形里没有像素就取最近的那个。
    static func preprocess(pixels: [UInt8], width: Int, height: Int) -> [Float] {
        guard width > 0, height > 0, pixels.count == width * height else {
            return [Float](repeating: 0, count: side * side)
        }
        let ordered = pixels.sorted()
        func percentile(_ q: Double) -> Float {
            Float(ordered[Int((q * Double(ordered.count - 1)).rounded(.down))])
        }
        let low = percentile(0.05), high = percentile(0.95)
        let canvasSide = Int((Double(max(width, height)) * 1.25).rounded(.up))
        var canvas = [Float](repeating: 0, count: canvasSide * canvasSide)
        let top = (canvasSide - height) / 2, left = (canvasSide - width) / 2
        for y in 0..<height {
            for x in 0..<width {
                let ink = (high - Float(pixels[y * width + x])) / (high - low + 1e-6)
                canvas[(top + y) * canvasSide + left + x] = min(max(ink, 0), 1)
            }
        }
        let step = Double(canvasSide) / Double(side)
        func span(_ index: Int) -> Range<Int> {
            var start = Int((Double(index) * step - 0.5).rounded(.up))
            var end = Int((Double(index + 1) * step - 0.5).rounded(.up))
            if end <= start {
                start = min(Int((Double(index) + 0.5) * step), canvasSide - 1)
                end = start + 1
            }
            return start..<min(end, canvasSide)
        }
        var output = [Float](repeating: 0, count: side * side)
        for row in 0..<side {
            let rows = span(row)
            for column in 0..<side {
                let columns = span(column)
                var sum: Float = 0
                for y in rows { for x in columns { sum += canvas[y * canvasSide + x] } }
                output[row * side + column] = sum / Float(rows.count * columns.count)
            }
        }
        return output
    }

    // MARK: - 网络

    /// 3×3 卷积（四周补零）+ ReLU + 2×2 取最大。输入输出都是「通道、行、列」的顺序。
    private static func block(_ input: [Float], channels: Int, size: Int,
                              weight: [Float], bias: [Float]) -> [Float] {
        let filters = bias.count
        var activated = [Float](repeating: 0, count: filters * size * size)
        for filter in 0..<filters {
            for y in 0..<size {
                for x in 0..<size {
                    var sum = bias[filter]
                    for channel in 0..<channels {
                        let base = (filter * channels + channel) * 9
                        for ky in 0..<3 {
                            let sy = y + ky - 1
                            guard sy >= 0, sy < size else { continue }
                            for kx in 0..<3 {
                                let sx = x + kx - 1
                                guard sx >= 0, sx < size else { continue }
                                sum += weight[base + ky * 3 + kx] * input[(channel * size + sy) * size + sx]
                            }
                        }
                    }
                    activated[(filter * size + y) * size + x] = max(sum, 0)
                }
            }
        }
        let half = size / 2
        var pooled = [Float](repeating: 0, count: filters * half * half)
        for filter in 0..<filters {
            for y in 0..<half {
                for x in 0..<half {
                    let origin = (filter * size + y * 2) * size + x * 2
                    pooled[(filter * half + y) * half + x] = max(max(activated[origin], activated[origin + 1]),
                                                                max(activated[origin + size], activated[origin + size + 1]))
                }
            }
        }
        return pooled
    }

    private static func dense(_ input: [Float], weight: [Float], bias: [Float]) -> [Float] {
        var output = bias
        for unit in 0..<bias.count {
            var sum: Float = 0
            let base = unit * input.count
            for index in 0..<input.count { sum += weight[base + index] * input[index] }
            output[unit] += sum
        }
        return output
    }

    /// 11 个类别的原始输出（softmax 之前）。
    func logits(_ input: [Float]) -> [Float] {
        let first = Self.block(input, channels: 1, size: 28, weight: conv1Weight, bias: conv1Bias)
        let second = Self.block(first, channels: 12, size: 14, weight: conv2Weight, bias: conv2Bias)
        let hidden = Self.dense(second, weight: fc1Weight, bias: fc1Bias).map { max($0, 0) }
        return Self.dense(hidden, weight: fc2Weight, bias: fc2Bias)
    }

    struct Verdict: Equatable {
        /// 0–9，或者 `DigitClassifier.reject`。
        var digit: Int
        /// 0–1，这个答案占的概率。
        var confidence: Float
    }

    func classify(pixels: [UInt8], width: Int, height: Int) -> Verdict {
        let raw = logits(Self.preprocess(pixels: pixels, width: width, height: height))
        let peak = raw.max() ?? 0
        let exps = raw.map { exp($0 - peak) }
        let total = exps.reduce(0, +)
        let best = exps.indices.max { exps[$0] < exps[$1] } ?? Self.reject
        return Verdict(digit: best, confidence: exps[best] / total)
    }
}

/// 两个读数怎么合成一个结论。
enum DigitCrossCheck {
    /// 模型要有多大把握，才配否决 Vision 的读数。
    ///
    /// 定在训练报告里「把握超过这个数的测试样本一个都没认错」的那一档。
    /// 定低了会把 Vision 读对的格子冤枉成问号；定高了等于没有这道校验。
    static let threshold: Float = 0.9

    /// - Returns: 这一格最后的值，以及是不是因为两边打架才变成问号的。
    ///
    /// 只有一种情况会改结果：**Vision 读出了一个数，模型很有把握地说是另一个数**。
    /// 这时谁也不信，标问号让人看一眼。其余情况一律保持 Vision 的读数：
    /// - 模型没把握、或者说「不是数字」：它的意见不算数；
    /// - Vision 没读出来：只剩模型一个读数，没有东西可以对，仍然是问号 ——
    ///   拿单独一个读数去填，就又回到「认错了还看起来对」。
    static func resolve(vision: Int?, model: DigitClassifier.Verdict?) -> (value: Int?, disagreed: Bool) {
        guard let vision else { return (nil, false) }
        guard let model, model.digit != DigitClassifier.reject, model.confidence >= threshold else {
            return (vision, false)
        }
        return model.digit == vision ? (vision, false) : (nil, true)
    }
}

/// 把配准后的号码区画成和墨迹图一样大的一张图，取红色通道。
///
/// 用红色通道是因为福彩票的底纹是粉红色的：在红色通道里它几乎是白的，
/// 而黑色的字照样是黑的。训练时抠数字用的也是红色通道。
enum ZoneRaster {
    static func red(_ cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
    }

    /// 一格里**有墨的那一块**，四周各让 3 个像素。格子里没有墨返回 nil。
    ///
    /// 模型训练时看的是贴着字裁的小图，所以这里也要先收到墨的外接框，
    /// 不能把整个格子（大半是空白）直接喂进去。
    static func glyph(in rect: CGRect, mask: InkMask, red: [UInt8]) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard red.count == mask.width * mask.height else { return nil }
        let x0 = max(Int((rect.minX * CGFloat(mask.width)).rounded(.down)), 0)
        let x1 = min(Int((rect.maxX * CGFloat(mask.width)).rounded(.up)), mask.width)
        let y0 = max(Int((rect.minY * CGFloat(mask.height)).rounded(.down)), 0)
        let y1 = min(Int((rect.maxY * CGFloat(mask.height)).rounded(.up)), mask.height)
        guard x1 > x0, y1 > y0 else { return nil }
        var left = x1, right = x0 - 1, top = y1, bottom = y0 - 1
        for y in y0..<y1 {
            for x in x0..<x1 where mask.ink[y * mask.width + x] {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        left = max(left - 3, 0); top = max(top - 3, 0)
        right = min(right + 3, mask.width - 1); bottom = min(bottom + 3, mask.height - 1)
        let width = right - left + 1, height = bottom - top + 1
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { pixels[y * width + x] = red[(top + y) * mask.width + left + x] }
        }
        return (pixels, width, height)
    }
}
