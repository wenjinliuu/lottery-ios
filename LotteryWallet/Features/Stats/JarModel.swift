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
            // 按真实比例分配有限的展示球，累计取整保证展示总数精确。
            var colors: [BallColor] = []
            colors.reserveCapacity(visible)
            var cumulative = 0
            for color in counts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                cumulative += counts[color, default: 0]
                let end = Int((Double(cumulative) / Double(total) * Double(visible)).rounded())
                colors.append(contentsOf: repeatElement(color, count: end - colors.count))
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

    /// Occupied disk area; a settled hexagonal pile also contains gaps between disks.
    private static let areaFraction = 0.64
    static let minimumDiameter = 7.5

    static func capacity(width: Double, height: Double) -> Int {
        guard width >= minimumDiameter, height >= minimumDiameter else { return 0 }
        let minArea = Double.pi * pow(minimumDiameter / 2, 2)
        return min(displayLimit, max(1, Int(width * height * areaFraction / minArea)))
    }

    static func radius(count: Int, width: Double, height: Double) -> Double {
        guard count > 0, width > 0, height > 0 else { return 0 }
        let ideal = sqrt(width * height * areaFraction / (Double.pi * Double(count)))
        return min(Double(DrawCardMetrics.maxBall) / 2, min(width, height) / 2, max(minimumDiameter / 2, ideal))
    }
}
