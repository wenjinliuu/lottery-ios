import Foundation

/// 票面上的玩法。
enum ScanPlay: String, Hashable, Sendable {
    case single     // 单式：一行一注
    case system     // 复式
    case dantuo     // 胆拖

    var label: String {
        switch self {
        case .single: "单式"
        case .system: "复式"
        case .dantuo: "胆拖"
        }
    }

    var entryMode: EntryMode {
        switch self {
        case .single: .manual
        case .system: .system
        case .dantuo: .dantuo
        }
    }
}

/// 一张识别出来的纸质彩票。
///
/// 注意这是**一整张票**，不是一注 —— 早期版本把每一注当成一个
/// `ScannedTicket`，复式和胆拖就没法表达了：一张 7+2 的复式票上只印两行号码，
/// 展开才是 14 注，硬要拆成 14 个「识别结果」既不像票面也没法让用户改。
struct ScannedTicket: Identifiable, Hashable {
    var id = UUID()
    var game: GameKey
    var play: ScanPlay = .single
    /// 复式 / 胆拖的选号，键名和录入页完全一致，可以直接喂给 `TicketBuilder.expand`。
    var selections: [SectionKey: SectionSelection] = [:]
    /// 单式票的每一注。
    var lines: [NumberSet] = []
    var multiple: Int = 1
    var addOn: Bool = false
    /// 追加多期：同一组号码往后打 N 期。票面写「3期」，合计是 N 期的总额。
    var periods: Int = 1
    var issue: String = ""
    var drawDate: String = ""
    /// 票面印的合计金额，用来和展开注数交叉验证。
    var totalAmount: Double?
    var warnings: [String] = []

    /// 单注价格。大乐透追加 3 元，其余 2 元。
    var unitPrice: Double { game.unitPrice(addOn: addOn) }

    /// 展开成一注一注。
    var expandedLines: [NumberSet] {
        switch play {
        case .single:
            return lines
        case .system, .dantuo:
            let playMode = game == .dlt ? (addOn ? "add" : "normal") : game.defaultPlayMode
            let tickets = TicketBuilder.expand(game: game, selections: selections,
                                              mode: play.entryMode, playMode: playMode, addOn: addOn)
            return (tickets ?? []).map(\.numbers)
        }
    }

    var count: Int { expandedLines.count }

    /// 单期金额。票面合计是 `periods` 期的总和。
    var costPerPeriod: Double { Double(count) * unitPrice * Double(multiple) }
    var totalCost: Double { costPerPeriod * Double(periods) }

    var isUsable: Bool { count > 0 }
}

struct ScanResult {
    var tickets: [ScannedTicket] = []
    /// 原始识别文本，复核页可以展开查看。
    var rawText: String = ""
    var warnings: [String] = []

    var isImportable: Bool { tickets.contains { $0.isUsable } }
}

/// 票面文本解析。
///
/// 这一版从「按位置猜」改成「按标签读」。真实票面上每一行号码前面都印着
/// 红单 / 红复 / 红胆 / 红拖 / 蓝单 / 蓝复 / 前区 / 前区胆 / 前区拖 /
/// 后区胆 / 后区拖 —— 这些标签就是最可靠的信号，比数一行有几个两位数稳得多，
/// 而且是识别复式和胆拖的**唯一**办法。
enum TicketTextParser {

    // MARK: - 文本归一

