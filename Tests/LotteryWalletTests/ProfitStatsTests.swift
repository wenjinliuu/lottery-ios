import XCTest
@testable import LotteryWallet

/// 盈亏统计的回归测试。
/// 这一块正是导入备份后卡死的根源，重点锁两件事：
/// 累计值要对，点数不能随时间跨度无限增长。
final class ProfitStatsTests: XCTestCase {

    private func entry(_ day: String, cost: Double, prize: Double, game: GameKey = .ssq) -> SettledEntry {
        SettledEntry(day: day, game: game, cost: cost, prize: prize, isWon: prize > 0)
    }

    func testCumulativeBalance() {
        let entries = [
            entry("2026-01-01", cost: 10, prize: 0),
            entry("2026-01-02", cost: 10, prize: 50),
            entry("2026-01-03", cost: 20, prize: 0)
        ]
        let series = ProfitStats.series(entries: entries, range: .all)
        XCTAssertEqual(series.costTotal, 40)
        XCTAssertEqual(series.prizeTotal, 50)
        XCTAssertEqual(series.netTotal, 10)
        // "全部"范围会在最前面补一个 0 基线点
        XCTAssertEqual(series.days.first?.close, 0)
        XCTAssertEqual(series.days.last?.close, 10)
    }

    /// 同一天的多注要合并成一个点。
    func testSameDayEntriesCollapse() {
        let entries = [
            entry("2026-03-05", cost: 2, prize: 0),
            entry("2026-03-05", cost: 2, prize: 6),
            entry("2026-03-06", cost: 2, prize: 0)
        ]
        let series = ProfitStats.series(entries: entries, range: .half)
        XCTAssertEqual(series.days.count, 2)
        XCTAssertEqual(series.days.first?.count, 2)
        XCTAssertEqual(series.settledCount, 3)
    }

    /// 跨度很大时不能逐日填充，点数必须封顶。
    /// 早期实现按日历天逐天生成点，跨几年就是上万个点，直接把首页拖死。
    func testLongSpanIsDownsampled() {
        var entries: [SettledEntry] = []
        for year in 2020...2026 {
            for month in 1...12 {
                for day in [1, 11, 21] {
                    entries.append(entry(String(format: "%04d-%02d-%02d", year, month, day), cost: 2, prize: 0))
                }
            }
        }
        let series = ProfitStats.series(entries: entries, range: .all)
        XCTAssertLessThanOrEqual(series.days.count, ProfitStats.maxChartPoints)
        // 抽稀不能影响总额
        XCTAssertEqual(series.costTotal, Double(entries.count) * 2)
    }

    func testEmptyInput() {
        let series = ProfitStats.series(entries: [], range: .all)
        XCTAssertTrue(series.isEmpty)
        XCTAssertEqual(series.netTotal, 0)
    }

    /// 区间之前的记录要压进起始余额，曲线不能从零重新开始。
    func testEarlierEntriesFoldIntoOpeningBalance() {
        let entries = [
            entry("2026-01-01", cost: 100, prize: 0),
            entry("2026-06-15", cost: 2, prize: 0)
        ]
        let series = ProfitStats.series(entries: entries, range: .month,
                                        now: DateText.parse("2026-06-20") ?? Date())
        XCTAssertEqual(series.days.count, 1)
        // 6 月只花了 2 元，但累计余额要带上 1 月的 -100
        XCTAssertEqual(series.costTotal, 2)
        XCTAssertEqual(series.days.first?.close, -102)
    }

    func testPeriodGroupsByMonthAndGame() {
        let entries = [
            entry("2026-02-03", cost: 2, prize: 0, game: .ssq),
            entry("2026-02-04", cost: 4, prize: 10, game: .dlt),
            entry("2026-05-04", cost: 6, prize: 0, game: .ssq),
            entry("2025-05-04", cost: 8, prize: 0, game: .ssq)
        ]
        let year = ProfitStats.period(entries: entries, year: 2026, month: nil)
        XCTAssertEqual(year.cost, 12)
        XCTAssertEqual(year.prize, 10)
        XCTAssertEqual(year.byMonth[2]?.count, 2)
        XCTAssertEqual(year.byMonth[5]?.count, 1)

        let february = ProfitStats.period(entries: entries, year: 2026, month: 2)
        XCTAssertEqual(february.cost, 6)
        XCTAssertEqual(february.ticketCount, 2)
        XCTAssertEqual(february.byDay.count, 2)
    }

    /// 区间选项改过一轮（去掉近7天、90天改半年、新增一年）。
    /// 这个断言是给下次改动兜底的 —— 上次删 `.week` 时忘了改测试，CI 才发现。
    func testRangeOptions() {
        XCTAssertEqual(ProfitRange.allCases, [.month, .half, .year, .all])
        XCTAssertEqual(ProfitRange.half.gridSpan, 183)
        XCTAssertEqual(ProfitRange.year.gridSpan, 365)
        XCTAssertEqual(ProfitRange.month.label, "本月")
    }
}
