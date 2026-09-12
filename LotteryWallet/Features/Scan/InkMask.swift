import Foundation
import CoreGraphics

/// 票面的**墨迹图**：灰度 → 大津法 → 每个像素「有没有墨」。
///
/// 这是配准这条路的地基。识别之前先量票面，量的就是这张图上的行列投影 ——
/// `Engineering/measure.py` 里那套判据（大津法 + 行列投影 + 虚线判据）
/// 在这里原样搬成 Swift，两边量出来的数才对得上。
///
/// **工作分辨率是固定的。** 虚线判据里「高 ≤ 6 行」是个**像素数**，
/// 它只在量它的那个分辨率下成立；直接拿 4400px 的正片去套，
/// 同一条虚线会变成二十几行高，判据当场失效。所以这里一律先把图缩到
/// `workingWidth`（1000px，和量数据时那几张照片同一个量级），
/// 所有像素判据都在这个尺度上说话。缩图还顺带把热敏纸的颗粒噪声抹掉了。
struct InkMask {
    let width: Int
    let height: Int
    /// 行优先，`true` = 比阈值暗 = 有墨。
    let ink: [Bool]
    /// 每一行的墨量（有墨的像素个数）。横带切分要用。
    let rowInk: [Int]

    init(width: Int, height: Int, ink: [Bool]) {
        self.width = width
        self.height = height
        self.ink = ink
        var rows = [Int](repeating: 0, count: max(0, height))
        for y in 0..<max(0, height) {
            let base = y * width
            var count = 0
            for x in 0..<width where ink[base + x] { count += 1 }
            rows[y] = count
        }
        rowInk = rows
    }

    /// 量票面用的工作宽度。见类型说明：像素判据只在这个尺度上有意义。
    static let workingWidth = 1000

    /// 把一张图变成墨迹图。
    ///
    /// 按 `workingWidth` 等比缩放 —— 只缩不放，本来就小的图保持原样，
    /// 放大只会凭空造出插值出来的灰边，让虚线变胖。
    static func make(_ cgImage: CGImage, workingWidth: Int = InkMask.workingWidth) -> InkMask? {
        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(1, CGFloat(workingWidth) / CGFloat(sourceWidth))
        let width = max(1, Int((CGFloat(sourceWidth) * scale).rounded()))
        let height = max(1, Int((CGFloat(sourceHeight) * scale).rounded()))

        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let threshold = otsu(bytes)
        return InkMask(width: width, height: height, ink: bytes.map { $0 < threshold })
    }

    /// 大津法阈值。热敏票印在银灰纸上，固定阈值不管用。
    static func otsu(_ samples: [UInt8]) -> UInt8 {
        var histogram = [Double](repeating: 0, count: 256)
        for sample in samples { histogram[Int(sample)] += 1 }
        let total = Double(samples.count)
        guard total > 0 else { return 128 }
        var sumAll: Double = 0
        for value in 0..<256 { sumAll += Double(value) * histogram[value] }

        var weightBackground: Double = 0
        var sumBackground: Double = 0
        var best: Double = 0
        var threshold = 128
        for value in 0..<256 {
            weightBackground += histogram[value]
            if weightBackground == 0 { continue }
            let weightForeground = total - weightBackground
            if weightForeground == 0 { break }
            sumBackground += Double(value) * histogram[value]
            let difference = sumBackground / weightBackground
                - (sumAll - sumBackground) / weightForeground
            let variance = weightBackground * weightForeground * difference * difference
            if variance > best {
                best = variance
                threshold = value
            }
        }
        return UInt8(threshold)
    }

    // MARK: - 投影

    /// 按横向墨量把图切成一条条**横带**。
    ///
    /// `floor` 是墨量下限，按整幅宽度取比例 —— 和 `measure.py` 的 0.08 一致。
    func rowBands(floor: Double = 0.08) -> [ClosedRange<Int>] {
        InkMask.runs(rowInk, above: Double(width) * floor)
    }

    /// 某一条横带里，每一列有没有墨。
    func columnPresence(in rows: ClosedRange<Int>) -> [Bool] {
        var present = [Bool](repeating: false, count: width)
        let low = max(0, rows.lowerBound)
        let high = min(height - 1, rows.upperBound)
        guard low <= high else { return present }
        for y in low...high {
            let base = y * width
            for x in 0..<width where ink[base + x] { present[x] = true }
        }
        return present
    }

