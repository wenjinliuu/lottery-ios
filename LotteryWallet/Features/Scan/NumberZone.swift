import Foundation

/// 票面上印号码的那一块在哪儿，以及把它拉成一张 1000 像素宽的正图。
///
/// 号码区用两行**一定认得出**的文字夹出来，不靠号码本身：
/// - 体彩：上面是「…票 N倍 合计N元」那一行，下面是第一行整句的话（广告语、「感谢您为公益事业…」）；
/// - 福彩：上面是哈希行，下面是「开奖期」那一行。
///
/// 和 `lottery-ocr` 仓库的 `tools/zones.py` 是同一套规则。
enum NumberZone {
    /// 一块识别出来的文字。坐标是像素，原点在左上角。
    struct Line {
        var text: String
        var minX: Double, maxX: Double, minY: Double, maxY: Double
    }

    struct Bounds: Equatable {
        var top: Double, bottom: Double, left: Double, right: Double
    }

    static func bounds(_ lines: [Line], sports: Bool, imageWidth: Double) -> Bounds? {
        let placed = lines.map { line -> Line in
            var copy = line
            copy.text = line.text.replacingOccurrences(of: " ", with: "")
            return copy
        }.sorted { $0.minY < $1.minY }
        var top: Double?, bottom: Double?, left: Double?, right: Double?
        if sports {
            guard let serial = placed.first(where: { matches($0.text, "\\d{5,7}-\\d{5,7}-\\d{5,7}") }) else { return nil }
            let width = serial.maxX - serial.minX
            let leftEdge = serial.minX - width * 0.03
            var rightEdge = serial.maxX + width * 0.12
            left = leftEdge
            // 流水号下面那一行是「XX票 N倍 合计N元」。认出「合计」最好；
            // 认不出就取流水号下面的第一行。
            let below = placed.filter { $0.minY > (serial.minY + serial.maxY) / 2 }
            guard let header = below.first(where: { $0.text.contains("合计") })
                    ?? below.first(where: { $0.minY >= serial.maxY - (serial.maxY - serial.minY) * 0.3 }) else { return nil }
            // 从这一行的**半腰**起算：识别框的下沿常常压到第一注号码的头上，
            // 切在半腰的话这一行剩下的半截自成一行（认不成数字），第一注是完整的。
            let middle = (header.minY + header.maxY) / 2
            top = middle
            // 「合计N元」印在最右边，和号码的右端对齐。流水号那一行常被认成两截，
            // 只按它算右边界会把七星彩的特别号、大乐透的最后一个后区号切掉。
            for line in placed where line.minY < middle && line.maxY > middle {
                rightEdge = max(rightEdge, line.maxX + (line.maxX - leftEdge) * 0.03)
            }
            right = rightEdge
            bottom = placed.first { line in
                line.minY > middle + (line.maxY - line.minY) * 0.6 && hanCount(line.text) >= 4
            }?.minY
        } else {
            for line in placed {
                if top == nil, line.text.contains("/"),
                   matches(line.text, "[0-9A-Z]{3,5}-[0-9A-Z]{3,5}-[0-9A-Z]{3,5}") {
                    top = line.maxY
                    // 从哈希行的左端起算：再往左是票纸的边，那条暗边会把所有行连成一行
                    left = line.minX - (line.maxX - line.minX) / 39 * 1.5
                    right = imageWidth
                } else if top != nil, bottom == nil, line.text.contains("开奖期") {
                    bottom = line.minY
                }
            }
        }
        guard let top, let bottom, let left, let right, bottom - top >= 8 else { return nil }
        let clampedLeft = max(left, 0), clampedRight = min(right, imageWidth)
        guard clampedRight - clampedLeft >= 40 else { return nil }
        return Bounds(top: top, bottom: bottom, left: clampedLeft, right: clampedRight)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func hanCount(_ text: String) -> Int {
        text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
    }

    /// 把 `bounds` 那一块采样成 `GlyphRows.zoneWidth` 宽的灰度图。
    ///
    /// - Parameter slope: 文字行还歪着多少（每往右一个像素，往下几个像素）。采样时跟着歪，出来的行就是平的。
    ///
    /// 原图比目标大很多时每个输出像素取一小片的平均，否则细笔画会被跳过去。
    static func sample(_ gray: [UInt8], width: Int, height: Int,
                       bounds: Bounds, slope: Double = 0) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard width > 1, height > 1, gray.count == width * height else { return nil }
        let outWidth = GlyphRows.zoneWidth
        let scale = Double(outWidth) / (bounds.right - bounds.left)
        let outHeight = max(Int((bounds.bottom - bounds.top) * scale), 8)
        guard outHeight <= 4000 else { return nil }
        let step = 1 / scale
        let taps = max(Int(step.rounded(.up)), 1)
        let centre = (bounds.left + bounds.right) / 2
        var out = [UInt8](repeating: 255, count: outWidth * outHeight)
        func pixel(_ x: Double, _ y: Double) -> Double {
            let cx = min(max(x, 0), Double(width - 1)), cy = min(max(y, 0), Double(height - 1))
            let x0 = Int(cx), y0 = Int(cy)
            let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let fx = cx - Double(x0), fy = cy - Double(y0)
            let upper = Double(gray[y0 * width + x0]) * (1 - fx) + Double(gray[y0 * width + x1]) * fx
            let lower = Double(gray[y1 * width + x0]) * (1 - fx) + Double(gray[y1 * width + x1]) * fx
            return upper * (1 - fy) + lower * fy
        }
        for y in 0..<outHeight {
            for x in 0..<outWidth {
                var sum = 0.0
                for row in 0..<taps {
                    for column in 0..<taps {
                        let sx = bounds.left + (Double(x) + (Double(column) + 0.5) / Double(taps)) * step - 0.5
                        let sy = bounds.top + (Double(y) + (Double(row) + 0.5) / Double(taps)) * step - 0.5
                        sum += pixel(sx, sy + slope * (sx - centre))
                    }
                }
                out[y * outWidth + x] = UInt8(min(max((sum / Double(taps * taps)).rounded(), 0), 255))
            }
        }
        return (out, outWidth, outHeight)
    }
}
