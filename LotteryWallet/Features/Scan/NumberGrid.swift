import Foundation
import CoreGraphics

/// 配准后的号码区里的**网格**。
///
/// 这是阶段 2 的核心，也是整条流水线一直缺的那一环。
///
/// 以前的做法是「从识别结果里估几何」：先让 Vision 认出一堆字符，再按字符
/// 坐标去估列距行距。这就是所有错位的根 —— 认得越差，估得越偏；估得越偏，
/// 认得越差。七星彩的特别号丢十位、排列5 把票底流水号读成一注，都是这么来的。
///
/// 现在反过来：**先有格子，再去认**。格子是在配准后的标准矩形里划的，
/// 位置来自票面自己印的墨迹（行投影 × 列投影），和识别结果无关。
/// 划好之后每一格单独裁出来认，认不出就是问号 —— 这一格在票面上的位置
/// 始终说得清楚，硬约束一就是这么落地的。
///
/// 坐标一律是**标准矩形里的 0–1**（配准之后，左上原点）。
struct NumberGrid: Equatable {
    /// 每一注占的纵向区间。
    let rows: [ClosedRange<CGFloat>]
    /// 每一位占的横向区间。
    let columns: [ClosedRange<CGFloat>]

    /// 第 `row` 注第 `column` 位那一格。
    func cell(row: Int, column: Int) -> CGRect? {
        guard rows.indices.contains(row), columns.indices.contains(column) else { return nil }
        let x = columns[column]
        let y = rows[row]
        return CGRect(x: x.lowerBound, y: y.lowerBound,
                      width: x.upperBound - x.lowerBound,
                      height: y.upperBound - y.lowerBound)
    }

    // MARK: - 划格子

    /// 一条候选行：它的纵向区间，和它横向被切成的那几段墨。
    struct Candidate: Equatable {
        var band: ClosedRange<Int>
        var segments: [ClosedRange<Int>]

        var centers: [Double] {
            segments.map { Double($0.lowerBound + $0.upperBound) / 2 }
        }
    }

    /// 把配准后的号码区切成一条条候选行。
    ///
    /// 行的墨量下限取号码区宽度的 5% —— 和 `measure.py` 量行距时用的是同一个数。
    static func candidates(in mask: InkMask,
                           within span: ClosedRange<Int>,
                           columns: Int) -> [Candidate] {
        guard mask.height > 0, span.lowerBound <= span.upperBound else { return [] }
        let width = Double(span.upperBound - span.lowerBound + 1)
        let profile = mask.rowProfile(rows: 0...(mask.height - 1), columns: span)
        var found: [Candidate] = []
        for band in InkMask.runs(profile, above: width * 0.05) {
            // 一两个像素高的是噪点，不是一行字
            guard band.upperBound - band.lowerBound + 1 >= 3 else { continue }
            let runs = InkMask.runs(mask.columnProfile(rows: band, columns: span), above: 0)
            let segments = runs.map {
                (span.lowerBound + $0.lowerBound)...(span.lowerBound + $0.upperBound)
            }
            // 段数不对的直接不要：虚线一行几十段，中文那行三五段
            guard segments.count <= columns,
                  segments.count >= Swift.max(1, columns - 2) else { continue }
            found.append(Candidate(band: band, segments: segments))
        }
        return found
    }

    /// 从候选行里挑出**真正的投注行**。
    ///
    /// 判据是「互相对得齐」：一张票上的几注是印成矩阵的，每一位都在同一列上。
    /// 而「单式票 / 1倍 / 合计10元」那一行、「感谢您为公益事业贡献」那一行，
    /// 段数可能凑巧落在范围里，但它们的段**落不到同一列上**。
    ///
    /// 取对得齐的最大的那一组。只有一行时要求段数正好齐 ——
    /// 一张票只有一注是常见的（排列3/5 经常打一注），不能因此判掉。
    static func betRows(_ candidates: [Candidate], columns: Int) -> [Candidate] {
        guard !candidates.isEmpty else { return [] }
        var best: [Candidate] = []
        for seed in candidates {
            let group = candidates.filter { aligned($0, seed) }
            if group.count > best.count { best = group }
        }
        if best.count >= 2 { return best.sorted { $0.band.lowerBound < $1.band.lowerBound } }
        // 只剩一行的话，它必须是完整的一注
        return candidates.filter { $0.segments.count == columns }
    }

