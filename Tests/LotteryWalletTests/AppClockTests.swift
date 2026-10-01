import XCTest
@testable import LotteryWallet

/// 示例模式的「今天」要落在示例数据的末尾，否则统计页、本月概览在截图里全是 0。
final class AppClockTests: XCTestCase {

    func testDemoTodayIsTheDayAfterTheLastDemoDraw() {
        // 示例数据 2026-06-01 至 09-27，见 Scripts/make-demo-data.py
        XCTAssertEqual(DateText.day(AppClock.demoToday), "2026-09-28")
    }

    /// 单元测试不带 --demo-data，走真实时间。
    func testNormalLaunchUsesTheRealClock() {
        XCTAssertLessThan(abs(AppClock.now.timeIntervalSinceNow), 5)
    }
}
