import Foundation

/// 整年开奖日历 `calendar/{year}.json`。
///
/// 这份文件在数据仓库里由 `scripts/build_draw_calendar.py` 一次性推演好，
/// 每个彩种全年每一期的期号、开奖日期、开奖时刻、停售时刻都是静态的。
/// App 只读，不做任何推算 —— 期号顺延、春节国庆休市这些规则都已经在
/// 生成端用真实开奖记录逐期比对验证过了。
struct DrawCalendarYear: Decodable, Sendable {
    var year: Int
    var lotteries: [String: GameYearCalendar]

    func entry(for game: GameKey) -> GameYearCalendar? {
        lotteries[game.remoteKey] ?? lotteries[game.rawValue]
    }
}

struct GameYearCalendar: Decodable, Sendable {
    var name: String
    var drawWeekdays: [Int]
    /// "21:15"
    var drawTime: String
    /// "20:00"
    var saleCloseTime: String
    var issues: [CalendarIssue]

    enum CodingKeys: String, CodingKey {
        case name
        case drawWeekdays = "draw_weekdays"
        case drawTime = "draw_time"
        case saleCloseTime = "sale_close_time"
        case issues
    }
}

/// 一期。`drawTime` / `saleCloseTime` 是完整时刻 "2026-01-01 21:15:00"。
struct CalendarIssue: Decodable, Sendable, Hashable, Identifiable {
    var issue: String
    var drawDate: String
    var weekday: Int
    var drawTime: String
    var saleCloseTime: String

    var id: String { issue }

    enum CodingKeys: String, CodingKey {
        case issue
        case drawDate = "draw_date"
        case weekday
        case drawTime = "draw_time"
        case saleCloseTime = "sale_close_time"
    }

    var saleClosesAt: Date? { DateText.parse(saleCloseTime) }
    var drawsAt: Date? { DateText.parse(drawTime) }

    /// 这一期现在还能不能买。停售时刻之前都算能买。
    func isOnSale(at now: Date) -> Bool {
        guard let close = saleClosesAt else { return false }
        return now < close
    }

    /// 录入页可以直接绑定的目标期次。
    func target(source: String = "draw_calendar") -> DrawTarget {
        DrawTarget(expect: issue,
                   openDate: drawDate,
                   openTime: drawTime,
                   buyEndTime: saleCloseTime,
                   status: .confirmed,
                   source: source,
                   basisIssue: issue,
                   isAvailable: true,
                   message: "")
    }
}
