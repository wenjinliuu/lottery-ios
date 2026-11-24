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

    /// 单个彩种内某一号码区（红球/蓝球/前区/后区等）的命中计数。
    struct ZoneBreakdown: Equatable, Identifiable, Sendable {
        let game: GameKey
        let sectionKey: SectionKey
        let label: String
        let color: BallColor
        let hits: Int

        var id: String { "\(game.rawValue).\(sectionKey.rawValue)" }
    }

    /// 单个彩种下的分区命中汇总。
    struct GameBreakdown: Equatable, Identifiable, Sendable {
        let game: GameKey
        let zones: [ZoneBreakdown]

        var hits: Int { zones.reduce(0) { $0 + $1.hits } }
        var id: GameKey { game }
    }

    struct Jar: Equatable {
        var counts: [BallColor: Int] = [:]
        /// 按彩种 + 号码区细分的真实命中明细（按彩种命中总数降序，彩种内保持官方球区顺序）。
        var breakdown: [GameBreakdown] = []

        var hits: Int { counts.values.reduce(0, +) }

        init(counts: [BallColor: Int] = [:], breakdown: [GameBreakdown] = []) {
            self.counts = counts
            self.breakdown = breakdown
        }

        /// 按命中数降序返回前 N 种球色，用于胶囊上的彩点指示。
        func topColors(limit: Int = 3) -> [BallColor] {
            counts
                .filter { $0.value > 0 }
                .sorted { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value
                }
                .prefix(limit)
                .map(\.key)
        }

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

        /// 当真实命中数超过展示上限时，按相同最大余数法算出每个彩种分区在罐内示意展示的颗数。
        func scaledZoneCounts(limit: Int) -> [String: Int] {
            let allZones = breakdown.flatMap(\.zones)
            let total = allZones.reduce(0) { $0 + $1.hits }
            let visible = min(limit, total)
            guard visible > 0, total > 0 else { return [:] }
            if visible == total {
                return Dictionary(uniqueKeysWithValues: allZones.map { ($0.id, $0.hits) })
            }
            let shares = allZones.map { zone in
                let scaled = zone.hits * visible
                return (id: zone.id, whole: scaled / total, remainder: scaled % total)
            }.sorted { lhs, rhs in
                if lhs.remainder == rhs.remainder { return lhs.id < rhs.id }
                return lhs.remainder > rhs.remainder
            }
            let extras = visible - shares.reduce(0) { $0 + $1.whole }
            var result: [String: Int] = [:]
            result.reserveCapacity(shares.count)
            for (index, share) in shares.enumerated() {
                result[share.id] = share.whole + (index < extras ? 1 : 0)
            }
            return result
        }
    }

    static func build(_ entries: [JarEntry], range: ProfitRange, now: Date) -> Jar {
        let today = DateText.day(now)
        let start = range.startDay(firstDay: entries.map(\.day).min() ?? today,
                                   lastDay: entries.map(\.day).max() ?? today, now: now)
        var counts: [BallColor: Int] = [:]
        var zoneCounts: [GameKey: [SectionKey: Int]] = [:]
        for entry in entries where entry.day >= start && (range == .all || entry.day <= today) {
            for section in entry.game.sections {
                let flags = entry.matched[section.key] ?? []
                let numbers = entry.numbers[section.key]
                for (_, hit) in zip(numbers, flags) where hit {
                    counts[section.color, default: 0] += 1
                    zoneCounts[entry.game, default: [:]][section.key, default: 0] += 1
                }
            }
        }

        let orderIndex = Dictionary(uniqueKeysWithValues: GameKey.ordered.enumerated().map { ($0.element, $0.offset) })
        let breakdown: [GameBreakdown] = zoneCounts.compactMap { game, sectionsMap in
            let zones = game.sections.map { section in
                ZoneBreakdown(game: game,
                              sectionKey: section.key,
                              label: section.label,
                              color: section.color,
                              hits: sectionsMap[section.key, default: 0])
            }
            let total = zones.reduce(0) { $0 + $1.hits }
            guard total > 0 else { return nil }
            return GameBreakdown(game: game, zones: zones)
        }.sorted { lhs, rhs in
            if lhs.hits == rhs.hits {
                return (orderIndex[lhs.game] ?? 0) < (orderIndex[rhs.game] ?? 0)
            }
            return lhs.hits > rhs.hits
        }

        return Jar(counts: counts, breakdown: breakdown)
    }

    /// 预览与测试用的示例大罐数据，同时提供精准的彩种与分区明细。
    static func demoPreview(hits: Int) -> Jar {
        let ssqRed = hits * 55 / 100
        let totalBlue = hits * 40 / 100
        let ssqBlue = totalBlue * 22 / 100
        let dltFront = totalBlue - ssqBlue
        let totalYellow = hits - ssqRed - totalBlue
        let dltBack = totalYellow * 65 / 100
        let qlcBasic = totalYellow - dltBack

        var counts: [BallColor: Int] = [:]
        if ssqRed > 0 { counts[.red] = ssqRed }
        if totalBlue > 0 { counts[.blue] = totalBlue }
        if totalYellow > 0 { counts[.yellow] = totalYellow }

        let breakdown: [GameBreakdown] = [
            GameBreakdown(game: .ssq, zones: [
                ZoneBreakdown(game: .ssq, sectionKey: .red, label: "红球", color: .red, hits: ssqRed),
                ZoneBreakdown(game: .ssq, sectionKey: .blue, label: "蓝球", color: .blue, hits: ssqBlue)
            ]),
            GameBreakdown(game: .dlt, zones: [
                ZoneBreakdown(game: .dlt, sectionKey: .front, label: "前区", color: .blue, hits: dltFront),
                ZoneBreakdown(game: .dlt, sectionKey: .back, label: "后区", color: .yellow, hits: dltBack)
            ]),
            GameBreakdown(game: .qlc, zones: [
                ZoneBreakdown(game: .qlc, sectionKey: .nums7, label: "基本号", color: .yellow, hits: qlcBasic)
            ])
        ].filter { $0.hits > 0 }.sorted { $0.hits > $1.hits }

        return Jar(counts: counts, breakdown: breakdown)
    }

    static let minimumDiameter = 7.5

    // Count complete staggered rows, reserving one ball diameter (at least 8pt)
    // above the pile. Allow for the two missing edge columns at the rounded base.
    private static func slots(diameter: Double, width: Double, height: Double, corner: Double = 28) -> Int {
        let columns = Int(width / diameter)
        let pileHeight = height - max(8, diameter)
        guard columns > 0, pileHeight >= diameter else { return 0 }
        let rows = 1 + Int((pileHeight - diameter) / (diameter * sqrt(3) / 2))
        let curvedRows = min(rows, Int(ceil(corner / (diameter * sqrt(3) / 2))))
        let cornerLoss = curvedRows * 2 * Int(ceil(corner / diameter))
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
