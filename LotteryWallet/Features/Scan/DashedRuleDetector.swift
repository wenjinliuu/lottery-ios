import Foundation
import CoreGraphics

/// 票面上印的一条**长虚线**。
///
/// 体彩数字型（七星彩、排列5、排列3）的号码区被上下两条长虚线夹住。
/// 这两条线是**票面自己印上去的**，位置、角度都跟用户怎么裁、怎么拍无关 ——
/// 这正是配准需要的锚点。用户的裁切框做不到：它本身就是歪的、松的。
struct DashedRule: Equatable {
    /// 斜投影里占的格区间（见 `InkMask.binProfile`）。`slope == 0` 时就是行区间。
    let bins: ClosedRange<Int>
    /// 找到它时用的投影斜率。
    let projectionSlope: Double
    /// 横跨的列区间（工作图像素）。
    let columns: ClosedRange<Int>
    /// 每一小段实线的列区间。画调试图时逐段画出来，一眼能看出是不是真抓到了虚线。
    let segments: [ClosedRange<Int>]
    /// 按各段中心拟合出来的直线：`y = slope * x + intercept`（工作图像素）。
    ///
    /// 拟合而不是直接取横带中线，是因为**斜率就是票面的倾角**。
    /// 预处理只保证四个角摆正，票本身印歪一两度时字还是斜的；
    /// 这条线量的是票面上真实的水平方向，配准要的就是它。
    let slope: Double
    let intercept: Double

    /// 这条线在斜投影里有多"厚"。判据里的「高 ≤ 6 行」量的就是它。
    var thickness: Int { bins.upperBound - bins.lowerBound + 1 }

    func y(at x: Double) -> Double { slope * x + intercept }

    /// 这条线大致在图上的哪个高度。上下两条线排序用。
    var midY: Double { y(at: Double(columns.lowerBound + columns.upperBound) / 2) }
}

/// 找票面上那两条长虚线。
///
/// 判据全部来自 `Engineering/vision-rebuild.md` 的实测表 ——
/// 三张真票（七星彩 24 条候选横带、排列5 18 条、排列3 9 条）里
/// **各只命中 2 条，零误报**。不要凭感觉改这些数：
///
/// ```
/// 高 ≤ 6 行            虚线是印刷线，比任何一行字都薄
/// 横跨 > 80% 宽度      它横穿整张票，任何一行文字都做不到
/// 段数 ≥ 12            "虚"的定义：断成很多截
/// 最长段 ≤ 5% 宽度     有一截特别长就不是虚线，是表格框线或者条码
/// 占空比 0.25–0.75     一半有墨一半没有；实线接近 1，稀疏噪点接近 0
/// ```
///
/// 唯一加的东西是**换个方向投影**：判据原样照搬，但允许沿票面自己的倾角去量，
/// 见 `InkMask.binProfile`。票摆得正时（`slope == 0`）两者完全等价。
enum DashedRuleDetector {

    /// 判据。默认值是实测值，**只有在重新量过票之后才允许改**。
    struct Criteria {
        var maximumThickness = 6
        var minimumExtent = 0.80
        var minimumSegments = 12
        var maximumSegmentWidth = 0.05
        var minimumFill = 0.25
        var maximumFill = 0.75

        static let measured = Criteria()
    }

    /// 试哪些倾角。
    ///
    /// 0.005 ≈ 0.29°，一路试到 ±2°。预处理会把文字基线拉到 0.35° 以内，
    /// 但它需要至少三块文字才肯动手 —— 拉不动的时候剩下的那点歪，
    /// 正好落在"一条 1000px 的线摊到十几行上"的量级。
    /// 从正着开始、按倾角从小到大试，先拿到两条就收工。
    static let slopes: [Double] = {
        var values: [Double] = [0]
        for step in 1...7 {
            let slope = Double(step) * 0.005
            values.append(slope)
            values.append(-slope)
        }
        return values
    }()

    /// 图里所有符合判据的虚线，从上到下。
    ///
    /// 按倾角从小到大扫，**第一个正好扫出两条的倾角说了算**。
    /// 一条都没凑够两条时退回摆正那一遍的结果 —— 调试图上照样画出来，
    /// 用户一看就知道是"一条也没找到"还是"找到三条不敢挑"。
    static func rules(in mask: InkMask, criteria: Criteria = .measured) -> [DashedRule] {
        var fallback: [DashedRule] = []
        for (index, slope) in slopes.enumerated() {
            let found = rules(in: mask, slope: slope, criteria: criteria)
            if found.count == 2 { return found }
            if index == 0 { fallback = found }
        }
        return fallback
    }

