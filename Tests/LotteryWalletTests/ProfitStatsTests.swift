import XCTest
@testable import LotteryWallet

/// 收支统计的回归测试。
/// 这一块正是导入备份后卡死的根源，重点锁两件事：
/// 累计值要对，点数不能随时间跨度无限增长。
final class ProfitStatsTests: XCTestCase {

    private func entry(_ day: String, cost: Double, prize: Double, game: GameKey = .ssq) -> SettledEntry {
        SettledEntry(day: day, game: game, cost: cost, prize: prize, isWon: prize > 0)
    }

    // MARK: - 中奖率

    /// 中奖率的分母是**已结算注数**，和 `settledCount` 同一个口径。
    func testWinRateCountsSettledOnly() {
        let entries = [
            entry("2026-01-01", cost: 10, prize: 0),
            entry("2026-01-02", cost: 10, prize: 50),
            entry("2026-01-03", cost: 10, prize: 5),
            entry("2026-01-04", cost: 10, prize: 0)
        ]
        let series = ProfitStats.series(entries: entries, range: .all)
        XCTAssertEqual(series.settledCount, 4)
        XCTAssertEqual(series.wonCount, 2)
        XCTAssertEqual(series.winRate, 50, accuracy: 0.001)
    }

    /// 一注都没有时不能除以零，也不该算成 0%。
    func testWinRateIsZeroWhenNothingSettled() {
        let series = ProfitStats.series(entries: [], range: .all)
        XCTAssertEqual(series.settledCount, 0)
        XCTAssertEqual(series.wonCount, 0)
        XCTAssertEqual(series.winRate, 0)
    }

    /// **抽稀不能吃掉中奖注数。**
    ///
    /// `days` 在点数超过 `maxChartPoints` 时会被合并，所以中奖注数必须在
    /// 抽稀之前累加好。写成「从 `series.days` 求和」的话这条会挂 ——
    /// 这正是这条用例存在的理由。
    func testWinRateSurvivesDownsampling() {
        var entries: [SettledEntry] = []
        var day = DateText.parse("2026-01-01")!
        // 远多于 maxChartPoints，逼出抽稀
        for index in 0..<(ProfitStats.maxChartPoints * 3) {
            entries.append(entry(DateText.day(day), cost: 10, prize: index % 4 == 0 ? 20 : 0))
            day = Calendar.chinaCalendar.date(byAdding: .day, value: 1, to: day)!
        }
        let series = ProfitStats.series(entries: entries, range: .all)
        // 前提：真的抽稀了。没抽稀这条用例就白测了。
        XCTAssertLessThan(series.days.count, entries.count)
        // 总数按**全部**记录算，不受抽稀影响。
        // `downsample` 是按下标**挑点**、不是合并，被挑掉的那些天整个消失；
        // 谁要是把 wonCount 改成从 `days` 求和，这里的 135 立刻对不上。
        XCTAssertEqual(series.settledCount, ProfitStats.maxChartPoints * 3)
        XCTAssertEqual(series.wonCount, entries.filter(\.isWon).count)
        XCTAssertEqual(series.winRate, 25, accuracy: 0.001)
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

    /// 公益金比例必须逐个彩种对上**真实票面**。
    ///
    /// 这些数字来自 `TicketTextParserTests` / `TicketTextParserGamesTests` 里的
    /// 样票：每张票底都印着「感谢您为公益事业贡献 X 元」，和票面合计一除
    /// 就是这个比例。原来首页一律乘 0.36，八个彩种里五个是错的。
    func testWelfareRateMatchesPrintedTickets() {
        // 票面合计 → 票面印的公益金
        let samples: [(GameKey, Double, Double)] = [
            (.ssq,  18, 6.48),   // 双色球样票
            (.dlt,  18, 6.48),   // 大乐透样票（另有 60/21.6、2772/997.92 等五张）
            (.qlc,   6, 2.16),   // 七乐彩样票
            (.qxc,  10, 3.70),   // 七星彩样票
            (.pl5,   4, 1.48),   // 排列5 样票
            (.fc3d, 10, 3.40),   // 福彩3D 样票
            (.pl3,   4, 1.36),   // 排列3 样票
            (.k8,    4, 1.20)    // 快乐8 样票
        ]
        for (game, total, printed) in samples {
            XCTAssertEqual(total * game.welfareRate, printed, accuracy: 0.001,
                           "\(game.label) 的公益金应与票面一致")
        }
        // 固定 0.36 的老写法必须已经被打破，否则这个测试形同虚设
        XCTAssertNotEqual(GameKey.k8.welfareRate, 0.36)
        XCTAssertNotEqual(GameKey.pl3.welfareRate, 0.36)
        XCTAssertNotEqual(GameKey.qxc.welfareRate, 0.36)
    }

    /// 公益金合计要逐条按彩种累加，不能拿总额乘一个比例。
    func testWelfareTotalIsSummedPerGame() {
        let entries = [
            entry("2026-05-01", cost: 100, prize: 0, game: .ssq),  // 0.36 → 36
            entry("2026-05-02", cost: 100, prize: 0, game: .k8)    // 0.30 → 30
        ]
        let series = ProfitStats.series(entries: entries, range: .all)
        XCTAssertEqual(series.welfareTotal, 66, accuracy: 0.001)
        // 拿总额乘 0.36 会得到 72 —— 正是这次要修掉的算法
        XCTAssertNotEqual(series.welfareTotal, series.costTotal * 0.36)
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
