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

/// 一天的盈亏汇总。
struct ProfitDay: Identifiable, Hashable {
    var date: String
    var day: Date
    /// 当日开盘累计余额。
    var open: Double
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
    var openingBalance: Double = 0
    var closingBalance: Double = 0
    var rangeLabel: String = ""

    var netTotal: Double { prizeTotal - costTotal }
    var isEmpty: Bool { days.isEmpty }
}

enum ProfitStats {

    /// 记入盈亏的日期：优先绑定的开奖日，其次记录创建日。
    static func profitDate(_ record: TicketRecord) -> String {
        for candidate in [record.targetOpenDate, record.targetOpenTime] where !candidate.isEmpty {
            if let date = DateText.parse(candidate) { return DateText.day(date) }
        }
        return DateText.day(record.createdAt)
    }

    /// 累计盈亏折线。只统计已经有结论的记录（中奖 / 未中奖），
    /// 待核对和奖金浮动的不计入，避免曲线来回跳。
    static func series(records: [TicketRecord], range: ProfitRange, now: Date = Date()) -> ProfitSeries {
        var settled = records
            .filter { $0.status == .won || $0.status == .lost }
            .sorted {
                let lhs = profitDate($0), rhs = profitDate($1)
                return lhs == rhs ? $0.createdAt < $1.createdAt : lhs < rhs
            }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DateText.chinaTimeZone

        if range == .month {
            let monthKey = String(DateText.day(now).prefix(7))
            settled = settled.filter { profitDate($0).hasPrefix(monthKey) }
        }

        var byDay: [String: [TicketRecord]] = [:]
        for record in settled { byDay[profitDate(record), default: []].append(record) }
        let availableDates = byDay.keys.sorted()
        guard let endDate = availableDates.last, let firstDate = availableDates.first else {
            return ProfitSeries(rangeLabel: range.label)
        }

        // 起点：全部=最早一天；本月=当月1号；近N天=末日往前推 N-1 天。
        var startDate = firstDate
        switch range {
        case .all:
            break
        case .month:
            startDate = String(DateText.day(now).prefix(7)) + "-01"
        case .week, .quarter:
            let span = Int(range.rawValue) ?? 7
            if let end = DateText.parse(endDate),
               let shifted = calendar.date(byAdding: .day, value: -(max(span, 1) - 1), to: end) {
                startDate = DateText.day(shifted)
            }
        }

        // 区间之前的记录压成一个起始余额，曲线才接得上。
        let openingBalance = settled
            .filter { profitDate($0) < startDate }
            .reduce(0) { $0 + $1.netProfit }

        guard let start = DateText.parse(startDate), let end = DateText.parse(endDate) else {
            return ProfitSeries(rangeLabel: range.label)
        }

        var days: [ProfitDay] = []
        var balance = openingBalance
        var cursor = start
        while cursor <= end {
            let key = DateText.day(cursor)
            let dayRecords = byDay[key] ?? []
            let open = balance
            var cost = 0.0
            var prize = 0.0
            var byGame: [GameKey: GameSpend] = [:]
            for record in dayRecords {
                cost += record.cost
                prize += record.prizeAmount
                balance += record.netProfit
                var spend = byGame[record.game] ?? GameSpend(game: record.game, cost: 0, prize: 0, count: 0)
                spend.cost += record.cost
                spend.prize += record.prizeAmount
                spend.count += 1
                byGame[record.game] = spend
            }
            days.append(ProfitDay(
                date: key,
                day: cursor,
                open: open,
                close: balance,
                cost: cost,
                prize: prize,
                count: dayRecords.count,
                wonCount: dayRecords.filter { $0.status == .won }.count,
                games: byGame.values.sorted { $0.cost > $1.cost }
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        // "全部"范围在最前面补一个 0 基线点，曲线从零起步更直观。
        if range == .all, let first = days.first,
           let baselineDay = calendar.date(byAdding: .day, value: -1, to: first.day) {
            days.insert(ProfitDay(date: DateText.day(baselineDay), day: baselineDay,
                                  open: 0, close: 0, cost: 0, prize: 0,
                                  count: 0, wonCount: 0, games: []), at: 0)
        }

        return ProfitSeries(
            days: days,
            costTotal: days.reduce(0) { $0 + $1.cost },
            prizeTotal: days.reduce(0) { $0 + $1.prize },
            openingBalance: openingBalance,
            closingBalance: balance,
            rangeLabel: range.label
        )
    }

    // MARK: - 统计页

    /// 按年或年月汇总。`month` 为 nil 表示全年。
    struct PeriodStats {
        var cost: Double = 0
        var prize: Double = 0
        var ticketCount: Int = 0
        var wonCount: Int = 0
        var byGame: [GameSpend] = []
        var byDay: [String: ProfitDay] = [:]
        var byMonth: [Int: [GameSpend]] = [:]

        var net: Double { prize - cost }
        var winRate: Double { ticketCount > 0 ? Double(wonCount) / Double(ticketCount) * 100 : 0 }
    }

    static func period(records: [TicketRecord], year: Int, month: Int?) -> PeriodStats {
        var stats = PeriodStats()
        var byGame: [GameKey: GameSpend] = [:]
        var byMonthGame: [Int: [GameKey: GameSpend]] = [:]
        var byDay: [String: ProfitDay] = [:]

        for record in records {
            let date = profitDate(record)
            let parts = date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, parts[0] == year else { continue }
            if let month, parts[1] != month { continue }

            stats.cost += record.cost
            stats.prize += record.prizeAmount
            stats.ticketCount += 1
            if record.status == .won { stats.wonCount += 1 }

            var spend = byGame[record.game] ?? GameSpend(game: record.game, cost: 0, prize: 0, count: 0)
            spend.cost += record.cost
            spend.prize += record.prizeAmount
            spend.count += 1
            byGame[record.game] = spend

            var monthMap = byMonthGame[parts[1]] ?? [:]
            var monthSpend = monthMap[record.game] ?? GameSpend(game: record.game, cost: 0, prize: 0, count: 0)
            monthSpend.cost += record.cost
            monthSpend.prize += record.prizeAmount
            monthSpend.count += 1
            monthMap[record.game] = monthSpend
            byMonthGame[parts[1]] = monthMap

            var day = byDay[date] ?? ProfitDay(date: date, day: DateText.parse(date) ?? Date(),
                                               open: 0, close: 0, cost: 0, prize: 0,
                                               count: 0, wonCount: 0, games: [])
            day.cost += record.cost
            day.prize += record.prizeAmount
            day.count += 1
            if record.status == .won { day.wonCount += 1 }
            byDay[date] = day
        }

        stats.byGame = byGame.values.sorted { $0.cost > $1.cost }
        stats.byDay = byDay
        stats.byMonth = byMonthGame.mapValues { $0.values.sorted { $0.cost > $1.cost } }
        return stats
    }

    /// 记录里出现过的年份，倒序。
    static func availableYears(records: [TicketRecord]) -> [Int] {
        let years = Set(records.compactMap { Int(profitDate($0).prefix(4)) })
        let current = Calendar.current.component(.year, from: Date())
        return Array(years.union([current])).sorted(by: >)
    }
}
