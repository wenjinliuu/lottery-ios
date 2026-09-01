import Foundation

/// 折线图的时间范围。
enum ProfitRange: String, CaseIterable, Identifiable {
    case week = "7"
    case month = "month"
    case quarter = "90"
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: "近7天"
        case .month: "本月"
        case .quarter: "近90天"
        case .all: "全部"
        }
    }
}

/// 统计用的轻量快照。
///
/// 统计不直接吃 SwiftData 对象：一是每次属性访问都有托管开销，
/// 二是日期、号码这些字段临时解析太贵。统一先抽成纯值再算。
struct SettledEntry: Hashable, Sendable {
    var day: String
    var game: GameKey
    var cost: Double
    var prize: Double
    var isWon: Bool

    var net: Double { prize - cost }
}

/// 一天的盈亏汇总。
struct ProfitDay: Identifiable, Hashable {
    var date: String
    var day: Date
    /// 当日收盘累计余额，折线画的就是这条。
    var close: Double
    var cost: Double
    var prize: Double
    var count: Int
    var wonCount: Int
    var games: [GameSpend]

    var id: String { date }
    var net: Double { prize - cost }
    var winRate: Double { count > 0 ? Double(wonCount) / Double(count) * 100 : 0 }
}

struct GameSpend: Identifiable, Hashable {
    var game: GameKey
    var cost: Double
    var prize: Double
    var count: Int

    var id: GameKey { game }
    var net: Double { prize - cost }
}

/// 折线图的完整数据。
struct ProfitSeries {
    var days: [ProfitDay] = []
    var costTotal: Double = 0
    var prizeTotal: Double = 0
    var settledCount: Int = 0
    var closingBalance: Double = 0
    var rangeLabel: String = ""

    var netTotal: Double { prizeTotal - costTotal }
    var isEmpty: Bool { days.isEmpty }
}

enum ProfitStats {
    /// 折线最多画这么多个点。点太密看不出趋势，还白白拖慢渲染。
    static let maxChartPoints = 180

    /// 把记录抽成统计快照。只取已经有结论的（中奖 / 未中奖），
    /// 待核对和奖金浮动的不计入，避免曲线来回跳。
    static func snapshot(_ records: [TicketRecord]) -> [SettledEntry] {
        records.compactMap { record in
            guard record.status == .won || record.status == .lost else { return nil }
            return SettledEntry(day: record.profitDay,
                                game: record.game,
                                cost: record.cost,
                                prize: record.prizeAmount,
                                isWon: record.status == .won)
        }
    }

    /// 全部记录的快照，统计页要连待核对的一起算花费。
    static func snapshotAll(_ records: [TicketRecord]) -> [SettledEntry] {
        records.map { record in
            SettledEntry(day: record.profitDay,
                         game: record.game,
                         cost: record.cost,
                         prize: record.prizeAmount,
                         isWon: record.status == .won)
        }
    }

    // MARK: - 累计盈亏折线

    /// 只在**有记录的日子**上打点，不再逐日填充空白天。
    /// 逐日填充在跨度大时会生成上万个点，既拖慢渲染又没有信息量。
    static func series(entries: [SettledEntry], range: ProfitRange, now: Date = Date()) -> ProfitSeries {
        guard !entries.isEmpty else { return ProfitSeries(rangeLabel: range.label) }

        var byDay: [String: [SettledEntry]] = [:]
        for entry in entries { byDay[entry.day, default: []].append(entry) }
        let allDays = byDay.keys.sorted()
        guard let lastDay = allDays.last else { return ProfitSeries(rangeLabel: range.label) }

        let startDay = rangeStart(range: range, lastDay: lastDay, firstDay: allDays[0], now: now)

        // 区间之前的记录压成起始余额，曲线才接得上
        var balance = 0.0
        var visible: [String] = []
        for day in allDays {
            if day < startDay {
                balance += byDay[day]?.reduce(0) { $0 + $1.net } ?? 0
            } else {
                visible.append(day)
            }
        }
        guard !visible.isEmpty else { return ProfitSeries(rangeLabel: range.label) }

        var points: [ProfitDay] = []
        points.reserveCapacity(visible.count + 1)

        // "全部"范围在最前面补一个 0 基线点，曲线从零起步更直观
        if range == .all, let first = DateText.parse(visible[0]),
           let baseline = Calendar.chinaCalendar.date(byAdding: .day, value: -1, to: first) {
            points.append(ProfitDay(date: DateText.day(baseline), day: baseline,
                                    close: 0, cost: 0, prize: 0, count: 0, wonCount: 0, games: []))
        }

        var costTotal = 0.0
        var prizeTotal = 0.0
        var settledCount = 0
        for day in visible {
            let items = byDay[day] ?? []
            var cost = 0.0
            var prize = 0.0
            var won = 0
            var byGame: [GameKey: GameSpend] = [:]
            for item in items {
                cost += item.cost
                prize += item.prize
                if item.isWon { won += 1 }
                var spend = byGame[item.game] ?? GameSpend(game: item.game, cost: 0, prize: 0, count: 0)
                spend.cost += item.cost
                spend.prize += item.prize
                spend.count += 1
                byGame[item.game] = spend
            }
            balance += prize - cost
            costTotal += cost
            prizeTotal += prize
            settledCount += items.count
            points.append(ProfitDay(date: day,
                                    day: DateText.parse(day) ?? Date(),
                                    close: balance,
                                    cost: cost,
                                    prize: prize,
                                    count: items.count,
                                    wonCount: won,
                                    games: byGame.values.sorted { $0.cost > $1.cost }))
        }

        return ProfitSeries(days: downsample(points),
                            costTotal: costTotal,
                            prizeTotal: prizeTotal,
                            settledCount: settledCount,
                            closingBalance: balance,
                            rangeLabel: range.label)
    }

