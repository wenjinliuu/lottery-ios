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

    /// 这种录入方式对应的票面类型。录入页的分段控件、落库的 `entryLabel`、
    /// 票夹卡片上的标签全都从这里出，三处再也不会各说各的。
    var shape: TicketShape {
        switch self {
        case .manual: .single
        case .system: .system
        case .dantuo: .dantuo
        }
    }

    /// 「单式票 / 复式票 / 胆拖票」。显示名只有 `TicketShape` 一处。
    var label: String { shape.label }

    var kind: EntryKind {
        switch self {
        case .manual: .manual
        case .system: .system
        case .dantuo: .dantuo
        }
    }

    /// 各彩种在当前玩法下支持的票面类型（基于真实物理票面规格）。
    static func modes(for game: GameKey, playMode: String = "") -> [EntryMode] {
        var result: [EntryMode] = [.manual]
        if game.supportsSystemPlay { result.append(.system) }
        if game.supportsDantuo(playMode: playMode) { result.append(.dantuo) }
        return result
    }
}

/// 一个号码区的选号状态。
/// - 单式 / 普通复式用 `selected`；
/// - 胆拖再额外标出 `dan`；
/// - 定位复式（排列3/3D 直选定位复式、排列5、七星彩前六位）按位存在 `positional`。
struct SectionSelection: Hashable {
    var selected: [Int] = []
    /// 胆码，必出现在每一注里。
    var dan: [Int] = []
    /// 定位复式按位选号，每个子数组是对应位置选中的数字集合。
    var positional: [[Int]] = []

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
        let effectiveMode = playMode.isEmpty ? game.defaultPlayMode : playMode
        var perSection: [(key: SectionKey, groups: [[Int]])] = []
        for section in game.sections {
            let selection = selections[section.key] ?? SectionSelection()
            let need = game.pickCount(for: section, playMode: effectiveMode)
            let groups: [[Int]]
            switch mode {
            case .manual:
                guard selection.selected.count == need else { return [] }
                groups = [section.isPositional ? selection.selected : selection.selected.sorted()]
            case .system:
                if game.usesPositionalSystem(for: section, playMode: effectiveMode) {
                    // 直选定位复式（排列3/3D 直选、排列5、七星彩前六位）：每位独立选 1–10 个数字做笛卡尔积。
                    guard selection.positional.count == need else { return [] }
                    let cleaned = selection.positional.map { Array(Set($0.filter { section.range.contains($0) })).sorted() }
                    guard cleaned.allSatisfy({ !$0.isEmpty }) else { return [] }
                    // 先检查总注数上限，避免笛卡尔积中途分配过大数组
                    var posCount = 1
                    for digits in cleaned {
                        posCount *= digits.count
                        if posCount > maxCombinations { return nil }
                    }
                    groups = cartesianProduct(cleaned)
                    break
                }
                if game == .pl3 || game == .fc3d {
                    // 排列3 / 3D 的组选复式（包号）：选一组不重复的数字。
                    //   组选6复式：任取 3 个不同的数字，C(n,3) 注，n 为 4–10；
                    //   组选3复式：一个对子加另一个数字，n×(n−1) 注，n 为 2–10。
                    let digits = Array(Set(selection.selected.filter { section.range.contains($0) })).sorted()
                    switch effectiveMode {
                    case "group6":
                        guard digits.count >= 4 else { return [] }
                        groups = combinations(of: digits, choose: 3)
                    case "group3":
                        guard digits.count >= 2 else { return [] }
                        groups = digits.flatMap { pair in digits.filter { $0 != pair }.map { [pair, pair, $0] } }
                    default:
                        return []
                    }
                    break
                }
                let unique = Array(Set(selection.selected.filter { section.range.contains($0) })).sorted()
                guard unique.count >= need else { return [] }
                let count = binomial(unique.count, need)
                if count > maxCombinations { return nil }
                groups = combinations(of: unique, choose: need)
            case .dantuo:
                let dan = Array(Set(selection.dan.filter { section.range.contains($0) })).sorted()
                let tuo = Array(Set(selection.tuo.filter { section.range.contains($0) })).sorted()
                if game == .pl3 || game == .fc3d {
                    switch effectiveMode {
                    case "group6":
                        // 组选6胆拖：1–2 个胆码 + 拖码，从拖码里补足到 3 个不同数字，C(t, 3-d) 注。
                        guard (1...2).contains(dan.count), dan.count + tuo.count >= 3 else { return [] }
                        let count = binomial(tuo.count, 3 - dan.count)
                        if count > maxCombinations { return nil }
                        groups = combinations(of: tuo, choose: 3 - dan.count).map { (dan + $0).sorted() }
                    case "group3":
                        // 组选3胆拖：1 个胆码 + ≥1 个拖码，每个拖码配出「胆胆拖」和「拖拖胆」2 注。
                        guard dan.count == 1, !tuo.isEmpty else { return [] }
                        let d = dan[0]
                        groups = tuo.flatMap { x in [[d, d, x], [x, x, d]] }
                    default:
                        return []
                    }
                    break
                }
                guard dan.count < need, dan.count + tuo.count >= need else { return [] }
                let count = binomial(tuo.count, need - dan.count)
                if count > maxCombinations { return nil }
                groups = combinations(of: tuo, choose: need - dan.count).map { (dan + $0).sorted() }
            }
            if groups.isEmpty { return [] }
            perSection.append((section.key, groups))
        }

