import Foundation

/// 号码球罐里放什么。
///
/// 规矩（2026-11 用真实备份推演后和用户敲定）：
/// - **一年一罐，外加一个「全部」的大罐**。
/// - 小珠子不是一个号码一颗：普通人一个月就买几百上千个号码，罐子里放不下。
///   几个号码合成一颗，**换算在一年里基本不变**，所以罐子是一个月一个月涨上去的。
/// - 「全部」的罐子永远只装到六七成，留出地方让珠子能滚。
/// - 只分两类：买了没开出的、开出了的。中没中奖不另外区分（试过带号码、带金圈的中奖球，
///   用户看了觉得太复杂，2026-11 去掉）。
struct JarEntry {
    /// 开奖日，`yyyy-MM-dd`。
    var day: String
    var game: GameKey
    var numbers: NumberSet
    var matched: [SectionKey: [Bool]]
    var prize: Double
}

struct JarBead: Hashable {
    enum Kind: Hashable {
        /// 买了没开出。
        case miss
        /// 开出了。
        case hit
    }

    var kind: Kind
    var game: GameKey
    /// 这个号码区的球色（双色球的红和蓝、大乐透的蓝和黄各算各的）。
    var color: BallColor
}

enum JarScope: Hashable {
    case year(Int)
    case all
}

enum JarBuilder {
    /// 罐子里小珠子大约能放多少颗。
    static let capacity = 300
    /// 一颗小珠代表几个号码，只取这些「整」的数。取整之后换算不会三天两头变。
    static let steps = [1, 2, 5, 10, 20, 35, 50, 70, 100, 150, 200, 350, 500, 700, 1000, 1500, 2000, 3500, 5000]

    struct Jar: Equatable {
        var beads: [JarBead] = []
        /// 一颗小珠代表几个号码。
        var per = 1
        /// 这一罐里一共多少个号码。
        var total = 0
        /// 其中开出了的有多少个。
        var hits = 0
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
        var total = 0, hits = 0
        for entry in chosen {
            for (index, section) in entry.game.sections.enumerated() {
                let numbers = entry.numbers[section.key]
                guard !numbers.isEmpty else { continue }
                let flags = entry.matched[section.key] ?? []
                let key = "\(entry.game.rawValue)-\(index)"
                var slot = tallies[key] ?? (entry.game, section.color, Tally())
                let matched = zip(numbers, flags).filter { $0.1 }.count
                slot.tally.bought += numbers.count
                slot.tally.hits += matched
                total += numbers.count
                hits += matched
                tallies[key] = slot
            }
        }

        let fill = scope == .all ? 0.65 : 0.85
        let per = perBead(total: total, elapsed: elapsed, fill: fill)
        var beads: [JarBead] = []
        for key in tallies.keys.sorted() {
            guard let slot = tallies[key] else { continue }
            let misses = slot.tally.bought - slot.tally.hits
            let missBeads = Int((Double(misses) / Double(per)).rounded())
            // 开出的号再少，只要有就至少留一颗
            let hitBeads = slot.tally.hits > 0 ? max(Int((Double(slot.tally.hits) / Double(per)).rounded()), 1) : 0
            beads += Array(repeating: JarBead(kind: .miss, game: slot.game, color: slot.color), count: missBeads)
            beads += Array(repeating: JarBead(kind: .hit, game: slot.game, color: slot.color), count: hitBeads)
        }
        return Jar(beads: beads, per: per, total: total, hits: hits)
    }
}
