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
    static let displayLimit = 1_200

    struct Jar: Equatable {
        var colors: [BallColor] = []
        var hits = 0

        var isSampled: Bool { colors.count < hits }
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

        let hits = counts.values.reduce(0, +)
        let visible = min(displayLimit, hits)
        guard visible > 0 else { return Jar() }

        // 按真实比例分配有限的展示球，累计取整保证展示总数精确。
        var colors: [BallColor] = []
        colors.reserveCapacity(visible)
        var cumulative = 0
        for color in counts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            cumulative += counts[color, default: 0]
            let end = Int((Double(cumulative) / Double(hits) * Double(visible)).rounded())
            colors.append(contentsOf: repeatElement(color, count: end - colors.count))
        }
        // 稳定地打散颜色，切回同一个范围时保持相同顺序。
        var seed: UInt64 = 1
        for index in colors.indices.dropFirst().reversed() {
            seed = 6364136223846793005 &* seed &+ 1
            colors.swapAt(index, Int((seed >> 32) % UInt64(index + 1)))
        }
        return Jar(colors: colors, hits: hits)
    }

    /// 球少时限制最大直径。数量增加时，逐步提高允许的占用面积并缩小球径。
    /// 达到展示上限时，球面积约占罐子的 48%，堆积的空隙和上方空间留给滚动。
    static func radius(count: Int, width: Double, height: Double) -> Double {
        guard count > 0, width > 0, height > 0 else { return 0 }
        let progress = min(Double(count) / Double(displayLimit), 1)
        let area = width * height * (0.26 + 0.22 * progress)
        return min(9, min(width, height) / 4, (area / (Double.pi * Double(count))).squareRoot())
    }
}