        let total = perSection.reduce(1) { $0 * $1.groups.count }
        guard total <= maxCombinations else { return nil }

        var tickets: [Ticket] = [Ticket(playMode: effectiveMode, entryLabel: mode.label)]
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
        let effectiveMode = playMode.isEmpty ? game.defaultPlayMode : playMode
        var total = 1
        for section in game.sections {
            let selection = selections[section.key] ?? SectionSelection()
            let need = game.pickCount(for: section, playMode: effectiveMode)
            switch mode {
            case .manual:
                guard selection.selected.count == need else { return 0 }
            case .system:
                if game.usesPositionalSystem(for: section, playMode: effectiveMode) {
                    guard selection.positional.count == need else { return 0 }
                    for pos in selection.positional {
                        let c = Set(pos.filter { section.range.contains($0) }).count
                        guard c > 0 else { return 0 }
                        total *= c
                        if total > maxCombinations { return total }
                    }
                    break
                }
                if game == .pl3 || game == .fc3d {
                    let n = Set(selection.selected.filter { section.range.contains($0) }).count
                    switch effectiveMode {
                    case "group6":
                        guard n >= 4 else { return 0 }
                        total *= binomial(n, 3)
                    case "group3":
                        guard n >= 2 else { return 0 }
                        total *= n * (n - 1)
                    default:
                        return 0
                    }
                    break
                }
                let n = Set(selection.selected.filter { section.range.contains($0) }).count
                guard n >= need else { return 0 }
                total *= binomial(n, need)
            case .dantuo:
                let dan = Set(selection.dan.filter { section.range.contains($0) }).count
                let tuo = Set(selection.tuo.filter { section.range.contains($0) }).count
                if game == .pl3 || game == .fc3d {
                    switch effectiveMode {
                    case "group6":
                        guard (1...2).contains(dan), dan + tuo >= 3 else { return 0 }
                        total *= binomial(tuo, 3 - dan)
                    case "group3":
                        guard dan == 1, tuo >= 1 else { return 0 }
                        total *= 2 * tuo
                    default:
                        return 0
                    }
                    break
                }
                guard dan < need, dan + tuo >= need else { return 0 }
                total *= binomial(tuo, need - dan)
            }
            if total > maxCombinations { return total }
        }
        return total
    }

    static func cartesianProduct(_ pools: [[Int]]) -> [[Int]] {
        var result: [[Int]] = [[]]
        for pool in pools {
            var next: [[Int]] = []
            next.reserveCapacity(result.count * pool.count)
            for prefix in result {
                for value in pool {
                    next.append(prefix + [value])
                }
            }
            result = next
        }
        return result
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
