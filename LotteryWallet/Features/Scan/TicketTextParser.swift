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
    /// 每一注自己的玩法，和 `lines` 一一对应。空数组表示整票共用 `playMode`。
    ///
    /// 3D 和排列3 需要它：**一张票上每一注可以是不同玩法**。
    /// 3D 的样票是「组六 / 组六 / 组三 / 单选 / 单选」打在一张纸上；
    /// 排列3 的组选票只印「组选」两个字，具体是组三还是组六由号码自己决定
    /// （有重复就是组三）。这两种情况都**不能拆票** —— 用户手里就是一张票，
    /// 票夹里也该是一张卡片，只是卡片里每一注各自标着自己的玩法。
    var lineModes: [String] = []
    var multiple: Int = 1
    /// 票面印的玩法键。
    ///
    /// 快乐8 是「选几」（`"8"`），3D / 排列3 是直选 / 组三 / 组六。
    /// 这两类彩种同一个彩种下不同玩法的号码个数和奖级完全不同，
    /// 不带上它，一张「快乐8-选八」会被当成默认的选十去核对。
    /// 空字符串表示用彩种默认值。
    var playMode: String = ""
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
    ///
    /// 单式票会过滤掉空号码：「补一注」是先塞一注空的再打开编辑器，
    /// 用户下滑关掉抽屉而不是点取消时，那一注空的会留在票上。
    /// 它既不该算钱，也不该被存成一条没有号码的记录。
    var expandedLines: [NumberSet] {
        switch play {
        case .single:
            return lines.filter { !$0.isEmpty }
        case .system, .dantuo:
            let playMode = game == .dlt ? (addOn ? "add" : "normal")
                                        : (self.playMode.isEmpty ? game.defaultPlayMode : self.playMode)
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

    /// 这一行除了数字（含 OCR 易混字母）和空白之外什么都没有。
    ///
    /// 数字型彩种必须有这道闸。它的一注就是几个 0-9，判据本身太松 ——
    /// 「第 26088期 2026年04月08日开奖」按两位一组拆出来正好是 8、4、8，
    /// 三个都在 0-9 里，于是每张排列3 都会平白多出一注，
    /// 注数和票面合计当然就对不上了。
    ///
    /// 和 `isNumberOnlyLine` 的区别：这里用 `digitValue` 而不是 `isNumber`，
    /// 保留对 O/I/l 这类 OCR 误读的容忍 —— 热敏票上 `05` 被认成 `O5` 很常见。
    static func isBareNumberLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        var sawDigit = false
        for character in trimmed {
            if character.isWhitespace { continue }
            guard digitValue(character) != nil else { return false }
            sawDigit = true
        }
        return sawDigit
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

    /// 行首的注序号。
    ///
    /// 两家的打法不一样：福彩印 `A.` `B.` `C.`，体彩印 **`①` `②` `③`**。
    /// 圈码在 Unicode 里是**带数值的数字字符**（`①` 的 numericValue 就是 1，
    /// 类别是 Other_Number），所以 Swift 的 `wholeNumberValue` 会把它读成 1 ——
    /// `① 12 15 17 24 33` 会变成六个前区号，整行当场被判无效丢掉。
    /// 四张大乐透单式样票就是全军覆没在这一步。
    ///
    /// 这里只摘**明确带分隔符或本身就是圈码**的形式，绝不摘裸的数字：
    /// `11 15 23…` 开头那个 1 一摘，红球就全错了。
    private static let lineIndexPrefix =
        "^\\s*(?:[A-Ea-e]\\s*[.。·:、)]|[①-⑮⒈-⒛]|[(（]\\s*\\d{1,2}\\s*[)）]|\\d{1,2}\\s*[.。、)])\\s*"

    /// `A.04 08 14 24 26 29-03 (3)` / `① 12 15 17 24 33 + 04 12` 这种一行一注的单式行。
    private static func singleLine(_ line: String, game: GameKey) -> (numbers: NumberSet, multiple: Int?)? {
        // 行尾括号里的倍数和行首的注序号都不是号码，先摘掉
        let multiple = lineMultiple(line)
        // 行尾那个倍数括号 OCR 经常只认出半边 —— 真实结果里有
        // `... 63 72 1 )`（丢了左括号）和 `... 23 25(1`（丢了右括号）。
        // 括号必须写成可选，否则那个残缺的 `1` 会被当成一个号码，
        // 号码个数多出一个，整注就被判掉了 —— 用户看到的是「少了一注」。
        //
        // **至少要有一边括号在**。两边都写成可选的话，
        // `A.11 13 14 27 31 33-04` 结尾的 `-04` 会被当成倍数削掉 ——
        // 每一张双色球单式票都要少一个蓝球。
        var body = line.replacingOccurrences(
            of: "(?:[(（]\\s*[-—0-9OQDIloq|!]{1,3}\\s*[)）]?|[-—0-9OQDIloq|!]{1,3}\\s*[)）])\\s*$",
            with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: lineIndexPrefix, with: "", options: .regularExpression)
        // 3D 每一注行首印着自己的玩法：`组六: 1 8 9`。摘掉它，
        // 剩下的才是号码 —— 玩法由 `perLineModes` 单独去读。
        body = body.replacingOccurrences(of: "^\\s*(组六|组三|组选|单选|直选|组6|组3)\\s*[:：]?\\s*",
                                         with: "", options: .regularExpression)
        // 空注：`D.-- -- -- -- -- ----  (-)`
        guard body.contains(where: { $0.isNumber }) else { return nil }

        let sections = game.sections
        if sections.count == 1 {
            return singleZoneLine(body, game: game, section: sections[0], multiple: multiple)
        }
        guard sections.count == 2 else { return nil }
        let (firstSection, secondSection) = (sections[0], sections[1])

        // 数字型的两区票（七星彩：前六位 0-9 + 特别号 0-14）不能按
        // 「分隔符 / 升序 / 不重复」那一套读 —— 它的号码就是可以重复、
        // 也没有顺序，`3 9 5 4 7 7 13` 是完全合法的一注。
        if firstSection.range.lowerBound == 0 {
            return digitLine(body, game: game,
                             first: firstSection, second: secondSection, multiple: multiple)
        }

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

        // 兜底：正则没摘掉的注序号（OCR 把 ① 认成别的写法）会让号码多出一个。
        // 多出来的那个必然在最前面，去掉之后剩下的能成一组合法号就采纳。
        first = trimStray(first, to: firstSection)
        second = trimStray(second, to: secondSection)

        guard first.count == firstSection.count, second.count == secondSection.count,
              first.allSatisfy(firstSection.range.contains),
              second.allSatisfy(secondSection.range.contains),
              isAscendingUnique(first), isAscendingUnique(second) else { return nil }

        return (NumberSet([firstSection.key: first, secondSection.key: second]), multiple)
    }

    /// 给测试用的入口。`singleLine` 本身是私有的，但"哪些行会被当成一注"
    /// 正是最容易出错、也最该被钉住的一件事。
    static func singleLineForTesting(_ line: String, game: GameKey) -> NumberSet? {
        singleLine(line, game: game)?.numbers
    }

    /// 只有一个号码区的彩种：七乐彩 7 个、快乐8 选几就几个、排列3/5 的每一位。
    ///
    /// 和双色球那种两区票的区别在于**没有分隔符可依**，只能靠「读出几个号」
    /// 和玩法声明的个数对上。
    private static func singleZoneLine(_ body: String,
                                       game: GameKey,
                                       section: GameSection,
                                       multiple: Int?) -> (numbers: NumberSet, multiple: Int?)? {
        guard isBareNumberLine(body) else { return nil }
        let values = numbers(in: body, range: section.range)
        guard !values.isEmpty else { return nil }

        if section.range.lowerBound == 0 {
            // 排列3 / 排列5 / 3D：一位一个号，可以重复，顺序就是票面顺序。
            guard values.count == section.count else { return nil }
            return (NumberSet([section.key: values]), multiple)
        }

        // 七乐彩固定 7 个；快乐8 的个数由玩法决定，这里先不卡死 ——
        // 调用方拿到玩法之后会再校一次，卡死了「选八」这种票一注都读不出来。
        let trimmed = trimStray(values, to: section)
        guard isAscendingUnique(trimmed), trimmed.allSatisfy(section.range.contains) else { return nil }
        let acceptable = game == .k8 ? (1...10).contains(trimmed.count) : trimmed.count == section.count
        guard acceptable else { return nil }
        return (NumberSet([section.key: trimmed]), multiple)
    }

    /// 七星彩：前六位各 0-9，第七位 0-14，整行一次读完再按位置分。
    private static func digitLine(_ body: String,
                                  game: GameKey,
                                  first: GameSection,
                                  second: GameSection,
                                  multiple: Int?) -> (numbers: NumberSet, multiple: Int?)? {
        guard isBareNumberLine(body) else { return nil }
        let all = numbers(in: body, range: 0...second.range.upperBound)
        guard all.count == first.count + second.count else { return nil }
        let head = Array(all.prefix(first.count))
        let tail = Array(all.suffix(second.count))
        guard head.allSatisfy(first.range.contains), tail.allSatisfy(second.range.contains) else { return nil }
        return (NumberSet([first.key: head, second.key: tail]), multiple)
    }

    /// 号码正好多出一个时，试着去掉头一个或最后一个，取能成立的那种。
    private static func trimStray(_ values: [Int], to section: GameSection) -> [Int] {
        guard values.count == section.count + 1 else { return values }
        for candidate in [Array(values.dropFirst()), Array(values.dropLast())] {
            if isAscendingUnique(candidate), candidate.allSatisfy(section.range.contains) {
                return candidate
            }
        }
        return values
    }

    /// 行尾括号里的倍数，比如 `(3)`。
    ///
    /// **必须锚在行尾。** 体彩的注序号有时会被打成 `(1)` 放在**行首**，
    /// 不锚定的话第一注的倍数就被读成 1 了。
    private static func lineMultiple(_ line: String) -> Int? {
        guard let match = firstMatch(in: line, pattern: "\\(\\s*([0-9OQDIloq|!]{1,2})\\s*\\)\\s*$"),
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

    /// 一块文本解析出的全部票。
    ///
    /// 就是一张。曾经为了 3D 的混合玩法在这里按玩法拆过票 —— 那是错的：
    /// 用户手里明明是一张彩票，票夹里冒出两三张卡片，和票面对不上，
    /// 金额也要跟着分摊，反而更难核对。现在玩法落到每一注上（`lineModes`），
    /// 一张票还是一张票。
    static func parseTickets(_ block: String) -> [ScannedTicket] {
        guard var ticket = parseTicket(block) else { return [] }
        guard ticket.game == .fc3d || ticket.game == .pl3, ticket.play == .single else {
            return [ticket]
        }
        let modes = perLineModes(block, game: ticket.game)
        guard modes.count == ticket.lines.count else { return [ticket] }
        ticket.lineModes = modes
        // 整票只有一种玩法时顺手也写到票级别上，复核页顶上那一行要用
        if let only = Set(modes).first, Set(modes).count == 1, !only.isEmpty {
            ticket.playMode = only
        }
        return [ticket]
    }

    /// 每一注的玩法。
    ///
    /// 三种来源，优先级从高到低：
    /// 1. **行首自己印着**。福彩 3D 是这样打的：`组六: 1 8 9`。
    /// 2. **票头写着「组选」**。体彩排列3 只印「组选单式票」，不说是组三还是
    ///    组六 —— 因为那是由号码本身决定的，见 `groupKind`。
    /// 3. 退回票头声明的玩法（直选单式票之类）。
    private static func perLineModes(_ block: String, game: GameKey) -> [String] {
        let headerMode = detectPlayMode(game: game, text: block)
        let isGroupPick = block.contains("组选")
        var modes: [String] = []
        for raw in normalize(block).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let parsed = singleLine(line, game: game) else { continue }
            let own = detectPlayMode(game: game, text: line)
            if !own.isEmpty {
                modes.append(own)
            } else if isGroupPick {
                modes.append(groupKind(of: parsed.numbers[.nums3]))
            } else {
                modes.append(headerMode)
            }
        }
        return modes
    }

    /// 组选票是组三还是组六，看号码有没有重复：
    /// 三位里有一对相同就是组三（`0 4 4`），三位都不同就是组六（`0 1 5`）。
    ///
    /// 这一步不能省 —— 两者奖级完全不同，都按「组选」存进去就没法核对。
    private static func groupKind(of digits: [Int]) -> String {
        Set(digits).count == 3 ? "group6" : "group3"
    }

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
            let inferred = ticket.play == .single ? inferPlay(game: game, selections: selections) : ticket.play
            ticket.play = inferred
            if inferred == .single {
                // 每个区都刚好选满，这就是一注单式，只是印成了带标签的样子
                // （`红单:… / 蓝单:…`）。
                //
                // **不能把 lines 清空。** 单式票的号码是从 `lines` 读的，
                // 清掉之后 `expandedLines` 返回空数组，注数变 0，
                // 刚刚读出来的号码全部丢掉。
                var numbers = NumberSet()
                for section in game.sections {
                    numbers[section.key] = (selections[section.key]?.selected ?? []).sorted()
                }
                ticket.lines = numbers.isEmpty ? singleLines : [numbers]
                ticket.selections = [:]
            } else {
                ticket.lines = []
            }
        } else if ticket.play != .single, singleLines.isEmpty {
            return nil
        } else {
            ticket.play = .single
        }

        ticket.issue = extractIssue(block, game: game)
        ticket.drawDate = extractDrawDate(block)
        ticket.totalAmount = extractTotal(block)
        ticket.multiple = extractMultiple(block) ?? lineMultiples.first ?? 1
        ticket.playMode = detectPlayMode(game: game, text: block)
        // 快乐8：玩法说选几，每一注就必须正好几个号。读出来对不上的那几注
        // 多半是把机号或金额当成号码了，宁可丢掉也不要留一注错的。
        if game == .k8, let want = Int(ticket.playMode) {
            ticket.lines = ticket.lines.filter { $0[.nums].count == want }
        }
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
        // **具体彩种名必须排在发行方前面。**
        //
        // 七乐彩、快乐8、3D 的票头上印的同样是「中国福利彩票」，
        // 先匹配发行方的话，这三种票会全部被认成双色球。
        // 体彩那边同理：排列3/5、七星彩的票头都写着「体彩」。
        if text.range(of: "七乐彩|七乐釆", options: .regularExpression) != nil { return .qlc }
        if text.range(of: "快乐8|快乐八|快乐\\s*8", options: .regularExpression) != nil { return .k8 }
        if text.range(of: "七星彩|7星彩|Seven\\s*Stars", options: [.regularExpression, .caseInsensitive]) != nil { return .qxc }
        if text.range(of: "排列\\s*5|排列五|排5", options: .regularExpression) != nil { return .pl5 }
        if text.range(of: "排列\\s*3|排列三|排3", options: .regularExpression) != nil { return .pl3 }
        if text.contains("双色球") { return .ssq }
        if text.range(of: "大乐透|超级大乐透", options: .regularExpression) != nil { return .dlt }
        // 3D 放在双色球之后：「玩法:3D-单式」这种行里没有别的彩种名，
        // 但 `3D` 两个字符太短，摆在最前面容易被别处的噪声命中。
        if text.range(of: "(^|[^0-9A-Za-z])3\\s*[DdＤ]([^0-9A-Za-z]|$)", options: .regularExpression) != nil { return .fc3d }

        // 标签本身也能定彩种
        if text.range(of: "前区|后区", options: .regularExpression) != nil { return .dlt }
        if text.range(of: "红[单复胆拖]|蓝[单复胆拖]", options: .regularExpression) != nil { return .ssq }

        // 都没认出来才退回发行方 —— 这一步只能区分福彩和体彩，
        // 而两家各自的主力彩种是双色球和大乐透，作为兜底是合理的猜测。
        if text.range(of: "福利彩|WELFARE", options: [.regularExpression, .caseInsensitive]) != nil { return .ssq }
        if text.range(of: "体育彩票|体彩|LOTTO|SPORT", options: [.regularExpression, .caseInsensitive]) != nil { return .dlt }
        return nil
    }

    /// 票面印的玩法键。
    ///
    /// 快乐8 的「选八」和 3D 的「组三 / 组六 / 单选」决定了一注有几个号、
    /// 按哪一档奖级算。不读出来的话，一张选八票会被当成默认的选十。
    static func detectPlayMode(game: GameKey, text: String) -> String {
        switch game {
        case .k8:
            // 「快乐8-选八单式」。中文数字和阿拉伯数字都可能印。
            if let match = firstMatch(in: text, pattern: "选\\s*([一二三四五六七八九十1-9]0?)") {
                return k8PlayCount(match.groups.first ?? "").map(String.init) ?? ""
            }
            return ""
        case .fc3d, .pl3:
            if text.contains("组六") || text.contains("组6") { return "group6" }
            if text.contains("组三") || text.contains("组3") { return "group3" }
            // 「组选」要留空：体彩排列3 只印这两个字，具体是组三还是组六
            // 得看号码有没有重复，交给 `perLineModes` 逐注判断。
            // 这一句必须排在「直选」前面 —— 否则「组选单式票」里的"选"字
            // 匹配不到，但将来若有票同时印着两种字样会判错。
            if text.contains("组选") { return "" }
            if text.contains("单选") || text.contains("直选") { return "single" }
            return ""
        default:
            return ""
        }
    }

    private static func k8PlayCount(_ raw: String) -> Int? {
        let table = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                     "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]
        if let value = table[raw] { return value }
        if let value = Int(raw), (1...10).contains(value) { return value }
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
    /// 期号印成 7 位 `YYYYNNN` 的彩种 —— 也就是福彩这一家。
    private static let sevenDigitIssueGames: Set<GameKey> = [.ssq, .qlc, .k8, .fc3d]

    static func extractIssue(_ text: String, game: GameKey) -> String {
        let lines = normalize(text).split(separator: "\n").map(String.init)
        // 福彩四个彩种的期号都是 7 位的 `YYYYNNN`（2026018），
        // 体彩四个是 5 位的 `YYNNN`（26042）。原来只给双色球开了 7 位这条路，
        // 七乐彩、快乐8、3D 全都读不到期号。
        if Self.sevenDigitIssueGames.contains(game) {
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
            // 票头只有在当前这块**已经有号码内容**时才另起一块。
            //
            // 一张票的抬头往往连着好几行都算票头：「中国福利彩票」一行、
            // 「玩法:双色球-单式」又一行。无条件切的话它们会被拆成两块，
            // 而带彩种名的那块因为没有数字被过滤掉，剩下的一块认不出彩种，
            // 整张票就白扫了。
            let currentHasNumbers = blocks.last?.contains { $0.contains(where: \.isNumber) } ?? false
            if blocks.isEmpty || (isHeader && currentHasNumbers) {
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
                for var ticket in parseTickets(piece) {
                    ticket.warnings = validate(ticket)
                    result.tickets.append(ticket)
                }
            }
        }
        result.warnings = summary(for: result.tickets)
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

        // 追加与否已经在 `reconcileAddOn` 里按单价校正过、也告诉用户了，
        // 走到这里还对不上，就是号码真的读错了。
        warnings.append("票面合计 \(MoneyText.format(total))，按识别结果算是 \(MoneyText.format(ticket.totalCost))（\(ticket.count) 注 × \(ticket.multiple) 倍\(ticket.periods > 1 ? " × \(ticket.periods) 期" : "")），请核对号码。")
        return warnings
    }

    /// 用票面合计反推单价，把追加标志纠正过来。返回一句给用户看的说明。
    ///
    /// 大乐透追加是 3 元一注（2 元基本 + 1 元追加）。票面上「追加」两个字
    /// 经常被折痕或兑奖章盖掉，但合计金额是白纸黑字印着的：
    /// 合计 ÷（注数 × 倍数 × 期数）等于 3 就一定是追加票。
    ///
    /// **必须把说明显示出来** —— 这一步会把单注价格从 2 元改成 3 元，
    /// 是记账口径的变化，悄悄改掉的话用户对不上账也不知道是哪一步动的。
    @discardableResult
    static func reconcileAddOn(_ ticket: inout ScannedTicket) -> String? {
        guard ticket.game == .dlt, let total = ticket.totalAmount, ticket.count > 0 else { return nil }
        let units = Double(ticket.count * ticket.multiple * ticket.periods)
        guard units > 0 else { return nil }
        let unit = total / units
        if abs(unit - 3) < 0.01, !ticket.addOn {
            ticket.addOn = true
            return "票面合计 \(MoneyText.format(total)) 折下来是 3 元一注，按追加票记（已自动勾上「追加投注」）。"
        }
        if abs(unit - 2) < 0.01, ticket.addOn {
            ticket.addOn = false
            return "票面合计 \(MoneyText.format(total)) 折下来是 2 元一注，不是追加票（已自动取消「追加投注」）。"
        }
        return nil
    }

    static func summary(for tickets: [ScannedTicket]) -> [String] {
        var warnings: [String] = []
        if tickets.isEmpty {
            warnings.append("没认出彩票。目前支持双色球、大乐透、七乐彩、快乐8、福彩3D、排列3、排列5、七星彩的单式票，以及双色球和大乐透的复式、胆拖票。")
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
