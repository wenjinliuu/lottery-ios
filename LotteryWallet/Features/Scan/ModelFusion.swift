import Foundation

/// 两个读数合成一个结论：Apple Vision 读出来的票 + 自己的模型按行读出来的号码。
///
/// 上一版模型只当「复核员」：只看一位数的格子、只会把格子改成问号、Vision 没读出来的它不管。
/// 所以识别率的上限还是 Vision —— 真机上七星彩一张票 16 个问号，模型其实都认得。
///
/// 这一版模型把**整行号码**读一遍（`GlyphRows`），和 Vision 逐个号码对：
///
/// | Vision | 模型（有把握） | 结论 |
/// |---|---|---|
/// | 读出来了 | 一样 | 两个互不相干的读法一致，采纳 |
/// | 读出来了 | 不一样 | 谁也不信，标问号 |
/// | 问号 | 读出来了 | **采纳模型的**，前提是整行过得了下面的检查 |
/// | 任意 | 没把握 / 这一行读不成 | 保持 Vision 的结果 |
///
/// 「采纳模型的」不是凭一个字的把握：`GlyphRows.readLine` 要求这一行切出来的数字**个数正好**、
/// 是行里唯一的一串；这里再要求补完之后整注合规（值域、升序、不重复）。任何一条不满足，问号原样留着。
///
/// 只管「一行一注」的票和套餐票下面那块。复式、胆拖的版式还没在真票上量过，不碰。
enum ModelFusion {
    /// 模型要有多大把握才算数。三批真票上，把握到这个数的数字一个都没认错
    /// （数字见 `Engineering/model-rows.md`）。
    static let threshold: Float = 0.9

    struct Report: Equatable {
        /// 票上有几行号码、模型读成了几行。
        var expected = 0
        var read = 0
        /// 两边一致的号码个数。
        var confirmed = 0
        /// Vision 没认出来、用模型补上的号码个数。
        var filled = 0
        /// 两边不一致、标成问号的号码个数。
        var disputed = 0
        /// 这张票的号码是不是**按模型读到的行重建**的（见 `rebuild`）。
        var rebuilt = false

        var note: String {
            guard expected > 0 else { return "模型读行：这种票面不复核" }
            var text: String
            if rebuilt && read == expected {
                text = "模型读行：\(read) 行号码全部读成、注数和票面合计对得上，按模型读到的行重建"
            } else if rebuilt {
                text = "模型读行：读成 \(read) 行，和 Vision 互补拼成 \(expected) 行、注数和票面合计对得上"
            } else {
                text = "模型读行：\(expected) 行号码读成 \(read) 行"
            }
            if read > 0 { text += "，\(confirmed) 个号码和 Vision 一致" }
            if filled > 0 { text += "，补上 \(filled) 个问号" }
            if disputed > 0 { text += "，\(disputed) 个对不上、已标成问号" }
            return text
        }
    }

    /// 模型读出来的一个号码。
    struct Value: Equatable {
        var value: Int
        var confidence: Float
    }

    /// 票上的一行号码：单式的第几注，或者套餐票下面的某个区。
    enum Slot: Equatable {
        case line(Int)
        case zone(SectionKey)
    }

    // MARK: - 入口

    @discardableResult
    static func fuse(_ ticket: inout ScannedTicket, rows: [[GlyphRows.Token]]) -> Report {
        var report = Report()
        // 复式、胆拖一个区的号码多了会折到下一行，先接回去
        let rows = ticket.play == .single ? rows : joinWrapped(rows)
        if ticket.play == .dantuo { return rebuildBanker(&ticket, rows: rows) ?? report }
        if ticket.play == .system, let rebuilt = rebuildSystem(&ticket, rows: rows) { return rebuilt }
        if let rebuilt = rebuild(&ticket, rows: rows) { return rebuilt }
        if let merged = mergeComplementary(&ticket, rows: rows) { return merged }
        var slots: [Slot] = []
        if ticket.play == .single {
            slots = ticket.lines.indices.filter { !ticket.lines[$0].isEmpty }.map { .line($0) }
        }
        // 套餐票下面那块、复式票的两个区：一个区一行
        // （一位数的区不看：排列3 组选复式那一行数字的版式还没在真票上量过；
        // 复式空壳票在上面 `rebuildSystem` 已经用票面合计把关过，对不上时绝不走无锚补位）
        if ticket.isPackage || (ticket.play == .system && !ticket.selections.isEmpty) {
            slots += ticket.game.sections.filter { digits(per: $0) == 2 }.map { .zone($0.key) }
        }
        report.expected = slots.count
        guard !slots.isEmpty, !rows.isEmpty else { return report }

        // 每一行号码 × 号码区里的每一行：读不读得成、和 Vision 像不像
        var options = [[Option?]](repeating: [Option?](repeating: nil, count: rows.count), count: slots.count)
        for (slotIndex, slot) in slots.enumerated() {
            for (rowIndex, tokens) in rows.enumerated() {
                options[slotIndex][rowIndex] = option(for: slot, in: ticket, tokens: tokens)
            }
        }
        for (slotIndex, rowIndex) in settle(match(options), options: options) {
            guard let picked = options[slotIndex][rowIndex] else { continue }
            report.read += 1
            apply(picked.values, to: slots[slotIndex], ticket: &ticket, report: &report)
        }
        if report.filled > 0 || report.disputed > 0 { refreshWarnings(&ticket) }
        return report
    }

    // MARK: - 复式、胆拖

    /// 一个区的号码一行印不下（大乐透一行 7 个），多出来的折到下一行，前面没有标签。
    ///
    /// 这一行全是数字、上一行的号码已经印满一行、而且接上去之后还是升序：它是上一行的续行。
    /// 「还是升序」这一条把「后区」那一行挡在外面 —— 后区的标签没切成段的时候，它看起来也是一行纯数字。
    static func joinWrapped(_ rows: [[GlyphRows.Token]]) -> [[GlyphRows.Token]] {
        var out: [[GlyphRows.Token]] = []
        for tokens in rows {
            guard let last = out.last, !tokens.isEmpty, tokens.count % 2 == 0,
                  tokens.allSatisfy({ $0.digit != DigitClassifier.reject }) else {
                out.append(tokens)
                continue
            }
            let run = Array(last.reversed().prefix { $0.digit != DigitClassifier.reject }.reversed())
            guard run.count >= 14, run.count % 2 == 0 else {
                out.append(tokens)
                continue
            }
            let previous = run[run.count - 2].digit * 10 + run[run.count - 1].digit
            guard tokens[0].digit * 10 + tokens[1].digit > previous else {
                out.append(tokens)
                continue
            }
            // 接在上一行的右边，隔一个「号码之间」的空隙
            let between = run[run.count - 2].segment.x0 - run[run.count - 3].segment.x1
            let shift = run[run.count - 1].segment.x1 + max(between, 1) - tokens[0].segment.x0
            out[out.count - 1] = last + tokens.map { token in
                var moved = token
                moved.segment.x0 += shift
                moved.segment.x1 += shift
                return moved
            }
        }
        return out
    }

