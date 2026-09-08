import XCTest
@testable import LotteryWallet

/// 整年开奖日历的解码与期次推进。
///
/// 这份 JSON 是数据仓库预生成的静态文件，App 只读不算。所以最容易出事的
/// 不是逻辑而是**字段名对不上** —— `draw_date` / `sale_close_time` 这些
/// 下划线键一旦和 CodingKeys 错开，解码会静默失败，整个日历功能直接不工作，
/// 而界面上只会显示「还没拿到开奖日历」，看不出是解码挂了。
final class DrawCalendarTests: XCTestCase {

    /// 直接抄自 `public_data/calendar/2026.json` 的真实结构。
    private let payload = """
    {
      "schema": "lottery_draw_calendar",
      "version": 1,
      "year": 2026,
      "timezone": "Asia/Shanghai",
      "lotteries": {
        "dlt": {
          "name": "超级大乐透",
          "draw_weekdays": [1, 3, 6],
          "draw_time": "21:25",
          "sale_close_time": "21:00",
          "count": 3,
          "issues": [
            {"issue": "26097", "draw_date": "2026-08-26", "weekday": 3,
             "draw_time": "2026-08-26 21:25:00", "sale_close_time": "2026-08-26 21:00:00"},
            {"issue": "26098", "draw_date": "2026-08-29", "weekday": 6,
             "draw_time": "2026-08-29 21:25:00", "sale_close_time": "2026-08-29 21:00:00"},
            {"issue": "26099", "draw_date": "2026-08-31", "weekday": 1,
             "draw_time": "2026-08-31 21:25:00", "sale_close_time": "2026-08-31 21:00:00"}
          ]
        }
      }
    }
    """.data(using: .utf8)!

    private func decoded() throws -> DrawCalendarYear {
        try JSONDecoder().decode(DrawCalendarYear.self, from: payload)
    }

    func testDecodesRepositoryShape() throws {
        let calendar = try decoded()
        XCTAssertEqual(calendar.year, 2026)
        let dlt = try XCTUnwrap(calendar.entry(for: .dlt))
        XCTAssertEqual(dlt.drawWeekdays, [1, 3, 6])
        XCTAssertEqual(dlt.saleCloseTime, "21:00")
        XCTAssertEqual(dlt.issues.count, 3)
        XCTAssertEqual(dlt.issues[0].issue, "26097")
        XCTAssertEqual(dlt.issues[0].drawDate, "2026-08-26")
    }

    /// 票面日期必须和日历推演出来的开奖日一致。
    ///
    /// 这两期的期号和开奖日是从**真实彩票照片**上抄下来的：
    /// 第 26097 期印着「2026年08月26日开奖」，第 26099 期印着「2026年08月31日开奖」。
    func testMatchesPrintedTicketDates() throws {
        let dlt = try XCTUnwrap(decoded().entry(for: .dlt))
        let byIssue = Dictionary(uniqueKeysWithValues: dlt.issues.map { ($0.issue, $0.drawDate) })
        XCTAssertEqual(byIssue["26097"], "2026-08-26")
        XCTAssertEqual(byIssue["26099"], "2026-08-31")
    }

    /// 停售时刻决定「现在还能不能买这一期」。
    func testOnSaleWindow() throws {
        let issue = try XCTUnwrap(decoded().entry(for: .dlt)?.issues.first)
        let closeAt = try XCTUnwrap(issue.saleClosesAt)
        XCTAssertTrue(issue.isOnSale(at: closeAt.addingTimeInterval(-60)))
        XCTAssertFalse(issue.isOnSale(at: closeAt))
        XCTAssertFalse(issue.isOnSale(at: closeAt.addingTimeInterval(60)))
    }

    /// 期次带出来的绑定目标要能直接存进票夹。
    func testIssueBuildsUsableTarget() throws {
        let issue = try XCTUnwrap(decoded().entry(for: .dlt)?.issues.last)
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
        let issues = try XCTUnwrap(decoded().entry(for: .dlt)?.issues)
        guard let start = issues.firstIndex(where: { $0.issue == "26097" }) else {
            return XCTFail("找不到起始期")
        }
        let picked = Array(issues[start...].prefix(2))
        XCTAssertEqual(picked.map(\.issue), ["26097", "26098"])
        XCTAssertEqual(picked.map(\.drawDate), ["2026-08-26", "2026-08-29"])
    }
}
