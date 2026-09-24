import XCTest
@testable import LotteryWallet

/// 时间显示。两条都对着真实出现过的显示错误。
final class DateTextStampTests: XCTestCase {

    /// 备份列表上每一份都显示成「9月22日 00:00」，时分永远是零。
    ///
    /// 原因是写成了 `friendly(day(date))`：`day` 只产出 `yyyy-MM-dd`，
    /// 时分秒在那一步就没了，再交给 `friendly` 解析回来自然是 0 点。
    /// `stamp` 直接拿 `Date` 格式化，不绕字符串。
    func testStampKeepsTimeOfDay() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 22
        components.hour = 14
        components.minute = 37
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DateText.chinaTimeZone
        let date = calendar.date(from: components)!

        XCTAssertEqual(DateText.stamp(date), "9月22日 14:37")
        // 钉住那个 bug 本身：绕一道 day() 就会丢掉时分。
        XCTAssertEqual(DateText.friendly(DateText.day(date)), "9月22日 00:00")
        XCTAssertNotEqual(DateText.stamp(date), DateText.friendly(DateText.day(date)))
    }

    /// `padded` 的月日要补零，设置页那一行是定宽的状态行。
    func testPaddedZeroFillsMonthAndDay() {
        XCTAssertEqual(DateText.padded("2026-09-22T02:44:00+08:00"), "09月22日 02:44")
        XCTAssertEqual(DateText.padded("2026-01-05T09:05:00+08:00"), "01月05日 09:05")
    }

    /// 解析不出来就原样返回，不要显示成一个编出来的日期。
    func testPaddedPassesThroughGarbage() {
        XCTAssertEqual(DateText.padded("不是时间"), "不是时间")
        XCTAssertEqual(DateText.padded(""), "")
    }
}
