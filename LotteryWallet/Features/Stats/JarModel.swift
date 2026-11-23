import Foundation

/// 球罐统计逐个号码的命中。奖金待公布时，只要已经核对号码就可以入罐。
struct JarEntry {
    var day: String
    var game: GameKey
    var numbers: NumberSet
    var matched: [SectionKey: [Bool]]
}

enum JarBuilder {
    /// 首版的碰撞预算，真机测量后可调整。真实命中数不受此限制。
    static let displayLimit = 1_000

    struct Jar: Equatable {
        var counts: [BallColor: Int] = [:]
        var hits: Int { counts.values.reduce(0, +) }

        func colors(limit: Int) -> [BallColor] {
            let total = hits
            let visible = min(limit, total)
            guard visible > 0 else { return [] }
            // 各色先取整，小数余数最大的颜色依次补一颗。相同余数按颜色名固定排序。
            let shares = counts.map { color, count in
                let scaled = count * visible
                return (color: color, whole: scaled / total, remainder: scaled % total)
            }.sorted { lhs, rhs in
                if lhs.remainder == rhs.remainder { return lhs.color.rawValue < rhs.color.rawValue }
                return lhs.remainder > rhs.remainder
            }
            let extras = visible - shares.reduce(0) { $0 + $1.whole }
            var colors: [BallColor] = []
            colors.reserveCapacity(visible)
            for (index, share) in shares.enumerated() {
                let count = share.whole + (index < extras ? 1 : 0)
                colors.append(contentsOf: repeatElement(share.color, count: count))
            }
            // 稳定地打散颜色，切回同一个范围时保持相同顺序。
            var seed: UInt64 = 1
            for index in colors.indices.dropFirst().reversed() {
                seed = 6364136223846793005 &* seed &+ 1
                colors.swapAt(index, Int((seed >> 32) % UInt64(index + 1)))
            }
            return colors
        }
    }

    static func build(_ entries: [JarEntry], range: ProfitRange, now: Date) -> Jar {
        let today = DateText.day(now)
        let start = range.startDay(firstDay: entries.map(\.day).min() ?? today,
                                   lastDay: entries.map(\.day).max() ?? today, now: now)
        var counts: [BallColor: Int] = [:]
        for entry in entries where entry.day >= start && (range == .all || entry.day <= today) {
            for section in entry.game.sections {
                let flags = entry.matched[section.key] ?? []
                let numbers = entry.numbers[section.key]
                for (_, hit) in zip(numbers, flags) where hit {
                    counts[section.color, default: 0] += 1
                }
            }
        }

        return Jar(counts: counts)
    }

    static let minimumDiameter = 7.5

    // Count complete staggered rows, reserving one ball diameter (at least 8pt)
    // above the pile. Allow for the two missing edge columns at the rounded base.
    private static func slots(diameter: Double, width: Double, height: Double) -> Int {
        let columns = Int(width / diameter)
        let pileHeight = height - max(8, diameter)
        guard columns > 0, pileHeight >= diameter else { return 0 }
        let rows = 1 + Int((pileHeight - diameter) / (diameter * sqrt(3) / 2))
        let curvedRows = min(rows, Int(ceil(28 / (diameter * sqrt(3) / 2))))
        let cornerLoss = curvedRows * 2 * Int(ceil(28 / diameter))
        return max(0, rows * columns - rows / 2 - cornerLoss)
    }

    static func capacity(width: Double, height: Double) -> Int {
        min(displayLimit, slots(diameter: minimumDiameter, width: width, height: height))
    }

    static func radius(count: Int, width: Double, height: Double) -> Double {
        guard count > 0, width > 0, height > 0 else { return 0 }
        let largest = min(Double(DrawCardMetrics.maxBall), width, height)
        var diameter = largest
        while diameter > minimumDiameter && slots(diameter: diameter, width: width, height: height) < count {
            let next = max(minimumDiameter, diameter * 0.9)
            // Anchor the last tier to a full jar so 1,000 balls don't land just
            // after a size change with a conspicuous empty space above them.
            if slots(diameter: next, width: width, height: height) >= displayLimit {
                var low = next, high = diameter
                for _ in 0..<12 {
                    let mid = (low + high) / 2
                    if slots(diameter: mid, width: width, height: height) >= displayLimit { low = mid }
                    else { high = mid }
                }
                return low / 2
            }
            diameter = next
        }
        return diameter / 2
    }
}
