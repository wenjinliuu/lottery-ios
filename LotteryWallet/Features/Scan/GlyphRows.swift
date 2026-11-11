import Foundation

/// 号码区 → 一行一行的数字。**自己训练的模型读整行号码**用的就是这一份。
///
/// 做法是纯几何的，不靠文字识别：
///
/// 1. 号码区拉正成 1000 像素宽，取红色通道（福彩的粉色底纹在红色通道里是白的）。
/// 2. 比周围暗的像素算墨（局部阈值：整张票一边亮一边暗，全局阈值会把暗的那半边整片当成墨）。
/// 3. 按行投影切出每一行，行内按列投影切出每一段。
/// 4. 留下「长得像数字」的段，一段一段交给 `DigitClassifier`。
/// 5. 一行里找**唯一**一串连着的、个数正好的数字（`readLine`）。
///
/// **和 `lottery-ocr` 仓库的 `tools/row_reader.py`、`tools/eval_rows.py` 逐步一致**，
/// `GlyphRowsTests` 拿那边导出的样例对拍。改一边必须改另一边。
///
/// 三批真票（56 张票）上量出来的结果记在 `Engineering/model-rows.md`。
enum GlyphRows {
    static let zoneWidth = 1000
    static let window = 41
    static let offset = 18

    struct Segment: Equatable {
        var x0: Int, x1: Int, y0: Int, y1: Int
    }

    struct Row: Equatable {
        var top: Int
        var bottom: Int
        var segments: [Segment]
    }

    /// 一段 + 模型说它是什么。
    struct Token: Equatable {
        var digit: Int
        var confidence: Float
        var segment: Segment
    }

    // MARK: - 墨迹

    /// 3×3 模糊，核是 1-2-1。边上按取得到的那几个算，整数除法。
    static func blur3(_ gray: [UInt8], width: Int, height: Int) -> [Int32] {
        var out = [Int32](repeating: 0, count: width * height)
        let weights: [Int32] = [1, 2, 1]
        for y in 0..<height {
            for x in 0..<width {
                var sum: Int32 = 0, total: Int32 = 0
                for dy in -1...1 where y + dy >= 0 && y + dy < height {
                    for dx in -1...1 where x + dx >= 0 && x + dx < width {
                        let weight = weights[dy + 1] * weights[dx + 1]
                        sum += Int32(gray[(y + dy) * width + x + dx]) * weight
                        total += weight
                    }
                }
                out[y * width + x] = sum / total
            }
        }
        return out
    }

