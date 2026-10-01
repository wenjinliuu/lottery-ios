import Foundation

/// 界面上「今天是哪天」的唯一来源。
///
/// 平时就是 `Date()`。`--demo-data` 启动时固定在示例数据最后一期的次日（2026-09-28）：
/// 示例票只到 09-27，真实日期一往后走，统计页默认的「本月」、首页的「本月概览」
/// 和逐日方格就会落到没有数据的月份 —— 商店截图里出现一屏 0 元。
enum AppClock {
    static let demoToday: Date = {
        var components = DateComponents(year: 2026, month: 9, day: 28, hour: 10)
        components.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    static var now: Date {
        ProcessInfo.processInfo.arguments.contains("--demo-data") ? demoToday : Date()
    }
}