    private static func rangeStart(range: ProfitRange, lastDay: String, firstDay: String, now: Date) -> String {
        switch range {
        case .all:
            return firstDay
        case .month:
            return String(DateText.day(now).prefix(7)) + "-01"
        case .week, .quarter:
            let span = Int(range.rawValue) ?? 7
            guard let end = DateText.parse(lastDay),
                  let shifted = Calendar.chinaCalendar.date(byAdding: .day, value: -(max(span, 1) - 1), to: end) else {
                return firstDay
            }
            return DateText.day(shifted)
        }
    }

    /// 点数超上限时等距抽稀，保留首尾，累计值本身仍然正确。
    private static func downsample(_ points: [ProfitDay]) -> [ProfitDay] {
        guard points.count > maxChartPoints else { return points }
        let stride = Double(points.count - 1) / Double(maxChartPoints - 1)
        var result: [ProfitDay] = []
        result.reserveCapacity(maxChartPoints)
        for step in 0..<maxChartPoints {
            let index = Int((Double(step) * stride).rounded())
            result.append(points[min(index, points.count - 1)])
        }
        return result
    }

    // MARK: - 统计页

    struct PeriodStats {
        var cost: Double = 0
        var prize: Double = 0
        var ticketCount: Int = 0
        var wonCount: Int = 0
        var byGame: [GameSpend] = []
        var byDay: [ProfitDay] = []
        var byMonth: [Int: [GameSpend]] = [:]

        var net: Double { prize - cost }
        var winRate: Double { ticketCount > 0 ? Double(wonCount) / Double(ticketCount) * 100 : 0 }
    }

    /// 按年或年月汇总。`month` 为 nil 表示全年。
    static func period(entries: [SettledEntry], year: Int, month: Int?) -> PeriodStats {
        var stats = PeriodStats()
        var byGame: [GameKey: GameSpend] = [:]
        var byMonthGame: [Int: [GameKey: GameSpend]] = [:]
        var byDay: [String: ProfitDay] = [:]
        let yearPrefix = String(format: "%04d-", year)

        for entry in entries {
            guard entry.day.hasPrefix(yearPrefix), entry.day.count >= 10 else { continue }
            let monthIndex = Int(entry.day.dropFirst(5).prefix(2)) ?? 0
            if let month, monthIndex != month { continue }

            stats.cost += entry.cost
            stats.prize += entry.prize
            stats.ticketCount += 1
            if entry.isWon { stats.wonCount += 1 }

            var spend = byGame[entry.game] ?? GameSpend(game: entry.game, cost: 0, prize: 0, count: 0)
            spend.cost += entry.cost
            spend.prize += entry.prize
            spend.count += 1
            byGame[entry.game] = spend

            var monthMap = byMonthGame[monthIndex] ?? [:]
            var monthSpend = monthMap[entry.game] ?? GameSpend(game: entry.game, cost: 0, prize: 0, count: 0)
            monthSpend.cost += entry.cost
            monthSpend.prize += entry.prize
            monthSpend.count += 1
            monthMap[entry.game] = monthSpend
            byMonthGame[monthIndex] = monthMap

            var day = byDay[entry.day] ?? ProfitDay(date: entry.day, day: Date(), close: 0,
                                                    cost: 0, prize: 0, count: 0, wonCount: 0, games: [])
            day.cost += entry.cost
            day.prize += entry.prize
            day.count += 1
            if entry.isWon { day.wonCount += 1 }
            byDay[entry.day] = day
        }

        stats.byGame = byGame.values.sorted { $0.cost > $1.cost }
        stats.byDay = byDay.values.sorted { $0.date < $1.date }
        stats.byMonth = byMonthGame.mapValues { $0.values.sorted { $0.cost > $1.cost } }
        return stats
    }

    /// 记录里出现过的年份，倒序。
    static func availableYears(entries: [SettledEntry]) -> [Int] {
        let years = Set(entries.compactMap { Int($0.day.prefix(4)) })
        let current = Calendar.current.component(.year, from: Date())
        return Array(years.union([current])).sorted(by: >)
    }
}

extension Calendar {
    /// 统一按东八区算日期，避免跨时区把开奖日算错一天。
    static let chinaCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DateText.chinaTimeZone
        return calendar
    }()
}
