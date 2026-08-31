import Foundation

/// 录入方式。
enum EntryMode: String, CaseIterable, Identifiable {
    case random     // 机选
    case manual     // 手动单式
    case system     // 复式
    case dantuo     // 胆拖

    var id: String { rawValue }

    var label: String {
        switch self {
        case .random: "随机"
        case .manual: "普通"
        case .system: "复式"
        case .dantuo: "胆拖"
        }
    }

    var kind: EntryKind {
        switch self {
        case .random: .random
        case .manual: .manual
        case .system: .system
        case .dantuo: .dantuo
        }
    }

    /// 复式和胆拖目前只对双色球、大乐透开放，与 web 版一致。
    static func modes(for game: GameKey) -> [EntryMode] {
        game.supportsSystemPlay ? [.random, .manual, .system, .dantuo] : [.random, .manual]
    }
}

/// 一个号码区的选号状态。复式用 `selected`，胆拖再额外标出 `dan`。
struct SectionSelection: Hashable {
    var selected: [Int] = []
    /// 胆码，必出现在每一注里。
    var dan: [Int] = []

    var tuo: [Int] { selected.filter { !dan.contains($0) } }
}

/// 选号 → 单注展开。复式和胆拖都在这里拆成一注一注，
/// 好让现有的判奖规则原样复用。
enum TicketBuilder {
    /// 复式/胆拖展开的注数上限，超过就不让保存。
    static let maxCombinations = 2000

    // MARK: - 随机

    static func randomTickets(game: GameKey, count: Int, playMode: String) -> [Ticket] {
        (0..<max(count, 1)).map { _ in randomTicket(game: game, playMode: playMode) }
    }

    static func randomTicket(game: GameKey, playMode: String) -> Ticket {
        var numbers = NumberSet()
        for section in game.sections {
            if section.isPositional {
                // 数字型玩法按位取值，允许重复
                numbers[section.key] = (0..<section.count).map { _ in Int.random(in: section.range) }
            } else {
                numbers[section.key] = pickUnique(count: section.count, from: section.range).sorted()
            }
        }
        var ticket = Ticket(numbers: numbers, playMode: playMode, entryLabel: EntryMode.random.label)
        if game == .k8 { ticket.playCount = Int(playMode) ?? sectionCount(game) }
        ticket.addOn = game == .dlt && playMode == "add"
        return ticket
    }

    private static func sectionCount(_ game: GameKey) -> Int {
        game.sections.first?.count ?? 0
    }

    static func pickUnique(count: Int, from range: ClosedRange<Int>) -> [Int] {
        var pool = Array(range)
        pool.shuffle()
        return Array(pool.prefix(count))
    }

    // MARK: - 展开

    /// 把每个号码区的选号展开成组合，再跨区做笛卡尔积。
    /// 返回 nil 表示注数超过上限。
    static func expand(game: GameKey,
                       selections: [SectionKey: SectionSelection],
                       mode: EntryMode,
                       playMode: String,
                       addOn: Bool) -> [Ticket]? {
        var perSection: [(key: SectionKey, groups: [[Int]])] = []
        for section in game.sections {
            let selection = selections[section.key] ?? SectionSelection()
            let groups: [[Int]]
            switch mode {
            case .manual, .random:
                guard selection.selected.count == section.count else { return [] }
                groups = [section.isPositional ? selection.selected : selection.selected.sorted()]
            case .system:
                guard selection.selected.count >= section.count else { return [] }
                groups = combinations(of: selection.selected.sorted(), choose: section.count)
            case .dantuo:
                let dan = selection.dan.sorted()
                let tuo = selection.tuo.sorted()
                guard dan.count < section.count, dan.count + tuo.count >= section.count else { return [] }
                groups = combinations(of: tuo, choose: section.count - dan.count).map { (dan + $0).sorted() }
            }
            if groups.isEmpty { return [] }
            perSection.append((section.key, groups))
        }

        let total = perSection.reduce(1) { $0 * $1.groups.count }
        guard total <= maxCombinations else { return nil }

        var tickets: [Ticket] = [Ticket(playMode: playMode, entryLabel: mode.label)]
        for (key, groups) in perSection {
            var next: [Ticket] = []
            next.reserveCapacity(tickets.count * groups.count)
            for ticket in tickets {
                for group in groups {
                    var copy = ticket
                    copy.numbers[key] = group
                    next.append(copy)
                }
            }
            tickets = next
        }
        if game == .k8 { tickets = tickets.map { var t = $0; t.playCount = Int(playMode); return t } }
        if game == .dlt && addOn { tickets = tickets.map { var t = $0; t.addOn = true; return t } }
        return tickets
    }

    /// 展开后的注数，用于在保存前给用户看"共 N 注 / 合计 M 元"。
    static func combinationCount(game: GameKey,
                                 selections: [SectionKey: SectionSelection],
                                 mode: EntryMode) -> Int {
        var total = 1
        for section in game.sections {
            let selection = selections[section.key] ?? SectionSelection()
            switch mode {
            case .manual, .random:
                guard selection.selected.count == section.count else { return 0 }
            case .system:
                guard selection.selected.count >= section.count else { return 0 }
                total *= binomial(selection.selected.count, section.count)
            case .dantuo:
                let dan = selection.dan.count
                let tuo = selection.tuo.count
                guard dan < section.count, dan + tuo >= section.count else { return 0 }
                total *= binomial(tuo, section.count - dan)
            }
            if total > maxCombinations { return total }
        }
        return total
    }

    // MARK: - 组合数学

    static func combinations(of values: [Int], choose k: Int) -> [[Int]] {
        guard k > 0 else { return [[]] }
        guard values.count >= k else { return [] }
        if values.count == k { return [values] }
        var result: [[Int]] = []
        var current: [Int] = []
        func walk(_ start: Int) {
            if current.count == k {
                result.append(current)
                return
            }
            guard start < values.count else { return }
            // 剩余数量不够就提前剪枝
            if values.count - start < k - current.count { return }
            for index in start..<values.count {
                current.append(values[index])
                walk(index + 1)
                current.removeLast()
            }
        }
        walk(0)
        return result
    }

    static func binomial(_ n: Int, _ k: Int) -> Int {
        guard k >= 0, n >= k else { return 0 }
        let k = min(k, n - k)
        var result = 1
        for i in 0..<k {
            result = result * (n - i) / (i + 1)
        }
        return result
    }
}