    /// 沿某一个倾角量一遍。
    static func rules(in mask: InkMask, slope: Double, criteria: Criteria) -> [DashedRule] {
        guard mask.width > 0, mask.height > 0 else { return [] }
        let width = Double(mask.width)
        var found: [DashedRule] = []

        let profile = mask.binProfile(slope: slope)
        for band in InkMask.runs(profile, above: width * 0.08) {
            let thickness = band.upperBound - band.lowerBound + 1
            guard thickness <= criteria.maximumThickness else { continue }

            let present = mask.columnPresence(bins: band, slope: slope)
            let segments = InkMask.runs(present)
            guard let first = segments.first, let last = segments.last else { continue }

            let extent = Double(last.upperBound - first.lowerBound + 1) / width
            guard extent > criteria.minimumExtent else { continue }
            guard segments.count >= criteria.minimumSegments else { continue }

            let longest = segments.map { $0.upperBound - $0.lowerBound + 1 }.max() ?? 0
            guard Double(longest) <= width * criteria.maximumSegmentWidth else { continue }

            let inked = segments.reduce(0) { $0 + ($1.upperBound - $1.lowerBound + 1) }
            let fill = Double(inked) / Double(last.upperBound - first.lowerBound + 1)
            guard fill > criteria.minimumFill, fill < criteria.maximumFill else { continue }

            let line = fit(segments: segments, bins: band, slope: slope, mask: mask)
            found.append(DashedRule(bins: band,
                                    projectionSlope: slope,
                                    columns: first.lowerBound...last.upperBound,
                                    segments: segments,
                                    slope: line.slope,
                                    intercept: line.intercept))
        }
        return found.sorted { $0.midY < $1.midY }
    }

    /// 按各段的**墨迹重心**拟合一条直线。
    ///
    /// 取重心而不是带的中线：带是整条线的包络，一端稍微高一点就会把整条带撑宽，
    /// 中线反而看不出倾角。逐段取重心之后，最小二乘拟出来的斜率
    /// 就是票面真实的倾角 —— 比扫倾角时用的那个粗粒度的值准得多。
    ///
    /// 拟完再剔一遍离群段：虚线总有一两截会和旁边的字连上，
    /// 那一截的重心会被拽偏，不剔掉的话整条线跟着歪。
    static func fit(segments: [ClosedRange<Int>],
                    bins: ClosedRange<Int>,
                    slope: Double,
                    mask: InkMask) -> (slope: Double, intercept: Double) {
        var points: [(x: Double, y: Double)] = []
        var all: [Double] = []
        for segment in segments {
            var weight = 0.0
            var sum = 0.0
            for x in segment.lowerBound...segment.upperBound where x >= 0 && x < mask.width {
                let span = mask.rows(bins: bins, slope: slope, at: x)
                let low = Swift.max(0, span.lowerBound)
                let high = Swift.min(mask.height - 1, span.upperBound)
                guard low <= high else { continue }
                for y in low...high where mask.ink[y * mask.width + x] {
                    weight += 1
                    sum += Double(y)
                }
            }
            guard weight > 0 else { continue }
            let center = Double(segment.lowerBound + segment.upperBound) / 2
            points.append((x: center, y: sum / weight))
            all.append(sum / weight)
        }
        let fallback = all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count)
        guard points.count >= 2 else { return (0, fallback) }

        var line = leastSquares(points) ?? (0, fallback)
        let residuals = points.map { abs($0.y - (line.slope * $0.x + line.intercept)) }
        let median = residuals.sorted()[residuals.count / 2]
        // 中位残差是 0（所有点都在一条线上）时不用剔，剔了反而只剩几个点
        if median > 0 {
            let kept = zip(points, residuals).filter { $1 <= median * 2.5 }.map { $0.0 }
            if kept.count >= 2, let refit = leastSquares(kept) { line = refit }
        }
        return line
    }

    private static func leastSquares(_ points: [(x: Double, y: Double)]) -> (slope: Double, intercept: Double)? {
        let count = Double(points.count)
        guard count >= 2 else { return nil }
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count
        var covariance = 0.0
        var variance = 0.0
        for point in points {
            covariance += (point.x - meanX) * (point.y - meanY)
            variance += (point.x - meanX) * (point.x - meanX)
        }
        guard variance > 0 else { return nil }
        let slope = covariance / variance
        return (slope, meanY - slope * meanX)
    }
}