    /// 某一块区域里每一列的墨量。
    func columnProfile(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> [Int] {
        let left = max(0, columns.lowerBound)
        let right = min(width - 1, columns.upperBound)
        guard left <= right else { return [] }
        var profile = [Int](repeating: 0, count: right - left + 1)
        let low = max(0, rows.lowerBound)
        let high = min(height - 1, rows.upperBound)
        guard low <= high else { return profile }
        for y in low...high {
            let base = y * width
            for x in left...right where ink[base + x] { profile[x - left] += 1 }
        }
        return profile
    }

    /// 某一块区域里每一行的墨量。
    func rowProfile(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> [Int] {
        let low = max(0, rows.lowerBound)
        let high = min(height - 1, rows.upperBound)
        guard low <= high else { return [] }
        let left = max(0, columns.lowerBound)
        let right = min(width - 1, columns.upperBound)
        guard left <= right else { return [Int](repeating: 0, count: high - low + 1) }
        var profile = [Int](repeating: 0, count: high - low + 1)
        for y in low...high {
            let base = y * width
            var count = 0
            for x in left...right where ink[base + x] { count += 1 }
            profile[y - low] = count
        }
        return profile
    }

    // MARK: - 带斜率的投影

    /// 横向投影**沿着一条有斜率的方向**做。
    ///
    /// 直接按图像的行去投影，只对**水平**的虚线成立：票哪怕只歪 1°，
    /// 一条横跨 1000px 的虚线就会摊到二十来行上 ——「高 ≤ 6 行」当场判不出来，
    /// 而这条线在票面上明明又细又直。预处理只把文字基线拉到 0.35° 以内，
    /// 剩下的那点歪正好落在会出事的量级上。
    ///
    /// 所以投影的方向也跟着斜：第 `bin` 格收的是 `y - slope * (x - 中线)`
    /// 落在这一格里的墨。`slope == 0` 时它和按行投影**完全等价** ——
    /// 实测那三张票的判据因此原样成立，一个数都没动。
    func binProfile(slope: Double) -> [Int] {
        let extra = binOffset(slope)
        let center = Double(width) / 2
        var profile = [Int](repeating: 0, count: height + extra * 2)
        for y in 0..<height {
            let base = y * width
            for x in 0..<width where ink[base + x] {
                let bin = Int((Double(y) - slope * (Double(x) - center)).rounded()) + extra
                if bin >= 0, bin < profile.count { profile[bin] += 1 }
            }
        }
        return profile
    }

    /// 斜投影的格号要往上让出多少 —— 斜着的那一端会探到图外面去。
    func binOffset(_ slope: Double) -> Int {
        Int((abs(slope) * Double(width) / 2).rounded(.up)) + 1
    }

    /// 斜投影里某一格在某一列上对应的行区间。
    func rows(bins: ClosedRange<Int>, slope: Double, at x: Int) -> ClosedRange<Int> {
        let extra = binOffset(slope)
        let shift = slope * (Double(x) - Double(width) / 2)
        let low = Int((Double(bins.lowerBound - extra) + shift).rounded(.down))
        let high = Int((Double(bins.upperBound - extra) + shift).rounded(.up))
        return low...Swift.max(low, high)
    }

    /// 斜投影里某一格带上，每一列有没有墨。
    func columnPresence(bins: ClosedRange<Int>, slope: Double) -> [Bool] {
        var present = [Bool](repeating: false, count: width)
        for x in 0..<width {
            let span = rows(bins: bins, slope: slope, at: x)
            var y = Swift.max(0, span.lowerBound)
            let end = Swift.min(height - 1, span.upperBound)
            while y <= end {
                if ink[y * width + x] {
                    present[x] = true
                    break
                }
                y += 1
            }
        }
        return present
    }

    /// 一条剖面里连续「超过下限」的那些段。
    static func runs(_ profile: [Int], above floor: Double) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var start: Int?
        for (index, value) in profile.enumerated() {
            let on = Double(value) > floor
            if on, start == nil { start = index }
            if !on, let began = start {
                out.append(began...(index - 1))
                start = nil
            }
        }
        if let began = start, !profile.isEmpty {
            out.append(began...(profile.count - 1))
        }
        return out
    }

    /// 一排 `true/false` 里连续为 `true` 的那些段。
    static func runs(_ flags: [Bool]) -> [ClosedRange<Int>] {
        runs(flags.map { $0 ? 1 : 0 }, above: 0)
    }
}