    /// 两行的段**是不是落在同一批列上**。
    ///
    /// 容差取这一行自己的中位段宽 —— 票面上的字有多宽，容差就有多宽。
    /// 用固定比例的话，字小的票太松、字大的票太紧。
    static func aligned(_ a: Candidate, _ b: Candidate) -> Bool {
        guard a.segments.count == b.segments.count, !a.segments.isEmpty else { return false }
        let widths = (a.segments + b.segments).map { Double($0.upperBound - $0.lowerBound + 1) }
        let tolerance = Swift.max(median(widths), 2)
        return zip(a.centers, b.centers).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// 把对齐的那几行合成列位：每一列取各行的中位数。
    ///
    /// 取中位数而不是并集：某一行的某一位印得糊、粘上了旁边的笔画时，
    /// 并集会被它拽宽，中位数不会。
    static func columnRanges(_ rows: [Candidate]) -> [ClosedRange<Int>]? {
        guard let count = rows.first?.segments.count, count > 0,
              rows.allSatisfy({ $0.segments.count == count }) else { return nil }
        var ranges: [ClosedRange<Int>] = []
        for index in 0..<count {
            let lows = rows.map { Double($0.segments[index].lowerBound) }
            let highs = rows.map { Double($0.segments[index].upperBound) }
            let low = Int(median(lows).rounded())
            let high = Int(median(highs).rounded())
            guard high >= low else { return nil }
            ranges.append(low...high)
        }
        return ranges
    }

    /// 缺的那一列按版式**算**出来，不去找。
    ///
    /// 七星彩的特别号印得比别的号码远（实测 1.58 个列距），而且整列可能
    /// 一个墨点都没切出来（印得淡、或者被裁掉一点）。已知前面几列的位置和列距，
    /// 这一列的位置是算得出来的 —— 这正是 `DigitTicketLayout` 那张比值表的用处。
    static func appendingTrailing(_ ranges: [ClosedRange<Int>],
                                  layout: DigitTicketLayout,
                                  limit: Int) -> [ClosedRange<Int>]? {
        guard ranges.count == layout.columns - 1, let last = ranges.last else { return nil }
        let centers = ranges.map { Double($0.lowerBound + $0.upperBound) / 2 }
        guard centers.count >= 2 else { return nil }
        let pitch = median(zip(centers, centers.dropFirst()).map { $1 - $0 })
        guard pitch > 0 else { return nil }
        let width = Double(last.upperBound - last.lowerBound + 1)
        let center = Double(last.lowerBound + last.upperBound) / 2 + Double(layout.trailingPitch) * pitch
        let low = Int((center - width / 2).rounded())
        let high = Int((center + width / 2).rounded())
        // 算到号码区外面去了就是算错了
        guard low >= 0, high <= limit, high > low else { return nil }
        return ranges + [low...high]
    }

    /// 这一行的每一段是不是都**落在某一列里**，而且没有两段挤进同一列。
    ///
    /// 列位定下来之后拿它去收行：缺了一位的那一注段数少一段，但剩下的段
    /// 依然一段一列对得上 —— 这样的行要留下来，那一格标问号。
    /// 整行丢掉的话，用户手里五注的票在票夹里变成四注，而且**看不出少在哪儿**。
    static func fits(_ candidate: Candidate, _ ranges: [ClosedRange<Int>]) -> Bool {
        guard !candidate.segments.isEmpty, !ranges.isEmpty else { return false }
        let widths = ranges.map { Double($0.upperBound - $0.lowerBound + 1) }
        let tolerance = Swift.max(median(widths) * 0.6, 2)
        var used = Set<Int>()
        for center in candidate.centers {
            guard let index = ranges.firstIndex(where: {
                Double($0.lowerBound) - tolerance <= center
                    && center <= Double($0.upperBound) + tolerance
            }) else { return false }
            guard used.insert(index).inserted else { return false }
        }
        return true
    }

    /// 划格子。`span` 是号码区在配准图里的横向范围（左边界到右边界）。
    static func build(mask: InkMask,
                      within span: ClosedRange<Int>,
                      layout: DigitTicketLayout) -> NumberGrid? {
        guard mask.width > 0, mask.height > 0 else { return nil }
        let all = candidates(in: mask, within: span, columns: layout.columns)
        // 先用"互相对得齐"的那几行把列位定下来
        let consensus = betRows(all, columns: layout.columns)
        guard !consensus.isEmpty else { return nil }
        guard var ranges = columnRanges(consensus) else { return nil }
        if ranges.count == layout.columns - 1 {
            guard let filled = appendingTrailing(ranges, layout: layout,
                                                 limit: mask.width - 1) else { return nil }
            ranges = filled
        }
        // 列数凑不齐就**整个作废**。少认一注用户看得见，摆错位用户看不见。
        guard ranges.count == layout.columns else { return nil }

        // 再拿定好的列位去收行 —— 缺一位的那一注也收进来，那一格标问号
        let rows = all.filter { fits($0, ranges) }
            .sorted { $0.band.lowerBound < $1.band.lowerBound }
        guard !rows.isEmpty else { return nil }

        let width = CGFloat(mask.width)
        let height = CGFloat(mask.height)
        return NumberGrid(
            rows: rows.map {
                CGFloat($0.band.lowerBound) / height...CGFloat($0.band.upperBound + 1) / height
            },
            columns: ranges.map {
                CGFloat($0.lowerBound) / width...CGFloat($0.upperBound + 1) / width
            })
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }
}