    /// 复式票的一个区：实票上「红复:」「蓝复:」「前区」等标签常切不成 `x`（或者干脆没切出段，只剩 `1?` 或纯数字），
    /// 所以直接走 `GlyphRows.readLine` 找唯一一串升序号码，并要求每一位都达到 `threshold`。
    private static func systemZoneRow(_ tokens: [GlyphRows.Token], section: GameSection,
                                      minCount: Int? = nil, maxCount: Int? = nil) -> [Value]? {
        let width = digits(per: section)
        let low = minCount ?? section.count
        let high = maxCount ?? min(section.range.upperBound, width == 1 ? 10 : 20)
        guard low <= high else { return nil }
        var matches: [[Value]] = []
        for count in low...high {
            guard let read = GlyphRows.readLine(tokens, count: count * width) else { continue }
            let values = numbers(read, parts: [(section, count)])
            let raw = values.map(\.value)
            let ascendingUnique = zip(raw, raw.dropFirst()).allSatisfy { $0 < $1 }
            if raw.allSatisfy(section.range.contains),
               (count == 1 || ascendingUnique),
               values.allSatisfy({ $0.confidence >= threshold }) {
                matches.append(values)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// 复式票：模型把对应号码区都读成、每位数都有把握、展开注数和票面合计对得上，就以模型为准。
    ///
    /// 支持双色球/大乐透双区复式、七乐彩/快乐8 单区复式、排列3/3D 组选3/组选6 复式、
    /// 以及排列3/排列5 直选定位复式；金额强校验不通过时绝不改票。
    static func rebuildSystem(_ ticket: inout ScannedTicket, rows: [[GlyphRows.Token]]) -> Report? {
        let sections = ticket.game.sections
        guard ticket.play == .system, let total = ticket.totalAmount, total > 0 else { return nil }
        let nonEmpty = rows.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        let prices: [Double] = ticket.game == .dlt ? [2, 3] : [2]
        let multPeriods = max(ticket.multiple, 1) * max(ticket.periods, 1)

        // 1. 双色球 / 大乐透双区复式
        if (ticket.game == .ssq || ticket.game == .dlt), sections.count == 2, nonEmpty.count >= 2 {
            let (front, back) = (sections[0], sections[1])
            var candidates: [(front: [Value], back: [Value])] = []
            for index in 0..<(nonEmpty.count - 1) {
                guard let first = systemZoneRow(nonEmpty[index], section: front),
                      let second = systemZoneRow(nonEmpty[index + 1], section: back) else { continue }
                let units = combinations(first.count, front.count) * combinations(second.count, back.count)
                guard units > 1 else { continue }
                let scale = Double(units * multPeriods)
                guard prices.contains(where: { abs(scale * $0 - total) < 0.01 }) else { continue }
                candidates.append((first, second))
            }
            guard candidates.count == 1, let picked = candidates.first else { return nil }

            var report = Report(expected: 2, read: 2, rebuilt: true)
            for (section, values) in [(front, picked.front), (back, picked.back)] {
                let model = values.map(\.value)
                let known = ticket.selections[section.key]?.selected.sorted() ?? []
                if known == model {
                    report.confirmed += model.count
                } else if known.count != model.count {
                    ticket.selections[section.key] = SectionSelection(selected: model)
                    report.filled += model.count
                } else {
                    ticket.selections[section.key] = SectionSelection(selected: model)
                    report.disputed += 1
                    let other = known.map { String(format: "%02d", $0) }.joined(separator: " ")
                    ticket.warnings.append("\(section.label)这一行两种读法不一致，另一种读到的是 \(other)，请对照票面核对。")
                }
            }
            refreshWarnings(&ticket)
            return report
        }

        // 2. 快乐8 / 七乐彩单区复式
        if (ticket.game == .k8 || ticket.game == .qlc), let section = sections.first {
            let need = ticket.game == .k8 ? (Int(ticket.playMode) ?? 0) : section.count
            guard need >= 1 else { return nil }
            var candidates: [[Value]] = []
            for row in nonEmpty {
                guard let values = systemZoneRow(row, section: section, minCount: need + 1, maxCount: 20) else { continue }
                let units = combinations(values.count, need)
                guard units > 1, abs(Double(units * multPeriods) * 2.0 - total) < 0.01 else { continue }
                candidates.append(values)
            }
            guard candidates.count == 1, let picked = candidates.first else { return nil }
            let model = picked.map(\.value)
            let known = ticket.selections[section.key]?.selected.sorted() ?? []
            var report = Report(expected: 1, read: 1, rebuilt: true)
            if known == model {
                report.confirmed += model.count
            } else if known.count != model.count {
                ticket.selections[section.key] = SectionSelection(selected: model)
                report.filled += model.count
            } else {
                ticket.selections[section.key] = SectionSelection(selected: model)
                report.disputed += 1
                let other = known.map { String(format: "%02d", $0) }.joined(separator: " ")
                ticket.warnings.append("\(section.label)这一行两种读法不一致，另一种读到的是 \(other)，请对照票面核对。")
            }
            refreshWarnings(&ticket)
            return report
        }

        // 3. 排列3 / 3D 组选复式（组选3复式 / 组选6复式）与 排列3 / 排列5 直选定位复式
        if (ticket.game == .pl3 || ticket.game == .fc3d || ticket.game == .pl5), let section = sections.first {
            let mode = ticket.effectivePlayMode()
            if (ticket.game == .pl3 || ticket.game == .fc3d), mode == "group3" || mode == "group6" {
                let minCount = mode == "group3" ? 2 : 4
                var candidates: [[Value]] = []
                for row in nonEmpty {
                    guard let values = systemZoneRow(row, section: section, minCount: minCount, maxCount: 10) else { continue }
                    let n = values.count
                    let units = mode == "group3" ? n * (n - 1) : combinations(n, 3)
                    guard units > 1, abs(Double(units * multPeriods) * 2.0 - total) < 0.01 else { continue }
                    candidates.append(values)
                }
                guard candidates.count == 1, let picked = candidates.first else { return nil }
                let model = picked.map(\.value)
                let known = ticket.selections[section.key]?.selected.sorted() ?? []
                var report = Report(expected: 1, read: 1, rebuilt: true)
                if known == model {
                    report.confirmed += model.count
                } else {
                    ticket.selections[section.key] = SectionSelection(selected: model)
                    if known.count == model.count {
                        report.disputed += 1
                        let other = known.map(String.init).joined(separator: " ")
                        ticket.warnings.append("\(section.label)这一行两种读法不一致，另一种读到的是 \(other)，请对照票面核对。")
                    } else {
                        report.filled += model.count
                    }
                }
                refreshWarnings(&ticket)
                return report
            } else if ticket.game.usesPositionalSystem(for: section, playMode: mode), nonEmpty.count >= section.count {
                let need = section.count
                var candidates: [[[Int]]] = []
                for start in 0...(nonEmpty.count - need) {
                    var positions: [[Int]] = []
                    var units = 1
                    var valid = true
                    for offset in 0..<need {
                        guard let values = systemZoneRow(nonEmpty[start + offset], section: section, minCount: 1, maxCount: 10) else {
                            valid = false; break
                        }
                        positions.append(values.map(\.value))
                        units *= values.count
                    }
                    guard valid, units > 1, abs(Double(units * multPeriods) * 2.0 - total) < 0.01 else { continue }
                    candidates.append(positions)
                }
                guard candidates.count == 1, let picked = candidates.first else { return nil }
                var report = Report(expected: need, read: need, rebuilt: true)
                let known = ticket.selections[section.key]?.positional ?? []
                if known == picked {
                    report.confirmed += picked.reduce(0) { $0 + $1.count }
                } else {
                    ticket.selections[section.key] = SectionSelection(positional: picked)
                    report.filled += picked.reduce(0) { $0 + $1.count }
                }
                refreshWarnings(&ticket)
                return report
            }
        }
        return nil
    }

    /// 一行「可选标签 + 一串有序号码」：兼容带标签切字行（`GlyphRows`）与整行序列读数（`CoreMLLineReader`）。
    private static func labelled(_ tokens: [GlyphRows.Token], section: GameSection,
                                 allowUnlabelled: Bool = true) -> [Value]? {
        if !allowUnlabelled {
            guard let first = tokens.first, first.digit == DigitClassifier.reject else { return nil }
        }
        let width = digits(per: section)
        let maxN = width == 1 ? 10 : 18
        var found: [Value]?
        for count in 1...maxN {
            guard let read = GlyphRows.readLine(tokens, count: count * width) else { continue }
            let values = numbers(read, parts: [(section, count)])
            let raw = values.map(\.value)
            let ascendingUnique = zip(raw, raw.dropFirst()).allSatisfy { $0 < $1 }
            if raw.allSatisfy(section.range.contains),
               (count == 1 || ascendingUnique),
               values.allSatisfy({ $0.confidence >= threshold }) {
                found = values
            }
        }
        return found
    }

    /// 胆拖票：模型把「胆 / 拖」几行都读成了、注数和票面合计对得上，就以模型为准。
    ///
    /// 支持双色球、大乐透（含后区无胆与前区无胆）、七乐彩、快乐8 与 排列3/3D 组选胆拖。
    /// 对不上就返回 nil，票保持 Vision 读到的样子。
    static func rebuildBanker(_ ticket: inout ScannedTicket, rows: [[GlyphRows.Token]]) -> Report? {
        let sections = ticket.game.sections
        guard let total = ticket.totalAmount, total > 0 else { return nil }
        let multPeriods = max(ticket.multiple, 1) * max(ticket.periods, 1)
        let prices: [Double] = ticket.game == .dlt ? [2, 3] : [2]

        // 1. 双色球 / 大乐透双区胆拖
        if (ticket.game == .dlt || ticket.game == .ssq), sections.count == 2 {
            let (front, back) = (sections[0], sections[1])
            var firstRows: [[Int]] = [], secondRows: [[Int]] = []
            for tokens in rows {
                if firstRows.count < 2, let values = labelled(tokens, section: front) {
                    firstRows.append(values.map(\.value))
                } else if firstRows.count == 2, secondRows.count < 2, let values = labelled(tokens, section: back) {
                    secondRows.append(values.map(\.value))
                }
            }
            var resolved: (frontDan: [Int], frontTuo: [Int], backDan: [Int], backTuo: [Int], count: Int)?
            if firstRows.count == 2, (1...2).contains(secondRows.count) {
                let fDan = firstRows[0], fTuo = firstRows[1]
                let bDan = secondRows.count == 2 ? secondRows[0] : []
                let bTuo = secondRows.count == 2 ? secondRows[1] : secondRows[0]
                if fDan.count < front.count, bDan.count < back.count,
                   Set(fDan).isDisjoint(with: fTuo), Set(bDan).isDisjoint(with: bTuo) {
                    let units = combinations(fTuo.count, front.count - fDan.count)
                        * combinations(bTuo.count, back.count - bDan.count)
                    let scale = Double(units * multPeriods)
                    if units > 0, prices.contains(where: { abs(scale * $0 - total) < 0.01 }) {
                        resolved = (fDan, fTuo, bDan, bTuo, 2 + secondRows.count)
                    }
                }
            }
            // 大乐透特例：前区无胆（3 行：前区拖 + 后区胆 + 后区拖）
            if resolved == nil, ticket.game == .dlt {
                var fTuo: [Int]?
                var backRows: [[Int]] = []
                for tokens in rows {
                    if fTuo == nil, let values = labelled(tokens, section: front), values.count >= front.count {
                        fTuo = values.map(\.value)
                    } else if fTuo != nil, backRows.count < 2, let values = labelled(tokens, section: back) {
                        backRows.append(values.map(\.value))
                    }
                }
                if let fTuo, backRows.count == 2 {
                    let bDan = backRows[0], bTuo = backRows[1]
                    if bDan.count == 1, Set(bDan).isDisjoint(with: bTuo) {
                        let units = combinations(fTuo.count, front.count) * combinations(bTuo.count, back.count - bDan.count)
                        let scale = Double(units * multPeriods)
                        if units > 0, prices.contains(where: { abs(scale * $0 - total) < 0.01 }) {
                            resolved = ([], fTuo, bDan, bTuo, 3)
                        }
                    }
                }
            }
            guard let picked = resolved else { return nil }

            var report = Report(expected: picked.count, read: picked.count, rebuilt: true)
            for (section, dan, tuo) in [(front, picked.frontDan, picked.frontTuo), (back, picked.backDan, picked.backTuo)] {
                let model = SectionSelection(selected: (dan + tuo).sorted(), dan: dan)
                let known = ticket.selections[section.key]
                if known?.selected.sorted() == model.selected, known?.dan.sorted() == model.dan.sorted() {
                    report.confirmed += model.selected.count
                } else {
                    report.filled += model.selected.count
                }
                ticket.selections[section.key] = model
            }
            refreshWarnings(&ticket)
            return report
        }

        // 2. 快乐8 / 七乐彩 / 排列3 / 3D 单区胆拖（两行：胆码 + 拖码）
        if (ticket.game == .k8 || ticket.game == .qlc || ticket.game == .pl3 || ticket.game == .fc3d),
           let section = sections.first {
            let mode = ticket.effectivePlayMode()
            let readable = rows.compactMap { labelled($0, section: section)?.map(\.value) }
            guard readable.count >= 2 else { return nil }
            var candidates: [(dan: [Int], tuo: [Int])] = []
            for idx in 0..<(readable.count - 1) {
                let dan = readable[idx], tuo = readable[idx + 1]
                guard Set(dan).isDisjoint(with: tuo), !dan.isEmpty, !tuo.isEmpty else { continue }
                let units: Int
                if ticket.game == .pl3 || ticket.game == .fc3d {
                    if mode == "group3", dan.count == 1 {
                        units = 2 * tuo.count
                    } else if mode == "group6", (1...2).contains(dan.count) {
                        units = combinations(tuo.count, 3 - dan.count)
                    } else {
                        continue
                    }
                } else {
                    let need = ticket.game == .k8 ? (Int(ticket.playMode) ?? 0) : section.count
                    guard need >= 2, dan.count < need, dan.count + tuo.count >= need else { continue }
                    units = combinations(tuo.count, need - dan.count)
                }
                guard units > 0, abs(Double(units * multPeriods) * 2.0 - total) < 0.01 else { continue }
                candidates.append((dan, tuo))
            }
            guard candidates.count == 1, let picked = candidates.first else { return nil }
            let model = SectionSelection(selected: (picked.dan + picked.tuo).sorted(), dan: picked.dan)
            var report = Report(expected: 2, read: 2, rebuilt: true)
            let known = ticket.selections[section.key]
            if known?.selected.sorted() == model.selected, known?.dan.sorted() == model.dan.sorted() {
                report.confirmed += model.selected.count
            } else {
                report.filled += model.selected.count
            }
            ticket.selections[section.key] = model
            refreshWarnings(&ticket)
            return report
        }
        return nil
    }

    // MARK: - 以模型读到的行为准

    /// 模型自己读出来的整张票：每一注在号码区的第几行、读到了什么；套餐票下面那块的两个区。
    struct Skeleton {
        /// 一注里每个区印几个号。
        var parts: [(section: GameSection, count: Int)] = []
        var rows: [Int] = []
        var lines: [[Value]] = []
        /// 福彩每一注行尾括号里的倍数，读不出来是 nil。
        var multiples: [Int?] = []
        var zones: [SectionKey: [Value]] = [:]
    }

    /// 只凭模型读到的行，按这个彩种一行号码该有的样子，把整张票搭出来。
    /// 一行一注的票都管（3D 除外）：体彩四种，加上双色球、七乐彩、快乐8 的单式。
    ///
    /// 一行号码「该有的样子」很死：大乐透 14 位、排列5 五位、排列3 三位、七星彩 7 或 8 位；
    /// 套餐票下面是「前区」「后区」各一行偶数位。`GlyphRows.readLine` 要求个数正好，
    /// 多一位少一位都不算，所以这里搭出来的每一行都是完整的一行。
    static func skeleton(game: GameKey, playMode: String = "", rows: [[GlyphRows.Token]]) -> Skeleton? {
        let sections = game.sections
        // 一注里每个区印几个号。快乐8 看玩法（选五就是 5 个）。
        var parts: [(section: GameSection, count: Int)] = sections.map { ($0, $0.count) }
        if game == .k8 {
            guard let want = Int(playMode), (1...10).contains(want) else { return nil }
            parts = [(sections[0], want)]
        }
        guard game != .fc3d else { return nil }       // 3D 每注前面印着玩法，行的样子不固定
        var out = Skeleton(parts: parts)
        for (index, tokens) in rows.enumerated() {
            var line: [Value]?
            if game == .qxc {
                if let seven = GlyphRows.readLine(tokens, count: 7) {
                    line = seven.map(single)
                } else if let eight = GlyphRows.readLine(tokens, count: 8), eight[6].digit == 1 {
                    line = eight.prefix(6).map(single)
                        + [Value(value: 10 + eight[7].digit, confidence: min(eight[6].confidence, eight[7].confidence))]
                }
            } else {
                let total = parts.reduce(0) { $0 + $1.count * digits(per: $1.section) }
                if let found = GlyphRows.readLine(tokens, count: total) { line = numbers(found, parts: parts) }
            }
            if let line, sound(line, parts: parts) {
                out.rows.append(index)
                out.lines.append(line)
                out.multiples.append(trailingMultiple(tokens))
                continue
            }
            // 大乐透套餐票下面那块：先前区、后后区
            guard game == .dlt, !out.lines.isEmpty else { continue }
            for section in sections where out.zones[section.key] == nil {
                var found: [Value]?
                for count in section.count...(section.count + 8) {
                    guard let read = GlyphRows.readLine(tokens, count: count * 2) else { continue }
                    let values = numbers(read, parts: [(section, count)])
                    if ordered(values.map(\.value), section: section) { found = values }
                }
                if let found { out.zones[section.key] = found }
                // 一行只能是一个区；前区没读成就不往后区上凑
                break
            }
        }
        return out.lines.isEmpty ? nil : out
    }

    /// 票头读不到时，只采信符合「等距六位 + 隔开的特别号」且金额吻合的体彩号码区。
    static func matchesSevenStars(rows: [[GlyphRows.Token]], text: String) -> Bool {
        guard let total = TicketTextParser.extractTotal(text),
              let layout = skeleton(game: .qxc, rows: rows), layout.lines.count >= 2,
              layout.lines.allSatisfy({ $0.allSatisfy { $0.confidence >= threshold } }) else { return false }
        let multiple = TicketTextParser.extractMultiple(text) ?? 1
        guard total == Double(layout.lines.count * 2 * multiple) else { return false }
        return layout.rows.allSatisfy { index in
            let row = rows[index]
            guard let digits = GlyphRows.readLine(row, count: 7) ?? GlyphRows.readLine(row, count: 8) else { return false }
            let centers = digits.map { Double($0.segment.x0 + $0.segment.x1) / 2 }
            let steps = (1...5).map { centers[$0] - centers[$0 - 1] }
            let pitch = steps.sorted()[2]
            let tailCenter = (centers[6] + centers[centers.count - 1]) / 2
            let gap = tailCenter - centers[5]
            return pitch > 0 && steps.allSatisfy { (0.75 * pitch...1.25 * pitch).contains($0) }
                && (1.3 * pitch...2.1 * pitch).contains(gap)
        }
    }

    /// 福彩一注的最后印着「(2)」：括号多半切不成数字，中间那个倍数切得成。
    /// 一行最右边那一段是「不是数字」、它左边紧挨着一个有把握的数字，那个数字就是倍数。
    static func trailingMultiple(_ tokens: [GlyphRows.Token]) -> Int? {
        guard tokens.count >= 3, let last = tokens.last, last.digit == DigitClassifier.reject else { return nil }
        let digit = tokens[tokens.count - 2]
        guard digit.digit != DigitClassifier.reject, digit.digit >= 1, digit.confidence >= threshold,
              tokens[tokens.count - 3].digit == DigitClassifier.reject else { return nil }
        return digit.digit
    }

    /// 一注的每个区都在值域里、两位数的区升序不重复。
    private static func sound(_ line: [Value], parts: [(section: GameSection, count: Int)]) -> Bool {
        var cursor = 0
        for part in parts {
            guard cursor + part.count <= line.count else { return false }
            guard ordered(line[cursor..<cursor + part.count].map(\.value), section: part.section) else { return false }
            cursor += part.count
        }
        return cursor == line.count
    }

    /// **模型读到的行当骨架，Vision 的读数拿来对。**
    ///
    /// 上一版反过来：Vision 认出几注就是几注，模型只能在这几注里补问号。真机上 Vision 把
    /// `⑤ 07 12 18 19 27` 读成 `07 12 118 19 27`，整注被丢；把 `② 09` 读成 `Q09`，后面全错开 ——
    /// 这两注模型其实都读对了，但没有地方可放。
    ///
    /// 只有模型这边**自己站得住**才换骨架：
    /// 1. 每一行都按这个彩种该有的位数读成了（`skeleton`）；
    /// 2. 注数乘单价正好等于票面印的合计 —— 这是和号码无关的第三个读数。
    ///
    /// 换了骨架之后 Vision 仍然有用：它读出来的每一注去找模型的同一行，
    /// 同一个号码两边不一样就标问号；模型没把握的那一位用 Vision 的。
    /// 条件不满足就返回 nil，走原来「Vision 为骨架、模型补问号」的路。
    static func rebuild(_ ticket: inout ScannedTicket, rows: [[GlyphRows.Token]]) -> Report? {
        let game = ticket.game
        guard ticket.play == .single, let total = ticket.totalAmount, total > 0,
              let skeleton = skeleton(game: game, playMode: ticket.playMode, rows: rows) else { return nil }
        // 排列3 每一注还带着自己的玩法（组三 / 组六），注数变了就对不上了
        if !ticket.lineModes.isEmpty, ticket.lineModes.count != skeleton.lines.count { return nil }
        let sections = game.sections
        var blockUnits = 0
        if !skeleton.zones.isEmpty {
            guard let front = skeleton.zones[sections[0].key], let back = skeleton.zones[sections[1].key] else { return nil }
            blockUnits = combinations(front.count, sections[0].count) * combinations(back.count, sections[1].count)
        }
        // 倍数：Vision 读到的那个；福彩每一注行尾括号里的倍数模型都读到了、而且都一样，也算一个候选。
        // Vision 把括号读丢的时候（真机上三张双色球都是 2 倍，读成了 1 倍）靠它把金额对上。
        var multiples = [max(ticket.multiple, 1)]
        let printed = skeleton.multiples.compactMap { $0 }
        if printed.count == skeleton.lines.count, let first = printed.first, printed.allSatisfy({ $0 == first }),
           !multiples.contains(first) { multiples.append(first) }
        let prices: [Double] = game == .dlt ? [2, 3] : [2]
        let base = Double((skeleton.lines.count + blockUnits) * max(ticket.periods, 1))
        guard let multiple = multiples.first(where: { times in
            prices.contains { abs(base * Double(times) * $0 - total) < 0.01 }
        }) else { return nil }
        ticket.multiple = multiple

        // Vision 读到的每一注去找模型的同一行
        let slots: [Slot] = ticket.lines.indices.filter { !ticket.lines[$0].isEmpty }.map { .line($0) }
        var options = [[Option?]](repeating: [Option?](repeating: nil, count: rows.count), count: slots.count)
        for (slotIndex, slot) in slots.enumerated() {
            for rowIndex in skeleton.rows {
                options[slotIndex][rowIndex] = option(for: slot, in: ticket, tokens: rows[rowIndex])
            }
        }
        var visionAt: [Int: [Int]] = [:]
        for pair in settle(match(options), options: options) {
            visionAt[pair.row] = current(of: slots[pair.slot], in: ticket)
        }

        var report = Report(expected: skeleton.lines.count, read: skeleton.lines.count, rebuilt: true)
        var lines: [NumberSet] = []
        for (line, row) in zip(skeleton.lines, skeleton.rows) {
            lines.append(combine(model: line, vision: visionAt[row], parts: skeleton.parts, report: &report))
        }
        ticket.lines = lines
        if !skeleton.zones.isEmpty {
            ticket.isPackage = true
            for section in sections {
                guard let values = skeleton.zones[section.key] else { continue }
                apply(values, to: .zone(section.key), ticket: &ticket, report: &report)
            }
        }
        refreshWarnings(&ticket)
        return report
    }

    /// 模型只读出一部分行、Vision 读出另一部分行：把两边互补拼成整张票。
    ///
    /// 只有严格满足下面四条才拼，绝不凑数：
    /// 1. 两边能对齐的行先按常规交叉核对（一致留下、冲突标问号、模型补问号）；
    /// 2. 模型独有的每一行，**每一个数字**都要达到 `threshold`（0.90），且不和未对齐的 Vision 行重复；
    /// 3. 未对齐的 Vision 行不含问号（防止残缺的数字行被误当成独立一注），且模型至少贡献了 1 行新注；
    /// 4. 拼出来的总注数乘单价（含倍数、期数）**正好等于票面合计**。
    static func mergeComplementary(_ ticket: inout ScannedTicket, rows: [[GlyphRows.Token]]) -> Report? {
        let game = ticket.game
        guard ticket.play == .single, !ticket.isPackage, ticket.lineModes.isEmpty,
              let total = ticket.totalAmount, total > 0,
              let skeleton = skeleton(game: game, playMode: ticket.playMode, rows: rows) else { return nil }
        let visionIndices = ticket.lines.indices.filter { !ticket.lines[$0].isEmpty }
        guard !visionIndices.isEmpty else { return nil }

        let slots = visionIndices.map { Slot.line($0) }
        var options = [[Option?]](repeating: [Option?](repeating: nil, count: skeleton.rows.count), count: slots.count)
        for (slotIndex, slot) in slots.enumerated() {
            for (skelIndex, rowIndex) in skeleton.rows.enumerated() {
                options[slotIndex][skelIndex] = option(for: slot, in: ticket, tokens: rows[rowIndex])
            }
        }
        let pairs = settle(match(options), options: options)
        let matchedSlots = Set(pairs.map(\.slot))
        let matchedSkels = Set(pairs.map(\.row))

        let modelOnlyIndices = skeleton.lines.indices.filter { !matchedSkels.contains($0) }
        guard !modelOnlyIndices.isEmpty else { return nil }
        guard modelOnlyIndices.allSatisfy({ skeleton.lines[$0].allSatisfy { $0.confidence >= threshold } }) else {
            return nil
        }

        let unmatchedVisionLines = visionIndices.enumerated()
            .filter { !matchedSlots.contains($0.offset) }
            .map { ticket.lines[$0.element] }
        guard unmatchedVisionLines.allSatisfy({ line in
            !line.values.values.contains { $0.contains { $0 < 0 } }
        }) else { return nil }

        let unmatchedVisionSets = Set(unmatchedVisionLines)
        var modelOnlySets: [Int: NumberSet] = [:]
        for skelIndex in modelOnlyIndices {
            let set = numberSet(from: skeleton.lines[skelIndex], parts: skeleton.parts)
            if unmatchedVisionSets.contains(set) { return nil }
            modelOnlySets[skelIndex] = set
        }

        let mergedCount = visionIndices.count + modelOnlyIndices.count
        var multiples = [max(ticket.multiple, 1)]
        let printed = skeleton.multiples.compactMap { $0 }
        if printed.count == skeleton.lines.count, let first = printed.first, printed.allSatisfy({ $0 == first }),
           !multiples.contains(first) { multiples.append(first) }
        let prices: [Double] = game == .dlt ? [2, 3] : [2]
        let base = Double(mergedCount * max(ticket.periods, 1))
        guard let multiple = multiples.first(where: { times in
            prices.contains { abs(base * Double(times) * $0 - total) < 0.01 }
        }) else { return nil }
        ticket.multiple = multiple

        var report = Report(expected: mergedCount, read: skeleton.lines.count, rebuilt: true)
        var merged: [NumberSet] = []
        var nextSlot = 0
        var nextSkel = 0

        func emitUnmatched(upToSlot slotLimit: Int, upToSkel skelLimit: Int) {
            while nextSlot < slotLimit {
                if !matchedSlots.contains(nextSlot) {
                    merged.append(ticket.lines[visionIndices[nextSlot]])
                }
                nextSlot += 1
            }
            while nextSkel < skelLimit {
                if let set = modelOnlySets[nextSkel] {
                    merged.append(set)
                    report.filled += skeleton.lines[nextSkel].count
                }
                nextSkel += 1
            }
        }

        for pair in pairs {
            emitUnmatched(upToSlot: pair.slot, upToSkel: pair.row)
            let vision = current(of: slots[pair.slot], in: ticket)
            let fused = combine(model: skeleton.lines[pair.row], vision: vision, parts: skeleton.parts, report: &report)
            merged.append(fused)
            nextSlot = pair.slot + 1
            nextSkel = pair.row + 1
        }
        emitUnmatched(upToSlot: slots.count, upToSkel: skeleton.lines.count)

        ticket.lines = merged
        refreshWarnings(&ticket)
        return report
    }

    private static func numberSet(from line: [Value], parts: [(section: GameSection, count: Int)]) -> NumberSet {
        var numbers = NumberSet()
        var cursor = 0
        for (section, count) in parts {
            numbers[section.key] = line[cursor..<cursor + count].map(\.value)
            cursor += count
        }
        return numbers
    }

    private static func combine(model line: [Value], vision: [Int]?,
                                parts: [(section: GameSection, count: Int)],
                                report: inout Report) -> NumberSet {
        var numbers = NumberSet()
        var cursor = 0
        for (section, count) in parts {
            var values: [Int] = []
            for _ in 0..<count {
                let entry = line[cursor]
                let seen = vision.flatMap { cursor < $0.count ? $0[cursor] : nil } ?? NumberSet.unknown
                cursor += 1
                let sure = entry.confidence >= threshold
                if seen < 0 {
                    values.append(sure ? entry.value : NumberSet.unknown)
                    if sure { report.filled += 1 }
                } else if !sure {
                    values.append(seen)
                } else if seen == entry.value {
                    values.append(seen)
                    report.confirmed += 1
                } else {
                    values.append(NumberSet.unknown)
                    report.disputed += 1
                }
            }
            // 拿 Vision 的值顶上之后不合规了：这一区里 Vision 顶上的那几位退回问号
            if !ordered(values, section: section) {
                for position in values.indices where line[cursor - count + position].confidence < threshold {
                    values[position] = NumberSet.unknown
                }
            }
            numbers[section.key] = values
        }
        return numbers
    }

    static func combinations(_ total: Int, _ pick: Int) -> Int {
        guard pick >= 0, total >= pick else { return 0 }
        var result = 1
        for index in 0..<pick { result = result * (total - index) / (index + 1) }
        return result
    }

    /// 模型读到的每一行，写成一行字。放在「识别原文」后面，出了问题一眼看得出模型读到了什么：
    /// 数字照写，「不是数字」写 `x`，没把握的数字后面跟一个 `?`。
    static func describe(_ rows: [[GlyphRows.Token]]) -> String {
        rows.map { tokens in
            tokens.map { token -> String in
                guard token.digit != DigitClassifier.reject else { return "x" }
                return token.confidence >= threshold ? String(token.digit) : "\(token.digit)?"
            }.joined()
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - 一行读成号码

    struct Option {
        var values: [Value]
        var score: Int
        /// 和 Vision 已经读出来的号码有几个一样。0 个就是「没有锚」：光凭内容说不清它是哪一行。
        var agree = 0
    }

    /// 这一行号码每个区印几个号、一个号占几位。
    static func layout(of slot: Slot, in ticket: ScannedTicket) -> [(section: GameSection, count: Int)] {
        switch slot {
        case .line(let index):
            return ticket.game.sections.map { ($0, ticket.lines[index][$0.key].count) }
        case .zone(let key):
            return ticket.game.sections.filter { $0.key == key }
                .map { ($0, ticket.selections[key]?.selected.count ?? 0) }
        }
    }

    static func digits(per section: GameSection) -> Int { section.range.upperBound <= 9 ? 1 : 2 }

    static func option(for slot: Slot, in ticket: ScannedTicket, tokens: [GlyphRows.Token]) -> Option? {
        let parts = layout(of: slot, in: ticket)
        var candidates: [[Value]] = []
        switch slot {
        case .line:
            guard parts.allSatisfy({ $0.count > 0 }) else { return nil }
            if ticket.game == .qxc {
                // 前六位各一位；特别号 0–14，印一位或两位，两位时十位只能是 1
                if let seven = GlyphRows.readLine(tokens, count: 7) { candidates.append(seven.map(single)) }
                if let eight = GlyphRows.readLine(tokens, count: 8), eight[6].digit == 1 {
                    let tail = Value(value: 10 + eight[7].digit, confidence: min(eight[6].confidence, eight[7].confidence))
                    candidates.append(eight.prefix(6).map(single) + [tail])
                }
            } else {
                let total = parts.reduce(0) { $0 + $1.count * digits(per: $1.section) }
                if let found = GlyphRows.readLine(tokens, count: total) {
                    candidates.append(numbers(found, parts: parts))
                }
            }
        case .zone:
            guard let section = parts.first?.section else { return nil }
            // 这个区选了几个号不一定读得出来（整行没认出来时是 0 个），所以个数从少到多都试一遍
            for count in section.count...(section.count + 8) {
                guard let found = GlyphRows.readLine(tokens, count: count * 2) else { continue }
                candidates.append(numbers(found, parts: [(section, count)]))
            }
        }
        let known = current(of: slot, in: ticket)
        var best: Option?
        for values in candidates {
            guard legal(values, slot: slot, in: ticket) else { continue }
            var agree = 0, differ = 0
            if case .zone = slot, !known.isEmpty, known.count != values.count {
                differ = max(known.count, values.count)
            } else {
                for (index, value) in values.enumerated() where index < known.count && known[index] >= 0 {
                    if known[index] == value.value { agree += 1 } else { differ += 1 }
                }
            }
            // 和 Vision 读到的大半对不上：这一行多半不是这一注
            guard differ <= agree else { continue }
            let score = 10 + agree * 2 - differ
            if best == nil || score > best!.score { best = Option(values: values, score: score, agree: agree) }
        }
        return best
    }

    private static func single(_ token: GlyphRows.Token) -> Value {
        Value(value: token.digit, confidence: token.confidence)
    }

    private static func numbers(_ tokens: [GlyphRows.Token],
                                parts: [(section: GameSection, count: Int)]) -> [Value] {
        var out: [Value] = []
        var cursor = 0
        for part in parts {
            let width = digits(per: part.section)
            for _ in 0..<part.count {
                let piece = tokens[cursor..<cursor + width]
                cursor += width
                out.append(Value(value: piece.reduce(0) { $0 * 10 + $1.digit },
                                 confidence: piece.map(\.confidence).min() ?? 0))
            }
        }
        return out
    }

    /// Vision 那边这一行现在的号码，按印刷顺序摊平。问号是 -1。
    static func current(of slot: Slot, in ticket: ScannedTicket) -> [Int] {
        switch slot {
        case .line(let index): return ticket.game.sections.flatMap { ticket.lines[index][$0.key] }
        case .zone(let key): return ticket.selections[key]?.selected ?? []
        }
    }

    /// 模型读出来的这一行本身合不合规：值域对、两位数的区升序不重复。
    static func legal(_ values: [Value], slot: Slot, in ticket: ScannedTicket) -> Bool {
        var cursor = 0
        let parts: [(section: GameSection, count: Int)]
        if case .zone(let key) = slot, let section = ticket.game.sections.first(where: { $0.key == key }) {
            parts = [(section, values.count)]
        } else {
            parts = layout(of: slot, in: ticket)
        }
        for part in parts {
            guard cursor + part.count <= values.count else { return false }
            let piece = values[cursor..<cursor + part.count].map(\.value)
            cursor += part.count
            guard ordered(piece, section: part.section) else { return false }
        }
        return cursor == values.count
    }

    /// 一个区里已经知道的那些号：都在值域里；两位数的区还要升序、不重复。
    static func ordered(_ numbers: [Int], section: GameSection) -> Bool {
        let known = numbers.filter { $0 >= 0 }
        guard known.allSatisfy(section.range.contains) else { return false }
        guard digits(per: section) == 2, section.count > 1 || known.count > 1 else { return true }
        return zip(known, known.dropFirst()).allSatisfy { $0 < $1 }
    }

    // MARK: - 哪一行配哪一行

    /// 保序地把「票上的第几行号码」配给「号码区里的第几行」，总分最高的那一种配法。
    ///
    /// 配上之后再查一遍有没有别的行也说得通：一行号码在上下两个邻居之间
    /// 还有另一行同样读得成、分数不比它低，就说明分不清，这一行不配。
    static func match(_ options: [[Option?]]) -> [(slot: Int, row: Int)] {
        let slots = options.count
        let rows = options.first?.count ?? 0
        guard slots > 0, rows > 0 else { return [] }
        var best = [[Int]](repeating: [Int](repeating: 0, count: rows + 1), count: slots + 1)
        for slot in 1...slots {
            for row in 1...rows {
                var value = max(best[slot - 1][row], best[slot][row - 1])
                if let option = options[slot - 1][row - 1] {
                    value = max(value, best[slot - 1][row - 1] + option.score)
                }
                best[slot][row] = value
            }
        }
        var pairs: [(slot: Int, row: Int)] = []
        var slot = slots, row = rows
        while slot > 0, row > 0 {
            if let option = options[slot - 1][row - 1],
               best[slot][row] == best[slot - 1][row - 1] + option.score {
                pairs.append((slot - 1, row - 1))
                slot -= 1; row -= 1
            } else if best[slot][row] == best[slot - 1][row] {
                slot -= 1
            } else {
                row -= 1
            }
        }
        pairs.reverse()
        return pairs.enumerated().compactMap { index, pair in
            let low = index > 0 ? pairs[index - 1].row + 1 : 0
            let high = index + 1 < pairs.count ? pairs[index + 1].row - 1 : rows - 1
            guard let mine = options[pair.slot][pair.row], low <= high else { return nil }
            for other in low...high where other != pair.row {
                if let rival = options[pair.slot][other], rival.score >= mine.score { return nil }
            }
            return pair
        }
    }

    /// 没有锚的行（Vision 一个号都没读出来）只能靠位置认：它必须**紧挨着**一行有锚的。
    ///
    /// 不加这一条的话，号码区里有一行没读成时，下面几行会整体往上错一行去配 ——
    /// 每个号码都「有把握」，却全是别的注的号。整张票一个锚都没有时，
    /// 只有「读得成的行数正好等于号码行数、而且一行挨一行」才收。
    static func settle(_ pairs: [(slot: Int, row: Int)], options: [[Option?]]) -> [(slot: Int, row: Int)] {
        func anchored(_ pair: (slot: Int, row: Int)) -> Bool { (options[pair.slot][pair.row]?.agree ?? 0) > 0 }
        var kept = pairs.filter(anchored)
        if kept.isEmpty {
            let rows = options.first?.count ?? 0
            let readable = (0..<rows).filter { row in options.contains { $0[row] != nil } }.count
            let consecutive = zip(pairs, pairs.dropFirst()).allSatisfy {
                $1.slot == $0.slot + 1 && $1.row == $0.row + 1
            }
            return pairs.count == options.count && readable == pairs.count && consecutive ? pairs : []
        }
        var grew = true
        while grew {
            grew = false
            for pair in pairs where !kept.contains(where: { $0 == pair }) {
                let touches = kept.contains {
                    ($0.slot == pair.slot - 1 && $0.row == pair.row - 1)
                        || ($0.slot == pair.slot + 1 && $0.row == pair.row + 1)
                }
                if touches { kept.append(pair); grew = true }
            }
        }
        return kept.sorted { $0.slot < $1.slot }
    }

    // MARK: - 合进去

    static func apply(_ values: [Value], to slot: Slot,
                      ticket: inout ScannedTicket, report: inout Report) {
        switch slot {
        case .line(let index):
            var line = ticket.lines[index]
            var cursor = 0
            var filled: [(SectionKey, Int)] = []
            for section in ticket.game.sections {
                var numbers = line[section.key]
                for position in numbers.indices {
                    defer { cursor += 1 }
                    guard cursor < values.count, values[cursor].confidence >= threshold else { continue }
                    let model = values[cursor].value
                    if numbers[position] < 0 {
                        numbers[position] = model
                        filled.append((section.key, position))
                    } else if numbers[position] == model {
                        report.confirmed += 1
                    } else {
                        numbers[position] = NumberSet.unknown
                        report.disputed += 1
                    }
                }
                line[section.key] = numbers
            }
            // 补完之后整注还得合规，否则刚补的那几位全部退回问号
            let sound = ticket.game.sections.allSatisfy { ordered(line[$0.key], section: $0) }
            if sound {
                report.filled += filled.count
            } else {
                for (key, position) in filled { line[key][position] = NumberSet.unknown }
            }
            ticket.lines[index] = line
        case .zone(let key):
            guard let section = ticket.game.sections.first(where: { $0.key == key }),
                  values.allSatisfy({ $0.confidence >= threshold }) else { return }
            let model = values.map(\.value)
            let known = ticket.selections[key]?.selected ?? []
            if known == model {
                report.confirmed += model.count
            } else if known.count < section.count {
                // Vision 这一行没读全（真机上「前区」整行丢过）：用模型读到的
                var selection = ticket.selections[key] ?? SectionSelection()
                selection.selected = model
                ticket.selections[key] = selection
                report.filled += model.count
            } else {
                report.disputed += 1
                let text = model.map { String(format: "%02d", $0) }.joined(separator: " ")
                ticket.warnings.append("\(section.label)这一行两种读法不一致，另一种读到的是 \(text)，请对照票面核对。")
            }
        }
    }

    /// 问号的个数变了，那句「有 N 位号码没认出来」跟着改。
    static func refreshWarnings(_ ticket: inout ScannedTicket) {
        ticket.warnings.removeAll { $0.contains("位号码没认出来") || $0.contains("那一块没读全") }
        if ticket.unknownCount > 0 {
            ticket.warnings.append("有 \(ticket.unknownCount) 位号码没认出来，点那颗问号球补一下")
        }
        if ticket.packageBlockMissing {
            ticket.warnings.append("套餐票下面「前区 / 后区」那一块没读全，补上之后才能导入")
        }
    }
}