    static func normalize(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r", with: "\n")
        let replacements: [(String, String)] = [
            ("[：﹕]", ":"), ("[＋﹢]", "+"), ("[—–−﹣]", "-"),
            ("[（]", "("), ("[）]", ")"), ("[，,]", " "),
            ("[\t\u{000B}\u{000C}]+", " "), ("\n{2,}", "\n")
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 热敏票常见的字母/数字混淆。
    private static let confusion: [Character: Int] = [
        "O": 0, "o": 0, "Q": 0, "q": 0, "D": 0, "d": 0,
        "I": 1, "i": 1, "l": 1, "|": 1, "!": 1,
        "Z": 2, "z": 2, "S": 5, "s": 5, "G": 6, "g": 6, "B": 8, "b": 8
    ]

    static func digitValue(_ character: Character) -> Int? {
        character.wholeNumberValue.flatMap { (0...9).contains($0) ? $0 : nil } ?? confusion[character]
    }

    // MARK: - 号码抽取

    /// 从一段文本里读出一串号码。
    ///
    /// **不能**无脑按两位一组切。样票里的蓝球复式印的是
    /// `蓝复: 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16` —— 前九个是**一位数**。
    /// 旧的实现要求每段至少两位数字才成一个号，这十六个蓝球一个都读不出来。
    ///
    /// 现在按空白切成 token：1–2 位直接当一个号；3 位以上说明热敏票把号码粘在
    /// 一起了（`101112`），再按两位一组拆开。最后统一用取值范围过滤。
    static func numbers(in text: String, range: ClosedRange<Int>) -> [Int] {
        var results: [Int] = []
        for token in digitRuns(text) {
            if token.count <= 2 {
                let value = token.reduce(0) { $0 * 10 + $1 }
                if range.contains(value) { results.append(value) }
            } else {
                var index = 0
                while index + 1 < token.count {
                    let value = token[index] * 10 + token[index + 1]
                    if range.contains(value) { results.append(value) }
                    index += 2
                }
            }
        }
        return results
    }

    /// 把文本切成一段段连续的「数字」（含易混字母）。
    private static func digitRuns(_ text: String) -> [[Int]] {
        var runs: [[Int]] = []
        var buffer: [Int] = []
        for character in text {
            if let value = digitValue(character) {
                buffer.append(value)
            } else {
                if !buffer.isEmpty { runs.append(buffer); buffer = [] }
            }
        }
        if !buffer.isEmpty { runs.append(buffer) }
        return runs
    }

    /// 一串数字最长能有几位还算「一排号码」。
    ///
    /// 真实的号码行是空格分开的一位或两位数，即使热敏票把相邻两个号糊在一起
    /// 也就四位。再长就不是号码了 —— 机号 `32030192`、条码、销售期流水号
    /// 都是这种一长串。这个上限是把它们挡在外面的关键：`32030192` 按两位一组
    /// 拆出来是 32、03、01，全都落在红球的 1–33 里，光靠取值范围根本拦不住。
    private static let maximumDigitRun = 4

    /// 这一行是不是「只有号码」——用来判断它是上一行标签的续行。
    ///
    /// 样票里 `蓝复` 和 `前区拖` 的号码经常排不下，第二行**没有标签**，
    /// 只有一排号码。但票尾的 `028期开奖号码:02 06 09 17 25 28+15` 同样是
    /// 一行号码，绝不能当成续行 —— 所以要求整行除了数字和空格之外什么都没有，
    /// 并且没有任何一串数字长得不像号码（见 `maximumDigitRun`）。
    static func isNumberOnlyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        var sawDigit = false
        for character in trimmed {
            if character.isWhitespace { continue }
            if character.isNumber { sawDigit = true; continue }
            return false
        }
        guard sawDigit else { return false }
        return digitRuns(trimmed).allSatisfy { $0.count <= maximumDigitRun }
    }

    static func isAscendingUnique(_ values: [Int]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
    }

    // MARK: - 标签

    /// 票面号码行的标签。
    private struct ZoneLabel {
        let key: SectionKey
        /// 胆码行。
        let isDan: Bool
        /// 拖码行 / 复式行 / 单式行 —— 都并进 `selected`。
        let isMultipleMark: Bool
    }

    /// `红单 / 红复 / 红胆 / 红拖 / 蓝单 / 蓝复 / 前区 / 前区胆 / 前区拖 / 后区 / 后区胆 / 后区拖`
    private static func zoneLabel(_ line: String, game: GameKey) -> (label: ZoneLabel, rest: String)? {
        let patterns: [(String, SectionKey)] = game == .ssq
            ? [("^\\s*红\\s*([单复胆拖])?\\s*[:：]?", .red), ("^\\s*蓝\\s*([单复胆拖])?\\s*[:：]?", .blue)]
            : [("^\\s*前\\s*区\\s*([胆拖])?\\s*[:：]?", .front), ("^\\s*后\\s*区\\s*([胆拖])?\\s*[:：]?", .back)]
        for (pattern, key) in patterns {
            guard let match = firstMatch(in: line, pattern: pattern), match.length > 0 else { continue }
            let mark = match.groups.first ?? ""
            let rest = String((line as NSString).substring(from: match.range.location + match.range.length))
            return (ZoneLabel(key: key, isDan: mark == "胆", isMultipleMark: mark == "复"), rest)
        }
        return nil
    }

    // MARK: - 单式行

    /// `A.04 08 14 24 26 29-03 (3)` 这种一行一注的单式行。
    private static func singleLine(_ line: String, game: GameKey) -> (numbers: NumberSet, multiple: Int?)? {
        // 行首的 A–E 编号和行尾括号里的倍数都不是号码，先摘掉
        let multiple = lineMultiple(line)
        var body = line.replacingOccurrences(of: "\\(\\s*[-—0-9OQDIloq|!]{1,3}\\s*\\)\\s*$",
                                             with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: "^\\s*[A-Ea-e]\\s*[.·:]\\s*", with: "", options: .regularExpression)
        // 空注：`D.-- -- -- -- -- ----  (-)`
        guard body.contains(where: { $0.isNumber }) else { return nil }

        let sections = game.sections
        guard sections.count == 2 else { return nil }
        let (firstSection, secondSection) = (sections[0], sections[1])

        // 双色球用 `-` 分红蓝，大乐透用 `+` 分前后区；分隔符被吃掉时按个数拆
        let separators: Set<Character> = game == .ssq ? ["-"] : ["+", "*"]
        var head = body
        var tail = ""
        if let index = body.firstIndex(where: { separators.contains($0) }), index != body.startIndex {
            head = String(body[body.startIndex..<index])
            tail = String(body[body.index(after: index)...])
        }

        var first = numbers(in: head, range: firstSection.range)
        var second = numbers(in: tail, range: secondSection.range)
        if tail.isEmpty {
            let all = numbers(in: body, range: 1...Swift.max(firstSection.range.upperBound, secondSection.range.upperBound))
            guard all.count == firstSection.count + secondSection.count else { return nil }
            first = Array(all.prefix(firstSection.count))
            second = Array(all.suffix(secondSection.count))
        }

        guard first.count == firstSection.count, second.count == secondSection.count,
              first.allSatisfy(firstSection.range.contains),
              second.allSatisfy(secondSection.range.contains),
              isAscendingUnique(first) else { return nil }

        return (NumberSet([firstSection.key: first, secondSection.key: second]), multiple)
    }

    private static func lineMultiple(_ line: String) -> Int? {
        guard let match = firstMatch(in: line, pattern: "\\(\\s*([0-9OQDIloq|!]{1,2})\\s*\\)"),
              let text = match.groups.first else { return nil }
        return intValue(text)
    }

    private static func intValue(_ text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.compactMap(digitValue)
        guard !digits.isEmpty else { return nil }
        let value = digits.reduce(0) { $0 * 10 + $1 }
        return value > 0 ? value : nil
    }

    // MARK: - 单张票

    static func parseTicket(_ block: String) -> ScannedTicket? {
        let lines = normalize(block)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let game = detectGame(block) else { return nil }

        var ticket = ScannedTicket(game: game)
        ticket.play = detectPlay(block)

        var selections: [SectionKey: SectionSelection] = [:]
        var singleLines: [NumberSet] = []
        var lineMultiples: [Int] = []
        /// 上一行的标签，用来接住没有标签的续行。
        var openLabel: (key: SectionKey, isDan: Bool)?

        for line in lines {
            guard !line.isEmpty else { openLabel = nil; continue }

            if let (label, rest) = zoneLabel(line, game: game) {
                let section = game.sections.first { $0.key == label.key }
                let range = section?.range ?? 1...99
                let values = numbers(in: rest, range: range)
                append(values, to: &selections, key: label.key, isDan: label.isDan)
                // 「后区胆」那一行在票面上可能是空的（样票里就有），
                // 但它仍然占着标签位，下一行的号码属于「后区拖」而不是它。
                openLabel = values.isEmpty ? nil : (label.key, label.isDan)
                continue
            }

            if let openLabel, isNumberOnlyLine(line) {
                let section = game.sections.first { $0.key == openLabel.key }
                let values = numbers(in: line, range: section?.range ?? 1...99)
                append(values, to: &selections, key: openLabel.key, isDan: openLabel.isDan)
                continue
            }
            openLabel = nil

            // 没有标签的票是单式票，按一行一注读
            if ticket.play == .single, let parsed = singleLine(line, game: game) {
                singleLines.append(parsed.numbers)
                if let multiple = parsed.multiple { lineMultiples.append(multiple) }
            }
        }

        ticket.selections = selections
        ticket.lines = dedupe(singleLines)

        // 标签行读到号码，但玩法没写「复式/胆拖」——按选号个数反推
        if !selections.isEmpty {
            if ticket.play == .single { ticket.play = inferPlay(game: game, selections: selections) }
            ticket.lines = []
        } else if ticket.play != .single, singleLines.isEmpty {
            return nil
        } else {
            ticket.play = .single
        }

        ticket.issue = extractIssue(block, game: game)
        ticket.drawDate = extractDrawDate(block)
        ticket.totalAmount = extractTotal(block)
        ticket.multiple = extractMultiple(block) ?? lineMultiples.first ?? 1
        ticket.addOn = detectAddOn(block)
        ticket.periods = extractPeriods(block)
        return ticket.count > 0 || !selections.isEmpty ? ticket : nil
    }

    private static func append(_ values: [Int],
                               to selections: inout [SectionKey: SectionSelection],
                               key: SectionKey,
                               isDan: Bool) {
        guard !values.isEmpty else { return }
        var selection = selections[key] ?? SectionSelection()
        for value in values where !selection.selected.contains(value) {
            selection.selected.append(value)
        }
        if isDan {
            for value in values where !selection.dan.contains(value) {
                selection.dan.append(value)
            }
        }
        selection.selected.sort()
        selection.dan.sort()
        selections[key] = selection
    }

    /// 玩法没印清楚时按选号个数反推：有胆码就是胆拖，某个区多选了就是复式。
    private static func inferPlay(game: GameKey, selections: [SectionKey: SectionSelection]) -> ScanPlay {
        if selections.values.contains(where: { !$0.dan.isEmpty }) { return .dantuo }
        for section in game.sections {
            if (selections[section.key]?.selected.count ?? 0) > section.count { return .system }
        }
        return .single
    }

    private static func dedupe(_ lines: [NumberSet]) -> [NumberSet] {
        var seen = Set<NumberSet>()
        return lines.filter { seen.insert($0).inserted }
    }

    // MARK: - 票面信息

    static func detectGame(_ text: String) -> GameKey? {
        if text.range(of: "双色球|福利彩|WELFARE", options: [.regularExpression, .caseInsensitive]) != nil { return .ssq }
        if text.range(of: "大乐透|体育彩票|体彩|LOTTO|SPORT", options: [.regularExpression, .caseInsensitive]) != nil { return .dlt }
        // 标签本身也能定彩种
        if text.range(of: "前区|后区", options: .regularExpression) != nil { return .dlt }
        if text.range(of: "红[单复胆拖]|蓝[单复胆拖]", options: .regularExpression) != nil { return .ssq }
        return nil
    }

    static func detectPlay(_ text: String) -> ScanPlay {
        if text.contains("胆拖") || text.range(of: "红胆|前区胆|后区胆", options: .regularExpression) != nil { return .dantuo }
        if text.contains("复式") || text.range(of: "红复|蓝复", options: .regularExpression) != nil { return .system }
        return .single
    }

    /// 追加。
    ///
    /// 票面上的「追加」两个字未必印得清楚，但**单价一定是 3 元**（基本 2 元 +
    /// 追加 1 元），所以 `TicketScanReview` 还会拿合计金额再校一次。
    static func detectAddOn(_ text: String) -> Bool {
        text.range(of: "追加", options: .literal) != nil
    }

    /// 倍数。`倍数:3` 和 `3倍` 两种写法都有。
    static func extractMultiple(_ text: String) -> Int? {
        if let match = firstMatch(in: text, pattern: "倍\\s*数\\s*[:：]?\\s*([0-9OQDIloq|!]{1,2})") {
            return intValue(match.groups.first)
        }
        if let match = firstMatch(in: text, pattern: "([0-9OQDIloq|!]{1,2})\\s*倍") {
            return intValue(match.groups.first)
        }
        return nil
    }

    /// 追加多期：同一组号码连打 N 期，合计是 N 期总额。
    ///
    /// 只在写着玩法/倍数的那一行找 `N期`，否则「开奖期」「第26005期」
    /// 「028期开奖号码」里的「期」全都会被误当成期数。
    static func extractPeriods(_ text: String) -> Int {
        for line in normalize(text).split(separator: "\n").map(String.init) {
            guard line.range(of: "倍|复式票|胆拖票|单式票|追加", options: .regularExpression) != nil else { continue }
            guard let match = firstMatch(in: line, pattern: "(?<![第0-9])([0-9]{1,2})\\s*期"),
                  let value = intValue(match.groups.first), (2...20).contains(value) else { continue }
            return value
        }
        return 1
    }

    /// 期号：福彩 7 位（2026029），体彩 5 位（26005）。
    static func extractIssue(_ text: String, game: GameKey) -> String {
        let lines = normalize(text).split(separator: "\n").map(String.init)
        if game == .ssq {
            for line in lines {
                // 「销售期:2026029-2470」也会命中，但它和开奖期是同一个号，没有影响
                if let match = firstMatch(in: line, pattern: "开奖期\\D{0,4}(20\\d{5})"),
                   let value = match.groups.first { return value }
            }
            for line in lines where !line.contains("开奖号码") {
                if let match = firstMatch(in: line, pattern: "(20\\d{5})"),
                   let value = match.groups.first { return value }
            }
            return ""
        }
        for line in lines {
            if let match = firstMatch(in: line, pattern: "第\\s*(2\\d{4})\\s*期"),
               let value = match.groups.first { return value }
        }
        for line in lines {
            if let match = firstMatch(in: line, pattern: "(?:^|\\D)(2\\d{4})\\s*期"),
               let value = match.groups.first { return value }
        }
        return ""
    }

    /// 票面日期。带时分秒的是出票时间，不带的才是开奖日。
    static func extractDrawDate(_ text: String) -> String {
        let source = normalize(text)
        var plain: [String] = []
        var timed: [String] = []
        for match in matches(in: source, pattern: "(20\\d{2})\\D{1,4}(\\d{1,2})\\D{1,4}(\\d{1,2})\\s*日?") {
            if let iso = isoDate(match.groups) { plain.append(iso) }
        }
        for match in matches(in: source, pattern: "(?:^|\\D)(2\\d)[-/]([01]?\\d)[-/]([0-3]?\\d)(?:\\s+([0-2]?\\d:[0-5]\\d:[0-5]\\d))?") {
            var groups = match.groups
            guard groups.count >= 3 else { continue }
            groups[0] = "20" + groups[0]
            guard let iso = isoDate(Array(groups.prefix(3))) else { continue }
            if groups.count >= 4 && !groups[3].isEmpty { timed.append(iso) } else { plain.append(iso) }
        }
        let limit = Calendar.current.component(.year, from: Date()) + 2
        if let candidate = plain.first(where: { Int($0.prefix(4)).map { $0 <= limit } ?? false }) {
            return candidate
        }
        return plain.first ?? timed.first ?? ""
    }

    private static func isoDate(_ groups: [String]) -> String? {
        guard groups.count >= 3,
              let year = Int(groups[0]), let month = Int(groups[1]), let day = Int(groups[2]),
              (2020...2099).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func extractTotal(_ text: String) -> Double? {
        for line in normalize(text).split(separator: "\n").map(String.init) {
            if let match = firstMatch(in: line, pattern: "(?:合\\s*计|共\\s*计|总\\s*计)\\D{0,4}(\\d{1,6})(?:\\.\\d{1,2})?\\s*元"),
               let value = match.groups.first.flatMap(Double.init) { return value }
            // `￥:32.00元`
            if let match = firstMatch(in: line, pattern: "[￥¥]\\s*[:：]?\\s*(\\d{1,6})(?:\\.\\d{1,2})?\\s*元?"),
               let value = match.groups.first.flatMap(Double.init) { return value }
        }
        return nil
    }

    // MARK: - 多张票

    /// 一张照片里可能有好几张票。文本已经按版面切好块时直接逐块解析；
    /// 没切好时按票头（玩法 / 中国福利彩票 / 超级大乐透）再切一次。
    static func splitBlocks(_ text: String) -> [String] {
        let lines = normalize(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [[String]] = []
        for line in lines {
            let isHeader = line.range(of: "玩法\\s*[:：]|中国福利彩票|超级大乐透|CHINA WELFARE|体彩",
                                      options: [.regularExpression, .caseInsensitive]) != nil
            if isHeader || blocks.isEmpty {
                blocks.append([line])
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks.map { $0.joined(separator: "\n") }.filter { $0.contains(where: \.isNumber) }
    }

    // MARK: - 总入口

    /// 版面已经切好的多块文本。扫描器用几何方式分出每张票之后走这条路。
    static func parse(blocks: [String]) -> ScanResult {
        var result = ScanResult()
        result.rawText = blocks.joined(separator: "\n\n———\n\n")
        for block in blocks {
            // 每一块自己可能还印着不止一张票（同一张纸上连着打的）
            let pieces = splitBlocks(block)
            let candidates = pieces.count > 1 ? pieces : [block]
            for piece in candidates {
                if var ticket = parseTicket(piece) {
                    ticket.warnings = validate(ticket)
                    result.tickets.append(ticket)
                }
            }
        }
        result.warnings = summarize(result.tickets)
        return result
    }

    static func parse(_ rawText: String) -> ScanResult {
        parse(blocks: splitBlocks(rawText))
    }

    /// 用票面合计金额反查注数。这是最有价值的一道校验 ——
    /// 复式和胆拖的注数是算出来的，只要少读或多读一个号，注数就会差很多，
    /// 而合计金额是票面上白纸黑字印着的。
    static func validate(_ ticket: ScannedTicket) -> [String] {
        var warnings: [String] = []
        if ticket.count == 0 {
            warnings.append("这张票没读出有效号码，请手动补。")
        }
        if ticket.issue.isEmpty {
            warnings.append("没识别到期号，请点期号那一行从开奖日历里选。")
        }
        guard let total = ticket.totalAmount, ticket.count > 0 else { return warnings }

        if abs(ticket.totalCost - total) < 0.5 { return warnings }

        // 大乐透追加是 3 元一注。票面上「追加」两个字经常糊掉，
        // 但只要合计除以（注数 × 倍数 × 期数）等于 3，它就一定是追加票。
        if ticket.game == .dlt {
            let units = Double(ticket.count * ticket.multiple * ticket.periods)
            if units > 0 {
                let unit = total / units
                if abs(unit - 3) < 0.01 && !ticket.addOn {
                    warnings.append("合计 \(MoneyText.format(total)) 折算下来是 3 元一注，这应该是**追加**票，已自动勾上。")
                    return warnings
                }
                if abs(unit - 2) < 0.01 && ticket.addOn {
                    warnings.append("合计 \(MoneyText.format(total)) 折算下来是 2 元一注，这不是追加票，已自动取消。")
                    return warnings
                }
            }
        }
        warnings.append("票面合计 \(MoneyText.format(total))，按识别结果算是 \(MoneyText.format(ticket.totalCost))（\(ticket.count) 注 × \(ticket.multiple) 倍\(ticket.periods > 1 ? " × \(ticket.periods) 期" : "")），请核对号码。")
        return warnings
    }

    /// 校验发现单价对不上时，把追加标志纠正过来。
    static func reconcileAddOn(_ ticket: inout ScannedTicket) {
        guard ticket.game == .dlt, let total = ticket.totalAmount, ticket.count > 0 else { return }
        let units = Double(ticket.count * ticket.multiple * ticket.periods)
        guard units > 0 else { return }
        let unit = total / units
        if abs(unit - 3) < 0.01 { ticket.addOn = true }
        else if abs(unit - 2) < 0.01 { ticket.addOn = false }
    }

    private static func summarize(_ tickets: [ScannedTicket]) -> [String] {
        var warnings: [String] = []
        if tickets.isEmpty {
            warnings.append("没认出彩票。目前支持双色球和大乐透的单式、复式、胆拖票。")
        } else if tickets.count > 1 {
            warnings.append("这张照片里认出了 \(tickets.count) 张票，请逐张核对。")
        }
        return warnings
    }

    // MARK: - 正则辅助

    struct RegexMatch {
        var range: NSRange
        var groups: [String]
        var length: Int
    }

    static func firstMatch(in text: String, pattern: String) -> RegexMatch? {
        matches(in: text, pattern: pattern).first
    }

    static func matches(in text: String, pattern: String) -> [RegexMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map { match in
            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? "" : nsText.substring(with: range))
            }
            return RegexMatch(range: match.range, groups: groups, length: match.range.length)
        }
    }
}
