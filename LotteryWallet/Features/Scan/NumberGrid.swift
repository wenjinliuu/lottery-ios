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

    /// 挨得很近的两段合成一段 —— 那是**同一个号码的两位数字**。
    ///
    /// 实测（七星彩）：号码之间空 55px，而 `13` 里的 `1` 和 `3` 只空 14px，
    /// 字宽 21px。所以判据是「间隙小于一个字宽就是同一个号码」。
    ///
    /// 不合的话，两位数的特别号会占掉两段，整行段数多出一段、
    /// 和别的行对不齐，那一注就被判掉了。
    static func merging(_ segments: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        guard segments.count > 1 else { return segments }
        let widths = segments.map { Double($0.upperBound - $0.lowerBound + 1) }
        let glyph = Swift.max(median(widths), 2)
        var out: [ClosedRange<Int>] = [segments[0]]
        for segment in segments.dropFirst() {
            let previous = out[out.count - 1]
            if Double(segment.lowerBound - previous.upperBound) <= glyph {
                out[out.count - 1] = previous.lowerBound...segment.upperBound
            } else {
                out.append(segment)
            }
        }
        return out
    }

    /// 把配准后的号码区切成一条条候选行。
    ///
    /// 行的墨量下限取号码区宽度的 5% —— 和 `measure.py` 量行距时用的是同一个数。
    ///
    /// 段数允许**比号码位数多两列**：票面上号码左边常常还杵着注序号
    /// （`①②③` / `组六:`），右边还杵着倍数 `(N)`。它们该不该算，
    /// 由 `trimming` 按实测的列距关系去判，不在这里瞎猜。
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
            let segments = merging(runs.map {
                (span.lowerBound + $0.lowerBound)...(span.lowerBound + $0.upperBound)
            })
            // 段数离谱的直接不要：虚线一行几十段，中文那行两三段
            guard segments.count <= columns + 2,
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

    /// 号码区两边多出来的那些列，裁掉。
    ///
    /// 票面上号码左右常常还杵着两样东西，它们都会被切成一列：
    ///
    /// - **左边：注序号 / 玩法标签**（`①②③`、`组六:`）。实测它和第一位号码的
    ///   列距和号码之间的列距几乎一样（62.5 对 65），**几何上分不开** ——
    ///   所以靠内容判：这一列里一个数字字符都没有。`①` 是带圈的，
    ///   Vision 认得出但 `plainDigitValue` 不认它当数字，正好用上。
    /// - **右边：倍数 `(N)`**。它离号码远得多 —— 实测福彩 3D 是 **2.7 个列距**，
    ///   而七星彩的特别号（离得最远的一个号码）也才 **1.58 个列距**。
    ///   这两个数中间有很大余量，拿 1.8 当界一刀切下去两边都安全。
    ///
    /// 裁不动就返回 nil，整个矩阵作废 —— 硬约束二。
    /// 返回**保留下来的那段下标**。只从两头裁，所以留下的一定是连续的一段 ——
    /// 拿着这段下标，后面还能回到原来那几行里去取并集。
    static func trimming(_ ranges: [ClosedRange<Int>],
                         columns: Int,
                         digitCenters: [Double]) -> ClosedRange<Int>? {
        guard ranges.count >= columns, columns > 0 else { return nil }
        var first = 0
        var last = ranges.count - 1
        while last - first + 1 > columns {
            let kept = Array(ranges[first...last])
            let centers = kept.map { Double($0.lowerBound + $0.upperBound) / 2 }
            let gaps = zip(centers, centers.dropFirst()).map { $1 - $0 }
            guard let lastGap = gaps.last, gaps.count >= 2,
                  let typical = gaps.dropLast().min() else { return nil }
            // 拿**最小**的那个列距当基准，不拿中位数。
            //
            // 中位数在只剩两个间隙时会取到较大的那个，判据一下子松掉一半：
            // 实测福彩 3D 的 `(1)` 离号码 132.5px、号码之间 39.5px，
            // 按中位数算阈值是 129.6 —— 只剩 2% 余量，票面稍微变一点就翻过去。
            // 按最小值算阈值是 71.1，余量大得多，而且七星彩那边
            // （特别号 103px、最小列距 62.5px、阈值 112.5）照样不会误伤。
            if typical > 0, lastGap > typical * 1.8 {
                last -= 1
                continue
            }
            // 最左边那一列里一个数字都没有 —— 那是注序号 / 玩法标签
            let head = ranges[first]
            let hasDigit = digitCenters.contains {
                Double(head.lowerBound) <= $0 && $0 <= Double(head.upperBound)
            }
            guard !hasDigit else { return nil }
            first += 1
        }
        return first...last
    }

    /// 某一列取**并集**，不取中位数。
    ///
    /// 七星彩的特别号那一列是**右对齐**的：`13` 的十位往左探出去，
    /// 而 `4` `9` `2` 不探。五行里三行是一位数，中位数就落在个位那一段上 ——
    /// 十位的 `1` 落在列外面，直接被丢掉，`13` 就读成了 `3`。
    /// 这一列只能取并集：只要有一行印了两位，这一列就得容得下两位。
    static func unionRange(_ rows: [Candidate], at index: Int) -> ClosedRange<Int>? {
        let picked = rows.compactMap { $0.segments.indices.contains(index) ? $0.segments[index] : nil }
        guard let low = picked.map(\.lowerBound).min(),
              let high = picked.map(\.upperBound).max(), high >= low else { return nil }
        return low...high
    }

    /// 末列再往左让出一个字宽 —— **哪怕墨迹里根本没切出十位来**。
    ///
    /// 并集只在"十位那一笔进了墨迹图"时才管用。`13` 的十位是一竖，
    /// 又细又淡，配准+缩放之后很可能整笔掉出二值化；而 Vision 在原图上
    /// 照样认得出它。这时候并集没变宽，Vision 认出来的 `1` 落在列外面，
    /// 又被丢了 —— 和修之前一模一样。
    ///
    /// 所以这一列的宽度不能只靠墨迹说了算，按版式硬让出一个字宽：
    /// 特别号离前一位 1.58 个列距（实测 103px，字宽 21px），
    /// 中间空着 80 多像素，让出 25px 碰不到邻居。
    static func wideningTail(_ range: ClosedRange<Int>, by width: Double) -> ClosedRange<Int> {
        let low = Swift.max(0, range.lowerBound - Int((width * 1.2).rounded()))
        return low...range.upperBound
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
        guard !candidate.segments.isEmpty,
              let leftmost = ranges.first, let rightmost = ranges.last else { return false }
        let widths = ranges.map { Double($0.upperBound - $0.lowerBound + 1) }
        let tolerance = Swift.max(median(widths) * 0.6, 2)
        var used = Set<Int>()
        var landed = 0
        for center in candidate.centers {
            if let index = ranges.firstIndex(where: {
                Double($0.lowerBound) - tolerance <= center
                    && center <= Double($0.upperBound) + tolerance
            }) {
                // 两段挤进同一列 = 这一行的排版和号码矩阵对不上
                guard used.insert(index).inserted else { return false }
                landed += 1
                continue
            }
            // 落在号码区**外面**的那些段是注序号和倍数 `(N)` —— 它们本来就不算号码。
            // 但落在号码区**里面**却不在任何一列上的，说明这行根本不是投注行。
            let outside = center < Double(leftmost.lowerBound) - tolerance
                || center > Double(rightmost.upperBound) + tolerance
            guard outside else { return false }
        }
        // 落进来的位数太少就不是一注 —— 允许缺一两位（那几格标问号），
        // 但不能只落一两位就当成一注
        return landed >= Swift.max(1, ranges.count - 2)
    }

    /// 划格子。`span` 是号码区在配准图里的横向范围（左边界到右边界）。
    static func build(mask: InkMask,
                      within span: ClosedRange<Int>,
                      layout: DigitTicketLayout,
                      digitCenters: [Double] = []) -> NumberGrid? {
        guard mask.width > 0, mask.height > 0 else { return nil }
        let all = candidates(in: mask, within: span, columns: layout.columns)
        // 先用"互相对得齐"的那几行把列位定下来
        let consensus = betRows(all, columns: layout.columns)
        guard !consensus.isEmpty else { return nil }
        guard var ranges = columnRanges(consensus) else { return nil }

        // 号码左右多出来的列（注序号、倍数）裁掉
        if ranges.count > layout.columns {
            guard let kept = trimming(ranges, columns: layout.columns,
                                      digitCenters: digitCenters) else { return nil }
            // 两位数的那一列要取并集（见 `unionRange`）。裁完才知道哪一列是
            // 真正的末列 —— 倍数列在右边，不裁掉的话会union错人。
            if layout.trailingMaximum > 9 {
                let widths = kept.map { Double(ranges[$0].upperBound - ranges[$0].lowerBound + 1) }
                let glyph = median(widths)
                let base = unionRange(consensus, at: kept.upperBound) ?? ranges[kept.upperBound]
                ranges[kept.upperBound] = wideningTail(base, by: glyph)
            }
            ranges = kept.map { ranges[$0] }
        } else if layout.trailingMaximum > 9, ranges.count == layout.columns {
            let glyph = median(ranges.map { Double($0.upperBound - $0.lowerBound + 1) })
            let base = unionRange(consensus, at: ranges.count - 1) ?? ranges[ranges.count - 1]
            ranges[ranges.count - 1] = wideningTail(base, by: glyph)
        }

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
