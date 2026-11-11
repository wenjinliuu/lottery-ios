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
            var text = rebuilt ? "模型读行：\(read) 行号码全部读成、注数和票面合计对得上，按模型读到的行重建"
                               : "模型读行：\(expected) 行号码读成 \(read) 行"
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
        guard ticket.play == .single else { return report }
        if let rebuilt = rebuild(&ticket, rows: rows) { return rebuilt }
        var slots: [Slot] = ticket.lines.indices.filter { !ticket.lines[$0].isEmpty }.map { .line($0) }
        if ticket.isPackage { slots += ticket.game.sections.map { .zone($0.key) } }
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

    // MARK: - 以模型读到的行为准

    /// 模型自己读出来的整张票：每一注在号码区的第几行、读到了什么；套餐票下面那块的两个区。
    struct Skeleton {
        var rows: [Int] = []
        var lines: [[Value]] = []
        var zones: [SectionKey: [Value]] = [:]
    }

    /// 只凭模型读到的行，按这个彩种一行号码该有的样子，把整张票搭出来。只管体彩的四种。
    ///
    /// 一行号码「该有的样子」很死：大乐透 14 位、排列5 五位、排列3 三位、七星彩 7 或 8 位；
    /// 套餐票下面是「前区」「后区」各一行偶数位。`GlyphRows.readLine` 要求个数正好，
    /// 多一位少一位都不算，所以这里搭出来的每一行都是完整的一行。
    static func skeleton(game: GameKey, rows: [[GlyphRows.Token]]) -> Skeleton? {
        let sections = game.sections
        var out = Skeleton()
        for (index, tokens) in rows.enumerated() {
            var line: [Value]?
            switch game {
            case .dlt:
                if let found = GlyphRows.readLine(tokens, count: 14) {
                    line = numbers(found, parts: [(sections[0], 5), (sections[1], 2)])
                }
            case .pl3, .pl5:
                if let found = GlyphRows.readLine(tokens, count: sections[0].count) { line = found.map(single) }
            case .qxc:
                if let seven = GlyphRows.readLine(tokens, count: 7) {
                    line = seven.map(single)
                } else if let eight = GlyphRows.readLine(tokens, count: 8), eight[6].digit == 1 {
                    line = eight.prefix(6).map(single)
                        + [Value(value: 10 + eight[7].digit, confidence: min(eight[6].confidence, eight[7].confidence))]
                }
            default:
                return nil
            }
            if let line, sound(line, sections: sections) {
                out.rows.append(index)
                out.lines.append(line)
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

    /// 一注的每个区都在值域里、两位数的区升序不重复。
    private static func sound(_ line: [Value], sections: [GameSection]) -> Bool {
        var cursor = 0
        for section in sections {
            guard cursor + section.count <= line.count else { return false }
            guard ordered(line[cursor..<cursor + section.count].map(\.value), section: section) else { return false }
            cursor += section.count
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
              let skeleton = skeleton(game: game, rows: rows) else { return nil }
        // 排列3 每一注还带着自己的玩法（组三 / 组六），注数变了就对不上了
        if !ticket.lineModes.isEmpty, ticket.lineModes.count != skeleton.lines.count { return nil }
        let sections = game.sections
        var blockUnits = 0
        if !skeleton.zones.isEmpty {
            guard let front = skeleton.zones[sections[0].key], let back = skeleton.zones[sections[1].key] else { return nil }
            blockUnits = combinations(front.count, sections[0].count) * combinations(back.count, sections[1].count)
        }
        let units = Double((skeleton.lines.count + blockUnits) * max(ticket.multiple, 1) * max(ticket.periods, 1))
        let prices: [Double] = game == .dlt ? [2, 3] : [2]
        guard prices.contains(where: { abs(units * $0 - total) < 0.01 }) else { return nil }

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
            let vision = visionAt[row]
            var numbers = NumberSet()
            var cursor = 0
            for section in sections {
                var values: [Int] = []
                for _ in 0..<section.count {
                    let model = line[cursor]
                    let seen = vision.flatMap { cursor < $0.count ? $0[cursor] : nil } ?? NumberSet.unknown
                    cursor += 1
                    let sure = model.confidence >= threshold
                    if seen < 0 {
                        values.append(sure ? model.value : NumberSet.unknown)
                        if sure { report.filled += 1 }
                    } else if !sure {
                        values.append(seen)
                    } else if seen == model.value {
                        values.append(seen)
                        report.confirmed += 1
                    } else {
                        values.append(NumberSet.unknown)
                        report.disputed += 1
                    }
                }
                // 拿 Vision 的值顶上之后不合规了：这一区里 Vision 顶上的那几位退回问号
                if !ordered(values, section: section) {
                    for position in values.indices where line[cursor - section.count + position].confidence < threshold {
                        values[position] = NumberSet.unknown
                    }
                }
                numbers[section.key] = values
            }
            lines.append(numbers)
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