    /// 比周围 41×41 的平均暗 18 以上的像素。窗口出界的部分不算。
    static func inkMask(_ gray: [UInt8], width: Int, height: Int) -> [Bool] {
        let blurred = blur3(gray, width: width, height: height)
        // 积分图，多一行一列的 0
        var integral = [Int64](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var run: Int64 = 0
            for x in 0..<width {
                run += Int64(blurred[y * width + x])
                integral[(y + 1) * (width + 1) + x + 1] = integral[y * (width + 1) + x + 1] + run
            }
        }
        let radius = window / 2
        var ink = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let y0 = max(y - radius, 0), y1 = min(y + radius + 1, height)
            for x in 0..<width {
                let x0 = max(x - radius, 0), x1 = min(x + radius + 1, width)
                let total = integral[y1 * (width + 1) + x1] - integral[y0 * (width + 1) + x1]
                    - integral[y1 * (width + 1) + x0] + integral[y0 * (width + 1) + x0]
                let area = Int64((y1 - y0) * (x1 - x0))
                ink[y * width + x] = Int64(blurred[y * width + x]) * area < total - Int64(offset) * area
            }
        }
        return ink
    }

    /// 投影里连续超过 `floor` 的区间，左闭右开。
    static func bands(_ profile: [Int], floor: Int) -> [(Int, Int)] {
        var runs: [(Int, Int)] = []
        var start: Int?
        for (index, value) in profile.enumerated() {
            if value > floor {
                if start == nil { start = index }
            } else if let begun = start {
                runs.append((begun, index))
                start = nil
            }
        }
        if let begun = start { runs.append((begun, profile.count)) }
        return runs
    }

    // MARK: - 行和段

    /// - Parameter rowColumns: 找行的时候只看左边这么大比例的列。福彩行尾的「(1)」
    ///   括号比数字高，上下两行的括号几乎挨着，算进去的话几行会连成一行。
    static func rows(_ gray: [UInt8], width: Int, height: Int, rowColumns: Double = 1) -> [Row] {
        guard width > 0, height > 0, gray.count == width * height else { return [] }
        let ink = inkMask(gray, width: width, height: height)
        let limit = Int(Double(width) * rowColumns)
        var profile = [Int](repeating: 0, count: height)
        for y in 0..<height {
            var count = 0
            for x in 0..<limit where ink[y * width + x] { count += 1 }
            profile[y] = count
        }
        let rough = bands(profile, floor: width * 6 / 1000)
        guard !rough.isEmpty else { return [] }
        let heights = rough.map { $0.1 - $0.0 }.sorted()
        let tall = heights[heights.count / 2]
        let found = splitTall(rough, profile: profile, tall: tall)
        var out: [Row] = []
        for (top, bottom) in found {
            let rowHeight = bottom - top
            guard rowHeight * 100 >= tall * 55 else { continue }        // 虚线、噪点
            var columns = [Int](repeating: 0, count: width)
            for y in top..<bottom {
                for x in 0..<width where ink[y * width + x] { columns[x] += 1 }
            }
            var segments: [Segment] = []
            for (x0, x1) in bands(columns, floor: 0) {
                var first = -1, last = -1
                for y in top..<bottom {
                    var any = false
                    for x in x0..<x1 where ink[y * width + x] { any = true; break }
                    guard any else { continue }
                    if first < 0 { first = y }
                    last = y
                }
                guard first >= 0 else { continue }
                let segmentHeight = last + 1 - first, segmentWidth = x1 - x0
                // 长得像数字：差不多和这一行一样高，不太宽也不太窄。
                // 冒号、小数点、加号、减号太矮；圈码和汉字太宽。
                guard segmentHeight * 100 >= rowHeight * 72,
                      rowHeight * 16 <= segmentWidth * 100,
                      segmentWidth * 100 <= rowHeight * 90 else { continue }
                segments.append(Segment(x0: x0, x1: x1, y0: first, y1: last + 1))
            }
            out.append(Row(top: top, bottom: bottom, segments: segments))
        }
        return out
    }

    /// 比一般的行高出将近一半的行，多半是两行粘在了一起（表头的下半截贴着第一注 ——
    /// 真机上一张套餐票就这样少了第一注）。
    ///
    /// 在它中间那一半里找墨最少的一条线，那条线上的墨不到这一行最浓处的 35% 就从那儿切开。
    /// 每一行最多切一刀。
    static func splitTall(_ rows: [(Int, Int)], profile: [Int], tall: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for (top, bottom) in rows {
            let height = bottom - top
            guard height * 100 > tall * 145, height >= 8 else {
                out.append((top, bottom))
                continue
            }
            let low = top + height / 4, high = bottom - height / 4
            var cut = low
            for y in low..<high where profile[y] < profile[cut] { cut = y }
            let peak = profile[top..<bottom].max() ?? 0
            if profile[cut] * 100 <= peak * 35 {
                out.append((top, cut))
                out.append((cut + 1, bottom))
            } else {
                out.append((top, bottom))
            }
        }
        return out
    }

    /// 一段四周各让 3 个像素裁出来，交给模型。
    static func crop(_ gray: [UInt8], width: Int, height: Int,
                     segment: Segment) -> (pixels: [UInt8], width: Int, height: Int) {
        let x0 = max(segment.x0 - 3, 0), x1 = min(segment.x1 + 3, width)
        let y0 = max(segment.y0 - 3, 0), y1 = min(segment.y1 + 3, height)
        var pixels = [UInt8](repeating: 0, count: (x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 { pixels[(y - y0) * (x1 - x0) + x - x0] = gray[y * width + x] }
        }
        return (pixels, x1 - x0, y1 - y0)
    }

    /// 号码区里每一行的每一段，都让模型认一遍。
    static func read(_ gray: [UInt8], width: Int, height: Int, rowColumns: Double = 1,
                     classifier: DigitClassifier) -> [[Token]] {
        rows(gray, width: width, height: height, rowColumns: rowColumns).map { row in
            row.segments.map { segment in
                let piece = crop(gray, width: width, height: height, segment: segment)
                let verdict = classifier.classify(pixels: piece.pixels, width: piece.width, height: piece.height)
                return Token(digit: verdict.digit, confidence: verdict.confidence, segment: segment)
            }
        }
    }

    // MARK: - 一行里的那一串号码

    /// 一行里找**唯一**一串连着的 `count` 个数字。找不到、或者找到不止一串，都是 nil。
    ///
    /// 窗口里不许有「不是数字」的段。窗口两头紧挨着的也不能是数字 ——
    /// 除非隔得比窗口里最大的空隙还远一半（福彩行尾的「(1)」就是这样隔开的）。
    /// 这样一来多读一位、少读一位都对不上，整行作废，不会错开一位去凑。
    static func readLine(_ tokens: [Token], count: Int) -> [Token]? {
        guard count > 0, tokens.count >= count else { return nil }
        func gap(_ left: Int, _ right: Int) -> Int { tokens[right].segment.x0 - tokens[left].segment.x1 }
        // 紧挨着的那一段「是数字」而且模型有七成半以上的把握，才算号码还没完。
        // 冒号、点常被认成没把握的 1，它们不算（「蓝复:02 11」前面那个冒号）。
        func digit(_ index: Int) -> Bool {
            tokens[index].digit != DigitClassifier.reject && tokens[index].confidence >= 0.75
        }
        var hits: [[Token]] = []
        for start in 0...(tokens.count - count) {
            let window = Array(tokens[start..<start + count])
            guard !window.contains(where: { $0.digit == DigitClassifier.reject }) else { continue }
            var widest = 1
            if count > 1 {
                for index in start..<(start + count - 1) { widest = max(widest, gap(index, index + 1)) }
            }
            if start > 0, digit(start - 1), gap(start - 1, start) * 2 <= widest * 3 { continue }
            let end = start + count
            if end < tokens.count, digit(end), gap(end - 1, end) * 2 <= widest * 3 { continue }
            hits.append(window)
        }
        return hits.count == 1 ? hits[0] : nil
    }
}
