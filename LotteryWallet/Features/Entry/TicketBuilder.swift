import Foundation

/// 录入方式。
///
/// 早期有一个「随机」模式：进页面直接给几注机选号，用户只能重摇。
/// 它和手选里的「随机填充」是同一件事，却多出一整套并行状态
/// （randomTickets / randomCount / regenerate），已经删掉。
enum EntryMode: String, CaseIterable, Identifiable {
    case manual     // 手选单式
    case system     // 复式
    case dantuo     // 胆拖

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: "手选"
        case .system: "复式"
        case .dantuo: "胆拖"
        }
    }

    var kind: EntryKind {
        switch self {
        case .manual: .manual
        case .system: .system
        case .dantuo: .dantuo
        }
    }

    /// 复式和胆拖目前只对双色球、大乐透开放，与 web 版一致。
    static func modes(for game: GameKey) -> [EntryMode] {
        game.supportsSystemPlay ? [.manual, .system, .dantuo] : [.manual]
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

    // MARK: - 随机填充

    static func pickUnique(count: Int, from range: ClosedRange<Int>) -> [Int] {
        var pool = Array(range)
        pool.shuffle()
        return Array(pool.prefix(count))
    }

    /// 数字型号码区（3D、排列3/5、七星彩前六位）的随机一注。
    ///
    /// 3D 和排列3 的组选必须**按玩法出号**，否则随机填充给出来的号根本
    /// 不属于用户选的玩法：组三是「两个号相同、第三个不同」，组六是三个全不同。
    /// 早期一律 `Int.random` 三次，选着组三却随出 1-5-9，一辈子也随不出对子。
    static func randomDigits(game: GameKey, count: Int, range: ClosedRange<Int>, playMode: String) -> [Int] {
        guard game == .fc3d || game == .pl3, count == 3 else {
            // 直选和其余数字型玩法按位取值，允许重复（豹子、对子都要随得出来）
            return (0..<count).map { _ in Int.random(in: range) }
        }
        switch playMode {
        case "group3":
            // 两个相同 + 一个不同
            let pair = Int.random(in: range)
            var single = Int.random(in: range)
            while single == pair { single = Int.random(in: range) }
            return [pair, pair, single].shuffled()
        case "group6":
            // 三个互不相同
            return pickUnique(count: 3, from: range)
        default:
            return (0..<count).map { _ in Int.random(in: range) }
        }
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
            let need = game.pickCount(for: section, playMode: playMode)
            let groups: [[Int]]
            switch mode {
            case .manual:
                guard selection.selected.count == need else { return [] }
                groups = [section.isPositional ? selection.selected : selection.selected.sorted()]
            case .system:
                guard selection.selected.count >= need else { return [] }
                groups = combinations(of: selection.selected.sorted(), choose: need)
            case .dantuo:
                let dan = selection.dan.sorted()
                let tuo = selection.tuo.sorted()
                guard dan.count < need, dan.count + tuo.count >= need else { return [] }
                groups = combinations(of: tuo, choose: need - dan.count).map { (dan + $0).sorted() }
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
        if game == .k8 { tickets = tickets.map { var t = $0; t.playCount = t[.nums].count; return t } }
        if game == .dlt && addOn { tickets = tickets.map { var t = $0; t.addOn = true; return t } }
        return tickets
    }

    /// 展开后的注数，用于在保存前给用户看"共 N 注 / 合计 M 元"。
    static func combinationCount(game: GameKey,
                                 selections: [SectionKey: SectionSelection],
                                 mode: EntryMode,
                                 playMode: String = "") -> Int {
        var total = 1
        for section in game.sections {
            let selection = selections[section.key] ?? SectionSelection()
            let need = game.pickCount(for: section, playMode: playMode)
            switch mode {
            case .manual:
                guard selection.selected.count == need else { return 0 }
            case .system:
                guard selection.selected.count >= need else { return 0 }
                total *= binomial(selection.selected.count, need)
            case .dantuo:
                let dan = selection.dan.count
                let tuo = selection.tuo.count
                guard dan < need, dan + tuo >= need else { return 0 }
                total *= binomial(tuo, need - dan)
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
