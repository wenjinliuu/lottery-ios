import XCTest
@testable import LotteryWallet

/// 首页那张图背后的数：累计流水、按月汇总、拖动时的读数、开奖倒计时。
///
/// 图本身画得对不对靠截图看；这里守的是**图上的数和票夹里的数是不是同一个数**。
final class ProfitFlowTests: XCTestCase {

    private func entry(_ day: String, cost: Double, prize: Double, game: GameKey = .ssq) -> SettledEntry {
        SettledEntry(day: day, game: game, cost: cost, prize: prize, isWon: prize > 0)
    }

    private let entries: [SettledEntry] = [
        SettledEntry(day: "2026-08-30", game: .ssq, cost: 10, prize: 0, isWon: false),
        SettledEntry(day: "2026-09-02", game: .ssq, cost: 20, prize: 5, isWon: true),
        // 快乐8 的公益金比例是 30%，双色球是 36% —— 不能拿总额乘一个数
        SettledEntry(day: "2026-09-02", game: .k8, cost: 10, prize: 0, isWon: false),
        SettledEntry(day: "2026-09-10", game: .ssq, cost: 10, prize: 200, isWon: true)
    ]

    // MARK: - 累计

    /// 三条线都从零起步，每个点是**到那一天为止**的累计，最后一个点等于总数。
    func testFlowIsCumulativeAndStartsAtZero() throws {
        let series = ProfitStats.series(entries: entries, range: .all)
        XCTAssertEqual(series.flow.count, 4)      // 零点 + 三个有记录的日子
        XCTAssertEqual(series.flow.first?.cost, 0)
        XCTAssertEqual(series.flow.first?.prize, 0)
        XCTAssertEqual(series.flow.map(\.cost), [0, 10, 40, 50])
        XCTAssertEqual(series.flow.map(\.prize), [0, 0, 5, 205])
        let last = try XCTUnwrap(series.flow.last)
        XCTAssertEqual(last.cost, series.costTotal)
        XCTAssertEqual(last.prize, series.prizeTotal)
        XCTAssertEqual(last.welfare, series.welfareTotal, accuracy: 0.0001)
        // 10×0.36 + 20×0.36 + 10×0.30 + 10×0.36
        XCTAssertEqual(series.welfareTotal, 17.4, accuracy: 0.0001)
    }

    /// 零点在第一笔记录的前一天，线才是从左下角起步的。
    func testFlowOriginIsTheDayBeforeTheFirstRecord() throws {
        let series = ProfitStats.series(entries: entries, range: .all)
        let origin = try XCTUnwrap(series.flow.first)
        XCTAssertEqual(DateText.day(origin.day), "2026-08-29")
    }

