import Foundation

/// 一个彩种的开奖日程。
///
/// ## 为什么它不再挂在 `Draw` 上
///
/// V1 的时候，「下一期是哪期、什么时候开、什么时候停售」这些信息是**跟着
/// 每一条开奖记录走的**（`Draw.nextExpect` / `nextOpenTime` / …），
/// 每一期都带一份。那套结构有两个毛病：同一个事实在几十条记录上重复，
/// 而且要想知道下一期，必须先拿到最新一期开奖。
///
/// V2 把它挪进了 `bootstrap.schedule`，一个彩种一份，和开奖记录解耦。
/// 这里照着这个形状建模。
struct DrawSchedule: Sendable, Hashable {
    let game: GameKey
    /// 官方名字，如「超级大乐透」。
    let name: String
    /// 开奖星期，**0 为周日**，和 `ChinaClock.weekday` 同一套。
    let weekdays: [Int]
    /// 开奖时刻 "21:15"。
    let drawTime: String
    /// 销售截止时刻 "20:00"。
    let saleCloseTime: String
    let next: NextDrawInfo?

    /// 今天开不开奖。
    func opensToday(_ now: ChinaClock) -> Bool {
        weekdays.contains(now.weekday)
    }

    /// 今天的开奖时刻过了没有。用来判断「该开了但号码还没更新」。
    func drawTimePassed(_ now: ChinaClock) -> Bool {
        guard drawTime.count >= 5 else { return false }
        return now.clock >= String(drawTime.prefix(5))
    }
}

/// 下一期开奖。
///
/// **`confirmed` 决定这份信息能不能当真。** 服务端在官方日历还没发布时
/// 会按周期推算一个出来，那种值只能以「预计」的语义展示；
/// `status == .unavailable` 表示服务端也给不出来，客户端不许自己编一个。
struct NextDrawInfo: Sendable, Hashable {
    let issue: String
    /// yyyy-MM-dd
    let date: String
    /// 完整时刻 "2026-09-22 21:15:00"
    let openTime: String
    let buyEndTime: String
    let status: NextDrawStatus
    let source: String
    let confirmed: Bool
    /// 推算所依据的那一期。
    let basisIssue: String

    var isUsable: Bool {
        status != .unavailable && !issue.isEmpty && !openTime.isEmpty && !buyEndTime.isEmpty
    }
}
