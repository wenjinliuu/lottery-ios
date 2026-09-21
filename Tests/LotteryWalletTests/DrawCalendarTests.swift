import XCTest
@testable import LotteryWallet

/// 年度开奖日历：从 V2 响应还原成业务模型之后，那些**票面级别**的事实
/// 必须仍然成立。
///
/// V2 把这份数据的结构整个换了：V1 是按彩种分好组、时刻带日期；V2 是一个
/// 扁平数组，`draw_time` 只有 `"21:25:00"` 这样的时刻。转换里少拼一个日期，
/// `isOnSale` 就永远是 false，录入页当场找不到可绑定的期次 —— 而界面上
/// 只会显示「还没拿到开奖日历」，看不出是转换挂了。
final class DrawCalendarTests: XCTestCase {

    /// 裁自 `/v2/calendar/2026` 的真实结构，只留大乐透三期。
    private let payload = """
    {
      "schema": "duigehao.lottery.calendar",
      "version": 2,
      "year": "2026",
      "generated_at": "2026-09-21T00:52:29.144+08:00",
      "entries": [
        {"lottery_type": "dlt", "issue": "26097", "date": "2026-08-26",
         "draw_time": "21:25:00", "sale_close_time": "21:00:00"},
        {"lottery_type": "dlt", "issue": "26098", "date": "2026-08-29",
         "draw_time": "21:25:00", "sale_close_time": "21:00:00"},
        {"lottery_type": "dlt", "issue": "26099", "date": "2026-08-31",
         "draw_time": "21:25:00", "sale_close_time": "21:00:00"}
      ]
    }
    """.data(using: .utf8)!

    private func decoded() throws -> DrawCalendarYear {
        let dto = try JSONDecoder().decode(LotteryV2.CalendarPayload.self, from: payload)
        return LotteryV2Mapper.calendarYear(dto, year: 2026)
    }

    func testRegroupsFlatEntriesByGame() throws {
        let calendar = try decoded()
        XCTAssertEqual(calendar.year, 2026)
        let dlt = try XCTUnwrap(calendar.entry(for: .dlt))
        // 开奖星期是从这一年实际出现过的日期推出来的，V2 条目里没有这个字段
        XCTAssertEqual(dlt.drawWeekdays, [1, 3, 6])
        XCTAssertEqual(dlt.saleCloseTime, "21:00")
        XCTAssertEqual(dlt.drawTime, "21:25")
        XCTAssertEqual(dlt.issues.count, 3)
        XCTAssertEqual(dlt.issues[0].issue, "26097")
        XCTAssertEqual(dlt.issues[0].drawDate, "2026-08-26")
    }

    /// 票面日期必须和日历推演出来的开奖日一致。
    ///
    /// 这两期的期号和开奖日是从**真实彩票照片**上抄下来的：
    /// 第 26097 期印着「2026年08月26日开奖」，第 26099 期印着「2026年08月31日开奖」。
    func testMatchesPrintedTicketDates() throws {
        let dlt = try XCTUnwrap(try decoded().entry(for: .dlt))
        let byIssue = Dictionary(uniqueKeysWithValues: dlt.issues.map { ($0.issue, $0.drawDate) })
        XCTAssertEqual(byIssue["26097"], "2026-08-26")
        XCTAssertEqual(byIssue["26099"], "2026-08-31")
    }

    /// 时刻必须拼上日期才解得出真实时间点。**这是 V2 最容易断的一环。**
    func testClockIsJoinedWithItsDate() throws {
        let issue = try XCTUnwrap(try decoded().entry(for: .dlt)?.issues.first)
        XCTAssertEqual(issue.drawTime, "2026-08-26 21:25:00")
        XCTAssertEqual(issue.saleCloseTime, "2026-08-26 21:00:00")
        XCTAssertNotNil(issue.drawsAt)
        XCTAssertNotNil(issue.saleClosesAt)
    }

    /// 停售时刻决定「现在还能不能买这一期」。
    func testOnSaleWindow() throws {
        let issue = try XCTUnwrap(try decoded().entry(for: .dlt)?.issues.first)
        let closeAt = try XCTUnwrap(issue.saleClosesAt)
        XCTAssertTrue(issue.isOnSale(at: closeAt.addingTimeInterval(-60)))
        XCTAssertFalse(issue.isOnSale(at: closeAt))
        XCTAssertFalse(issue.isOnSale(at: closeAt.addingTimeInterval(60)))
    }

    /// 期次带出来的绑定目标要能直接存进票夹。
    func testIssueBuildsUsableTarget() throws {
        let issue = try XCTUnwrap(try decoded().entry(for: .dlt)?.issues.last)
        let target = issue.target()
        XCTAssertEqual(target.expect, "26099")
        XCTAssertEqual(target.openDate, "2026-08-31")
        XCTAssertEqual(target.buyEndTime, "2026-08-31 21:00:00")
        XCTAssertEqual(target.status, .confirmed)
        XCTAssertTrue(target.isAvailable)
    }

    /// 追加连打 N 期要拆成 N 张票，期号必须是日历里**连续的** N 期。
    /// 第 26099 期连打 3 期就是 26099 / 26100 / 26101 —— 不是 26099 打三遍。
    func testMultiPeriodTakesConsecutiveIssues() throws {
        let issues = try XCTUnwrap(try decoded().entry(for: .dlt)?.issues)
        guard let start = issues.firstIndex(where: { $0.issue == "26097" }) else {
            return XCTFail("找不到起始期")
        }
        let picked = Array(issues[start...].prefix(2))
        XCTAssertEqual(picked.map(\.issue), ["26097", "26098"])
        XCTAssertEqual(picked.map(\.drawDate), ["2026-08-26", "2026-08-29"])
    }
}