    /// 抽稀只是少画点，剩下每个点上的累计值不能变，最后一个点必须留着。
    func testDownsamplingKeepsCumulativeTotals() throws {
        var many: [SettledEntry] = []
        let start = try XCTUnwrap(DateText.parse("2025-01-01"))
        for offset in 0..<400 {
            let day = try XCTUnwrap(Calendar.chinaCalendar.date(byAdding: .day, value: offset, to: start))
            many.append(entry(DateText.day(day), cost: 2, prize: offset % 50 == 0 ? 5 : 0))
        }
        let series = ProfitStats.series(entries: many, range: .all)
        XCTAssertLessThanOrEqual(series.flow.count, ProfitStats.maxChartPoints)
        XCTAssertEqual(series.flow.last?.cost, 800)
        XCTAssertEqual(series.flow.last?.prize, series.prizeTotal)
        // 累计值只增不减
        for (previous, next) in zip(series.flow, series.flow.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.cost, previous.cost)
        }
    }

    func testEmptySeriesHasNoFlow() {
        let series = ProfitStats.series(entries: [], range: .all)
        XCTAssertTrue(series.flow.isEmpty)
        XCTAssertTrue(series.months.isEmpty)
    }

    // MARK: - 每月

    func testMonthsSumToTotals() {
        let series = ProfitStats.series(entries: entries, range: .all)
        XCTAssertEqual(series.months.map(\.month), ["2026-08", "2026-09"])
        XCTAssertEqual(series.months.map(\.cost), [10, 40])
        XCTAssertEqual(series.months.map(\.prize), [0, 205])
        XCTAssertEqual(series.months.reduce(0) { $0 + $1.welfare }, series.welfareTotal, accuracy: 0.0001)
    }

    /// 中了大奖的月份奖金超过投入：柱子总高仍然等于投入，不能画出负的一段。
    func testMonthBarNeverExceedsItsCost() {
        let series = ProfitStats.series(entries: entries, range: .all)
        for month in series.months {
            XCTAssertEqual(month.prizeShown + month.welfareShown + month.rest, month.cost, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(month.welfareShown, 0)
            XCTAssertGreaterThanOrEqual(month.rest, 0)
        }
        // 八月没中奖：10 元 = 公益金 3.6 + 其余 6.4
        XCTAssertEqual(series.months[0].welfareShown, 3.6, accuracy: 0.0001)
        XCTAssertEqual(series.months[0].rest, 6.4, accuracy: 0.0001)
        // 九月奖金 205 > 投入 40：整根柱子都是奖金
        XCTAssertEqual(series.months[1].prizeShown, 40)
        XCTAssertEqual(series.months[1].welfareShown, 0)
    }

    /// 最多画最近十二个月，再多柱子就细得点不中了。
    func testMonthsAreCappedAtTwelve() throws {
        var many: [SettledEntry] = []
        for month in 1...12 { many.append(entry(String(format: "2025-%02d-05", month), cost: 2, prize: 0)) }
        for month in 1...6 { many.append(entry(String(format: "2026-%02d-05", month), cost: 2, prize: 0)) }
        let series = ProfitStats.series(entries: many, range: .all)
        XCTAssertEqual(series.months.count, 12)
        XCTAssertEqual(series.months.first?.month, "2025-07")
        XCTAssertEqual(series.months.last?.month, "2026-06")
    }

    // MARK: - 读数

    func testReadingShowsTotalsWhenNothingIsSelected() {
        let series = ProfitStats.series(entries: entries, range: .all)
        let reading = FlowReading.make(series: series, mode: .cumulative, day: nil, month: nil)
        XCTAssertEqual(reading.cost, 50)
        XCTAssertEqual(reading.prize, 205)
        // 奖金比投入多：第四格不能写「净支出 −155」
        XCTAssertEqual(reading.lastTitle, "净收入")
        XCTAssertEqual(reading.lastValue, 155)
        XCTAssertTrue(reading.lastIsGain)
    }

    /// 线是阶梯状的：两次购买之间的任何一天，读数都是前一次购买之后的累计。
    func testReadingSnapsToTheLastPointOnOrBeforeTheFinger() throws {
        let series = ProfitStats.series(entries: entries, range: .all)
        let between = try XCTUnwrap(DateText.parse("2026-09-06"))
        let reading = FlowReading.make(series: series, mode: .cumulative, day: between, month: nil)
        XCTAssertEqual(reading.caption, "截至 09-02")
        XCTAssertEqual(reading.cost, 40)
        XCTAssertEqual(reading.prize, 5)
        XCTAssertEqual(reading.lastTitle, "净支出")
        XCTAssertEqual(reading.lastValue, 35)

        // 手指拖到第一笔记录之前：按零点算，不能崩也不能跳到总数
        let early = try XCTUnwrap(DateText.parse("2026-01-01"))
        XCTAssertEqual(FlowReading.make(series: series, mode: .cumulative, day: early, month: nil).cost, 0)
    }

    func testMonthlyReadingFollowsTheSelectedBar() {
        let series = ProfitStats.series(entries: entries, range: .all)
        let picked = FlowReading.make(series: series, mode: .monthly, day: nil, month: "2026-08")
        XCTAssertEqual(picked.caption, "2026 年 8 月")
        XCTAssertEqual(picked.cost, 10)
        XCTAssertEqual(picked.lastTitle, "其余")
        XCTAssertEqual(picked.lastValue, 6.4, accuracy: 0.0001)
        // 选了一个图上没有的月份：退回总数
        XCTAssertEqual(FlowReading.make(series: series, mode: .monthly, day: nil, month: "2020-01").cost, 50)
        XCTAssertEqual(FlowReading.monthLabel("2026-09"), "9月")
    }

    func testEmptyReadingSaysSo() {
        let reading = FlowReading.make(series: ProfitSeries(), mode: .cumulative, day: nil, month: nil)
        XCTAssertEqual(reading.caption, "还没有已开奖的记录")
        XCTAssertEqual(reading.cost, 0)
    }

    // MARK: - 倒计时

    func testCountdownBadge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(DrawCountdown.badge(until: now.addingTimeInterval(2 * 3600 + 14 * 60 + 37), now: now), "今日开奖 2:14:37")
        XCTAssertEqual(DrawCountdown.badge(until: now.addingTimeInterval(14 * 60 + 5), now: now), "今日开奖 14:05")
        XCTAssertEqual(DrawCountdown.badge(until: now.addingTimeInterval(0.4), now: now), "今日开奖 0:01")
        // 到点和过点之后只剩「今日开奖」，不出现负数
        XCTAssertEqual(DrawCountdown.badge(until: now, now: now), "今日开奖")
        XCTAssertEqual(DrawCountdown.badge(until: now.addingTimeInterval(-600), now: now), "今日开奖")
    }
}
