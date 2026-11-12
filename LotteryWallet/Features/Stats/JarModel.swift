import Foundation

/// 号码球罐里放什么。
///
/// 规矩（2026-11 用真实备份推演后和用户敲定）：
/// - **一年一罐，外加一个「全部」的大罐**。
/// - 小珠子不是一个号码一颗：普通人一个月就买几百上千个号码，罐子里放不下。
///   几个号码合成一颗，**换算在一年里基本不变**，所以罐子是一个月一个月涨上去的。
/// - 「全部」的罐子永远只装到六七成，留出地方让珠子能滚。
/// - 中奖那一注里命中的号码不合并，一颗一个号，按那一注的奖金分三档。
struct JarEntry {
    /// 开奖日，`yyyy-MM-dd`。
    var day: String
    var game: GameKey
    var numbers: NumberSet
    var matched: [SectionKey: [Bool]]
    var prize: Double
}

/// 中奖球的档次。按**那一注**的奖金分，不按奖级名：各彩种的奖级叫法和金额差得很远。
enum JarTier: Int, Comparable {
    /// 小奖：不到 100 元。绝大多数中奖都在这一档。
    case small
    /// 100 元到不足 1 万元。
    case medium
    /// 1 万元以上。
    case big

    static func < (lhs: JarTier, rhs: JarTier) -> Bool { lhs.rawValue < rhs.rawValue }

    static func of(prize: Double) -> JarTier {
        if prize >= 10_000 { return .big }
        return prize >= 100 ? .medium : .small
    }
}

struct JarBead: Hashable {
    enum Kind: Hashable {
        /// 买了没开出。
        case miss
        /// 开出了，但那一注没中奖。
        case hit
        /// 中奖那一注里命中的号。
        case win(JarTier)
    }

    var kind: Kind
    var game: GameKey
    /// 这个号码区的球色（双色球的红和蓝、大乐透的蓝和黄各算各的）。
    var color: BallColor
    /// 只有中奖球带号码。
    var number: Int?
    /// 球上写的字，和票面一致（该补零的补零）。
    var label: String?
}

enum JarScope: Hashable {
    case year(Int)
    case all
}

enum JarBuilder {
    /// 罐子里小珠子大约能放多少颗。
    static let capacity = 300
    /// 中奖球最多放多少颗（放最近的）。
    static let winLimit = 60
    /// 一颗小珠代表几个号码，只取这些「整」的数。取整之后换算不会三天两头变。
    static let steps = [1, 2, 5, 10, 20, 35, 50, 70, 100, 150, 200, 350, 500, 700, 1000, 1500, 2000, 3500, 5000]

    struct Jar: Equatable {
        var beads: [JarBead] = []
        /// 一颗小珠代表几个号码。
        var per = 1
        /// 这一罐里一共多少个号码。
        var total = 0
        /// 中奖球一共多少颗（可能比放进罐子的多）。
        var wins = 0
    }

    /// 至少要这么大的换算才装得下。
    static func step(atLeast needed: Int) -> Int {
        steps.first { $0 >= needed } ?? (steps.last ?? 1)
    }

    /// - Parameters:
    ///   - elapsed: 这一年已经过了多少（0–1）。往年和「全部」传 1。
    ///   - fill: 希望装到几成。年罐按年底八成半估，「全部」按六成半。
    static func perBead(total: Int, elapsed: Double, fill: Double) -> Int {
        guard total > 0 else { return 1 }
        // 今年还没过完：按现在的节奏估到年底。刚开年时别拿两三天去估一整年，至少按一个月算。
        let projected = Double(total) / min(max(elapsed, 1.0 / 12), 1)
        return step(atLeast: Int((projected / (Double(capacity) * fill)).rounded(.up)))
    }

    static func build(_ entries: [JarEntry], scope: JarScope, now: Date) -> Jar {
        let calendar = Calendar.chinaCalendar
        let thisYear = calendar.component(.year, from: now)
        let chosen: [JarEntry]
        var elapsed = 1.0
        switch scope {
        case .all:
            chosen = entries
        case .year(let year):
            let prefix = String(format: "%04d-", year)
            chosen = entries.filter { $0.day.hasPrefix(prefix) }
            if year == thisYear {
                let day = calendar.ordinality(of: .day, in: .year, for: now) ?? 365
                elapsed = Double(day) / 365
            }
        }

        struct Tally { var bought = 0; var hits = 0 }
        var tallies: [String: (game: GameKey, color: BallColor, tally: Tally)] = [:]
        var winners: [(day: String, bead: JarBead)] = []
        var total = 0
        for entry in chosen {
            let tier = entry.prize > 0 ? JarTier.of(prize: entry.prize) : nil
            for (index, section) in entry.game.sections.enumerated() {
                let numbers = entry.numbers[section.key]
                guard !numbers.isEmpty else { continue }
                let flags = entry.matched[section.key] ?? []
                let key = "\(entry.game.rawValue)-\(index)"
                var slot = tallies[key] ?? (entry.game, section.color, Tally())
                slot.tally.bought += numbers.count
                total += numbers.count
                for (position, number) in numbers.enumerated() where position < flags.count && flags[position] {
                    if let tier {
                        winners.append((entry.day, JarBead(kind: .win(tier), game: entry.game, color: section.color, number: number,
                                                           label: section.padsNumbers ? String(format: "%02d", number) : String(number))))
                    } else {
                        slot.tally.hits += 1
                    }
                }
                tallies[key] = slot
            }
        }

        let fill = scope == .all ? 0.65 : 0.85
        let per = perBead(total: total, elapsed: elapsed, fill: fill)
        var beads: [JarBead] = []
        for key in tallies.keys.sorted() {
            guard let slot = tallies[key] else { continue }
            let winCount = winners.filter { $0.bead.game == slot.game && $0.bead.color == slot.color }.count
            let misses = max(slot.tally.bought - slot.tally.hits - winCount, 0)
            let missBeads = Int((Double(misses) / Double(per)).rounded())
            let hitBeads = slot.tally.hits > 0 ? max(Int((Double(slot.tally.hits) / Double(per)).rounded()), 1) : 0
            beads += Array(repeating: JarBead(kind: .miss, game: slot.game, color: slot.color), count: missBeads)
            beads += Array(repeating: JarBead(kind: .hit, game: slot.game, color: slot.color), count: hitBeads)
        }
        // 中奖球放最近的那些
        let recent = winners.sorted { $0.day > $1.day }.prefix(winLimit).map(\.bead)
        return Jar(beads: beads + recent, per: per, total: total, wins: winners.count)
    }
}
