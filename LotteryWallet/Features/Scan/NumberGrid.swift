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
    /// 由 `window` 按实测的列距和字宽规律去判，不在这里瞎猜。
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
            // 上限给得宽：票面上号码左右还杵着注序号、玩法标签、倍数，
            // 而中文标签常常被切成好几段（`组` 是 纟+且 两段，`六` 还能再拆）。
            // 卡得紧的话整行被判掉 —— 实测福彩 3D 每行切出 11 段，
            // 卡在 5 段就是「候选行 0 条」，一注都读不出来。
            // 该留哪几列交给 `window` 按列距规律去挑，不在这里瞎砍。
            guard segments.count <= columns + 8,
                  segments.count >= Swift.max(1, columns - 2) else { continue }
            found.append(Candidate(band: band, segments: segments))
        }
        return found
    }

    /// 每一条墨迹带切出了几段 —— **不过任何筛子**，只给调试图看。
    ///
    /// `candidates` 会按段数上下限把行筛掉，筛完是 0 条时调试图只能说
    /// 「候选行 0 条」，看不出是压根没切出带来、还是段数卡在了上限外面。
    /// 福彩 3D 那一轮就卡在这儿：真机报 0 条，而实际上每行切了 11 段，
    /// 只是撞上了当时 `columns + 2` 的上限。把原始段数摊开就不用再猜。
    static func bandShapes(in mask: InkMask, within span: ClosedRange<Int>) -> [Int] {
        guard mask.height > 0, span.lowerBound <= span.upperBound else { return [] }
        let width = Double(span.upperBound - span.lowerBound + 1)
        let profile = mask.rowProfile(rows: 0...(mask.height - 1), columns: span)
        return InkMask.runs(profile, above: width * 0.05).compactMap { band in
            guard band.upperBound - band.lowerBound + 1 >= 3 else { return nil }
            let runs = InkMask.runs(mask.columnProfile(rows: band, columns: span), above: 0)
            return merging(runs.map {
                (span.lowerBound + $0.lowerBound)...(span.lowerBound + $0.upperBound)
            }).count
        }
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

    /// 从多切出来的那些列里，挑出**最像号码矩阵**的连续一段。
    ///
    /// 号码是等距印的，只有最后一位可能远一点（七星彩的特别号，
    /// `DigitTicketLayout.trailingPitch` 记着实测值 1.58）。而且号码是等宽印的 ——
    /// 一位就是一个字宽。注序号列（`①` 带个圈，比数字宽）、玩法标签列
    /// （`组六:` 实测 29–78，比数字宽三倍）、倍数列（`(1)` 实测 295–329）
    /// 三样都同时破坏这两条规律，按规律挑就能避开它们。
    ///
    /// 上一版是靠「这一列里有没有数字字符」来认注序号列的，**那条路是死的**：
    /// 文档第七节写着 `.fast` 会把圈码 `①` 读成 `0` —— 注序号列里于是"有数字"，
    /// 判据失效，整个矩阵被毙掉。真机上七星彩 5 行各切出 8 段、格子划得好好的，
    /// 就卡死在这一步。几何规律不依赖 OCR，稳得多。
    ///
    /// 打分的两项（都是无量纲的，跟裁切和拍摄距离无关）：
    /// - **列距**：把末段列距先除掉 `trailingPitch` 折算成标准列距，
    ///   再看最离谱的那一段偏中位数多少。取 max ——
    ///   有一段列距不对，这一段窗口就是错的。
    /// - **字宽**：各列宽偏离中位宽多少，取**平均**而不是 max ——
    ///   某一列碰巧全是 `1`（笔画细）不该一票否决掉正确的窗口。
    ///
    /// 权重 0.7 是拿四种版式的实测列位扫出来的：光看列距，排列3 只有
    /// 62.5 对 65 这么点差别（注序号列距和号码列距几何上分不开，文档 3.2 节
    /// 就是这么记的），±3px 抖动下只有七成能挑对；加上字宽这一项之后全中。
    ///
    /// 数字字符只留作一道**否决**：挑中的这一段里至少一半的列得有数字，
    /// 否则是整段压在中文标签上了。
    static func window(_ ranges: [ClosedRange<Int>],
                       columns: Int,
                       trailingPitch: Double,
                       digitCenters: [Double]) -> ClosedRange<Int>? {
        guard ranges.count >= columns, columns >= 2 else { return nil }
        var bestStart: Int?
        var bestScore = Double.greatestFiniteMagnitude
        for start in 0...(ranges.count - columns) {
            let picked = Array(ranges[start..<(start + columns)])
            let centers = picked.map { Double($0.lowerBound + $0.upperBound) / 2 }
            let widths = picked.map { Double($0.upperBound - $0.lowerBound + 1) }
            let gaps = zip(centers, centers.dropFirst()).map { $1 - $0 }
            guard !gaps.isEmpty else { continue }

            // 这一段里至少一半的列得有数字，否则是压在中文标签上了
            let withDigits = picked.filter { range in
                digitCenters.contains {
                    Double(range.lowerBound) <= $0 && $0 <= Double(range.upperBound)
                }
            }.count
            guard withDigits * 2 >= columns else { continue }

            // 末段列距折算成标准列距，之后每一段都该相等
            let units = gaps.enumerated().map { index, gap in
                index == gaps.count - 1 ? gap / Swift.max(trailingPitch, 0.01) : gap
            }
            let pitch = median(units)
            guard pitch > 0 else { continue }
            let pitchDeviation = (units.map { abs($0 - pitch) }.max() ?? 0) / pitch

            let glyph = median(widths)
            guard glyph > 0 else { continue }
            let widthDeviation = widths.map { abs($0 - glyph) }.reduce(0, +)
                / Double(widths.count) / glyph

            let score = pitchDeviation + 0.7 * widthDeviation
            if score < bestScore {
                bestScore = score
                bestStart = start
            }
        }
        guard let bestStart else { return nil }
        return bestStart...(bestStart + columns - 1)
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

        // 号码左右多出来的列（注序号、玩法标签、倍数）按列距规律挑掉
        if ranges.count > layout.columns {
            guard let kept = window(ranges, columns: layout.columns,
                                    trailingPitch: Double(layout.trailingPitch),
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
