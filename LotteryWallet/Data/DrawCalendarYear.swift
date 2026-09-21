import Foundation

/// 整年开奖日历。
///
/// 每个彩种全年每一期的期号、开奖日期、开奖时刻、停售时刻都是静态的：
/// 期号顺延、春节国庆休市这些规则都在生成端用真实开奖记录逐期比对验证过，
/// App 只读，不做任何推算。
///
/// **这是业务模型，不是线上结构。** V2 的 `/v2/calendar/{year}` 返回的是
/// 一个扁平数组、时刻不带日期，转换在 `LotteryV2Mapper.calendarYear` 里做。
struct DrawCalendarYear: Sendable {
    var year: Int
    var lotteries: [String: GameYearCalendar]

    func entry(for game: GameKey) -> GameYearCalendar? {
        lotteries[game.apiKey] ?? lotteries[game.rawValue]
    }
}

struct GameYearCalendar: Sendable {
    var name: String
    var drawWeekdays: [Int]
    /// "21:15"
    var drawTime: String
    /// "20:00"
    var saleCloseTime: String
    var issues: [CalendarIssue]

}

/// 一期。`drawTime` / `saleCloseTime` 是完整时刻 "2026-01-01 21:15:00"。
struct CalendarIssue: Sendable, Hashable, Identifiable {
    var issue: String
    var drawDate: String
    var weekday: Int
    var drawTime: String
    var saleCloseTime: String

    var id: String { issue }


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
