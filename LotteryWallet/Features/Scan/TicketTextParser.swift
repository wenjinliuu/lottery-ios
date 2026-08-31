import Foundation

/// 一张票的识别结果。
struct ScannedTicket: Identifiable, Hashable {
    var id = UUID()
    var numbers = NumberSet()
    /// 该注单独标注的倍数，没识别到就用整票倍数。
    var multiple: Int?
}

struct ScanResult {
    var game: GameKey?
    var issue: String = ""
    var drawDate: String = ""
    var tickets: [ScannedTicket] = []
    var multiple: Int = 1
    var addOn: Bool = false
    /// 票面上印的合计金额，用于和解析出的注数交叉验证。
    var totalAmount: Double?
    /// 原始识别文本，复核页可以展开查看。
    var rawText: String = ""

    var warnings: [String] = []

    var isImportable: Bool {
        game != nil && !tickets.isEmpty && issue.isEmpty == false
    }
}

/// 票面文本解析。规则逐条移植自 web 版 `web/ocr.js`，
/// 差别只在于文字识别换成了 Apple Vision，不再需要下载 OCR 模型。
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

    private static func digitValue(_ character: Character) -> Int? {
        character.wholeNumberValue.flatMap { (0...9).contains($0) ? $0 : nil } ?? confusion[character]
    }

    /// 把一段文本里的两位数字 token 抽出来。
    static func numberTokens(_ text: String) -> [Int] {
        var results: [Int] = []
        var buffer: [Int] = []
        for character in text {
            if let value = digitValue(character) {
                buffer.append(value)
            } else {
                results.append(contentsOf: pairs(buffer))
                buffer = []
            }
        }
        results.append(contentsOf: pairs(buffer))
        return results
    }

    /// 连续数字按两位一组切分，奇数位丢掉最后一位。
    private static func pairs(_ digits: [Int]) -> [Int] {
        guard digits.count >= 2 else { return [] }
        var values: [Int] = []
        var index = 0
        while index + 1 < digits.count {
            values.append(digits[index] * 10 + digits[index + 1])
            index += 2
        }
        return values
    }

    /// 号码粘连时的兜底：在数字串里搜一组递增、不越界的号码。
    /// 与 web 版 `extractCompactNumberSequence` 同一套评分逻辑。
    static func compactSequence(_ text: String, count: Int, max: Int) -> [Int] {
        var digits: [(value: Int, position: Int)] = []
        for (offset, character) in text.enumerated() {
            if let value = digitValue(character) { digits.append((value, offset)) }
        }
        guard digits.count >= count * 2 else { return [] }

        var best: (values: [Int], score: Double)?
        func search(_ cursor: Int, _ numbers: [Int], _ last: Int, _ score: Double) {
            if numbers.count == count {
                let finalScore = score + Double(Swift.max(0, digits.count - cursor)) * 0.18
                if best == nil || finalScore <= best!.score { best = (numbers, finalScore) }
                return
            }
            let needed = (count - numbers.count) * 2
            guard digits.count >= needed else { return }
            var first = cursor
            while first <= digits.count - needed {
                let secondUpper = Swift.min(first + 2, digits.count - needed + 1)
                var second = first + 1
                while second <= secondUpper {
                    let number = digits[first].value * 10 + digits[second].value
                    if number >= 1, number <= max, number > last {
                        let penalty = Double(first - cursor + (second - first - 1))
                        search(second + 1, numbers + [number], number, score + penalty)
                    }
                    second += 1
                }
                first += 1
            }
        }
        search(0, [], 0, 0)
        return best?.values ?? []
    }

    static func isAscendingUnique(_ values: [Int]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
    }

    // MARK: - 双色球

    static func parseSSQ(_ text: String) -> [ScannedTicket] {
        var tickets: [ScannedTicket] = []
        for rawLine in normalize(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var red: [Int] = []
            var blue: Int?

            if let dashIndex = line.firstIndex(of: "-"), dashIndex != line.startIndex {
                let leftSource = String(line[line.startIndex..<dashIndex])
                let rightSource = String(line[line.index(after: dashIndex)...])
                // 热敏票上 "C." 常被连成 "C1"，优先按 A–E 行号拆出首个红球
                if let labeled = firstMatch(in: leftSource, pattern: "^\\s*[A-Ea-e]\\s*[.·:1Il|!]?\\s*([0-9OQDIloq|!ZzSsGgBb]{2})(?=\\s|$)"),
                   let head = numberTokens(labeled.groups.first ?? "").first {
                    let rest = numberTokens(String(leftSource.dropFirst(labeled.length)))
                    red = [head] + rest.prefix(5)
                } else {
                    red = Array(numberTokens(leftSource).suffix(6))
                }
                blue = numberTokens(rightSource).first

                if red.count != 6 || !red.allSatisfy({ (1...33).contains($0) }) || !isAscendingUnique(red) {
                    red = compactSequence(leftSource, count: 6, max: 33)
                }
                if let value = blue, !(1...16).contains(value) {
                    blue = compactSequence(rightSource, count: 1, max: 16).first
                } else if blue == nil {
                    blue = compactSequence(rightSource, count: 1, max: 16).first
                }
            } else if firstMatch(in: line, pattern: "^\\s*[A-Ea-e][.·:\\s]") != nil {
                // 分隔横线漏识别时，A–E 行仍可按 6+1 解析
                let cleaned = line.replacingOccurrences(of: "\\(\\s*[0-9OQDIloq|!]{1,2}\\s*\\)?\\s*$", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "^\\s*[A-Ea-e][.·:\\s]*", with: "", options: .regularExpression)
                let values = numberTokens(cleaned)
                red = Array(values.prefix(6))
                blue = values.count > 6 ? values[6] : nil
            } else {
                continue
            }

            guard red.count == 6, let blueValue = blue,
                  red.allSatisfy({ (1...33).contains($0) }),
                  (1...16).contains(blueValue),
                  isAscendingUnique(red) else { continue }

            var ticket = ScannedTicket(numbers: NumberSet([.red: red, .blue: [blueValue]]))
            ticket.multiple = lineMultiple(line)
            tickets.append(ticket)
        }
        return dedupe(tickets)
    }

    // MARK: - 大乐透

    static func parseDLT(_ text: String) -> [ScannedTicket] {
        var tickets: [ScannedTicket] = []
        for rawLine in normalize(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var front: [Int] = []
            var back: [Int] = []
            var leftSource = ""
            var rightSource = ""

            if let plusIndex = line.firstIndex(where: { $0 == "+" || $0 == "*" }) {
                leftSource = String(line[line.startIndex..<plusIndex])
                rightSource = String(line[line.index(after: plusIndex)...])
                front = Array(numberTokens(leftSource).suffix(5))
                back = Array(numberTokens(rightSource).prefix(2))
            } else {
                // "+" 常被热敏票吃掉，七个两位数仍可稳定按 5+2 拆
                let cleaned = line.replacingOccurrences(of: "\\(\\s*[0-9OQDIloq|!]{1,2}\\s*\\)?\\s*$", with: "", options: .regularExpression)
                let values = numberTokens(cleaned)
                guard values.count == 7 else { continue }
                front = Array(values.prefix(5))
                back = Array(values.suffix(2))
                leftSource = front.map { String(format: "%02d", $0) }.joined(separator: " ")
                rightSource = back.map { String(format: "%02d", $0) }.joined(separator: " ")
            }

            if front.count != 5 || !front.allSatisfy({ (1...35).contains($0) }) || !isAscendingUnique(front) {
                front = compactSequence(leftSource, count: 5, max: 35)
            }
            if back.count != 2 || !back.allSatisfy({ (1...12).contains($0) }) || !isAscendingUnique(back) {
                back = compactSequence(rightSource, count: 2, max: 12)
            }

            guard front.count == 5, back.count == 2,
                  front.allSatisfy({ (1...35).contains($0) }),
                  back.allSatisfy({ (1...12).contains($0) }),
                  isAscendingUnique(front), isAscendingUnique(back) else { continue }

            tickets.append(ScannedTicket(numbers: NumberSet([.front: front, .back: back])))
        }
        return dedupe(tickets)
    }

    private static func lineMultiple(_ line: String) -> Int? {
        guard let match = firstMatch(in: line, pattern: "\\(\\s*([0-9OQDIloq|!]{1,2})"),
              let text = match.groups.first else { return nil }
        let digits = text.compactMap(digitValue)
        guard !digits.isEmpty else { return nil }
        let value = digits.reduce(0) { $0 * 10 + $1 }
        return value > 0 ? value : nil
    }

    private static func dedupe(_ tickets: [ScannedTicket]) -> [ScannedTicket] {
        var seen = Set<String>()
        return tickets.filter { ticket in
            let key = ticket.numbers.values
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue):\($0.value.map(String.init).joined(separator: ","))" }
                .joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    // MARK: - 票面信息

    static func detectGame(_ text: String, ssq: [ScannedTicket], dlt: [ScannedTicket]) -> GameKey? {
        if text.range(of: "双色球|福利彩|WELFARE", options: [.regularExpression, .caseInsensitive]) != nil { return .ssq }
        if text.range(of: "大乐透|体育彩票|体彩|LOTTO|SPORT", options: [.regularExpression, .caseInsensitive]) != nil { return .dlt }
        if !ssq.isEmpty && dlt.isEmpty { return .ssq }
        if !dlt.isEmpty && ssq.isEmpty { return .dlt }
        if ssq.isEmpty && dlt.isEmpty { return nil }
        return ssq.count >= dlt.count ? .ssq : .dlt
    }

    /// 期号：双色球 7 位（如 2026050），大乐透 5 位（如 26050）。
    static func extractIssue(_ text: String, game: GameKey) -> String {
        let lines = normalize(text).split(separator: "\n").map(String.init)
        if game == .ssq {
            for line in lines {
                if let match = firstMatch(in: line, pattern: "(?:开奖期|开奖|期)\\D{0,8}(20\\d{5})"),
                   let value = match.groups.first { return value }
            }
            return firstMatch(in: text, pattern: "(20\\d{5})")?.groups.first ?? ""
        }
        let head = lines.prefix(Swift.max(8, (lines.count + 1) / 2))
        for line in head {
            if let match = firstMatch(in: line, pattern: "(?:第\\s*)?(2\\d{4})\\s*(?:期|H|84|H8|$)"),
               let value = match.groups.first { return value }
        }
        return ""
    }

    /// 票面日期。带时分秒的是出票时间，不带的才是开奖日。
    static func extractDrawDate(_ text: String) -> String {
        let source = normalize(text)
        var plain: [String] = []
        var timed: [String] = []
        for match in matches(in: source, pattern: "(20\\d{2})\\D{1,4}(\\d{1,2})\\D{1,4}(\\d{1,2})") {
            if let iso = isoDate(match.groups) { plain.append(iso) }
        }
        for match in matches(in: source, pattern: "(?:^|\\D)(2\\d)[-/]([01]?\\d)[-/]([0-3]?\\d)(?:\\s+([0-2]?\\d:[0-5]\\d:[0-5]\\d))?") {
            var groups = match.groups
            guard groups.count >= 3 else { continue }
            groups[0] = "20" + groups[0]
            guard let iso = isoDate(Array(groups.prefix(3))) else { continue }
            if groups.count >= 4 && !groups[3].isEmpty { timed.append(iso) } else { plain.append(iso) }
        }
        // 优先取不带时间、且年份合理的那个作为开奖日
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
            if let match = firstMatch(in: line, pattern: "(?:合计|共计|总计|计)\\D{0,8}(\\d{1,4})\\s*元"),
               let value = match.groups.first.flatMap(Double.init) { return value }
        }
        return firstMatch(in: text, pattern: "(\\d{1,4})\\s*元")?.groups.first.flatMap(Double.init)
    }

    /// 大乐透追加与倍数。
    static func extractDLTMode(_ text: String) -> (addOn: Bool, multiple: Int?) {
        if let match = firstMatch(in: text, pattern: "追加\\s*(?:投注)?\\D{0,5}([0-9OQDIloq|!]{1,2})\\s*[倍信]") {
            return (true, multipleValue(match.groups.first))
        }
        if let match = firstMatch(in: text, pattern: "(?:普通|基本)\\s*(?:投注)?\\D{0,5}([0-9OQDIloq|!]{1,2})\\s*[倍信]") {
            return (false, multipleValue(match.groups.first))
        }
        return (text.contains("追加"), nil)
    }

    private static func multipleValue(_ text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.compactMap(digitValue)
        guard !digits.isEmpty else { return nil }
        let value = digits.reduce(0) { $0 * 10 + $1 }
        return value > 0 ? value : nil
    }

    // MARK: - 总入口

    static func parse(_ rawText: String) -> ScanResult {
        let text = normalize(rawText)
        let ssq = parseSSQ(text)
        let dlt = parseDLT(text)
        var result = ScanResult()
        result.rawText = text
        result.game = detectGame(text, ssq: ssq, dlt: dlt)
        result.tickets = result.game == .ssq ? ssq : (result.game == .dlt ? dlt : [])
        if let game = result.game {
            result.issue = extractIssue(text, game: game)
        }
        result.drawDate = extractDrawDate(text)
        result.totalAmount = extractTotal(text)

        if result.game == .dlt {
            let mode = extractDLTMode(text)
            result.addOn = mode.addOn
            if let multiple = mode.multiple { result.multiple = multiple }
        } else if let first = result.tickets.first?.multiple {
            result.multiple = first
        }

        // 用票面合计金额反查注数，识别漏行时给出提示
        if let total = result.totalAmount, !result.tickets.isEmpty {
            let expected = Double(result.tickets.count) * 2 * Double(result.multiple)
            if abs(expected - total) > 0.5 {
                result.warnings.append("票面合计 \(Int(total)) 元，识别到 \(result.tickets.count) 注 × \(result.multiple) 倍，请核对是否漏识别。")
            }
        }
        if result.game == nil { result.warnings.append("没认出彩种，目前只支持双色球和大乐透单式票。") }
        if result.tickets.isEmpty { result.warnings.append("没识别到号码，可以在复核页手动补录。") }
        if result.issue.isEmpty { result.warnings.append("没识别到期号，请手动填写。") }

        return result
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
