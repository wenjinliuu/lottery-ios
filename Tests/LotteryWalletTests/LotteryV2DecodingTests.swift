import XCTest
@testable import LotteryWallet

/// V2 响应的解码与转换。
///
/// 这一层错了不会崩、不会红，只会「什么都没有」—— 界面上是一片空白加一行
/// 「暂无数据」，看不出是网络没通还是某个字段改了名。所以每一个端点、
/// 每一种缺字段的情形都得钉一遍。
final class LotteryV2DecodingTests: XCTestCase {

    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try decoder.decode(T.self, from: data)
    }

    // MARK: - bootstrap

    func testBootstrapDecodesLatestAndSchedule() throws {
        let payload = try decode(LotteryV2.Bootstrap.self, LotteryV2Fixtures.bootstrap)
        let result = LotteryV2Mapper.bootstrap(payload)

        XCTAssertEqual(result.latest.count, 4)
        XCTAssertEqual(result.schedules.count, 4)
        XCTAssertEqual(result.generatedAt, "2026-09-21T00:52:29.144+08:00")

        let ssq = try XCTUnwrap(result.latest.first { $0.gameKey == .ssq })
        XCTAssertEqual(ssq.expect, "2026109")
        XCTAssertEqual(ssq.openDate, "2026-09-20")
        XCTAssertEqual(ssq.drawValues[.red], [9, 12, 15, 26, 30, 33])
        XCTAssertEqual(ssq.drawValues[.blue], [6])
    }

    /// 远端叫 `kl8`，App 内部叫 `k8`。两边对不上时的表现是
    /// 「其它七个彩种都好，就快乐8 没有数据」。
    func testBootstrapMapsKL8ToK8() throws {
        let payload = try decode(LotteryV2.Bootstrap.self, LotteryV2Fixtures.bootstrap)
        let result = LotteryV2Mapper.bootstrap(payload)

        let k8 = try XCTUnwrap(result.latest.first { $0.gameKey == .k8 })
        XCTAssertEqual(k8.expect, "2026253")
        XCTAssertEqual(k8.drawValues[.nums].count, 20)
        XCTAssertNotNil(result.schedules[.k8])
        XCTAssertEqual(result.schedules[.k8]?.drawTime, "21:30")
    }

    /// 号码区每个彩种一种形状，错一个就是整版号码球画错。
    func testNumbersLayoutPerGame() throws {
        let payload = try decode(LotteryV2.Bootstrap.self, LotteryV2Fixtures.bootstrap)
        let result = LotteryV2Mapper.bootstrap(payload)

        // 七乐彩：7 个基本号 + 1 个特别号
        let qlc = try XCTUnwrap(result.latest.first { $0.gameKey == .qlc })
        XCTAssertEqual(qlc.drawValues[.nums7], [11, 13, 19, 20, 25, 28, 29])
        XCTAssertEqual(qlc.drawValues[.special], [26])

        // 七星彩：digits 是 7 位，前六位一组、末位单独一组
        let qxc = try XCTUnwrap(result.latest.first { $0.gameKey == .qxc })
        XCTAssertEqual(qxc.drawValues[.nums6], [2, 9, 0, 5, 0, 3])
        XCTAssertEqual(qxc.drawValues[.tail], [9])
    }

    /// 服务端省略空字段是常态。少一堆字段不能把整份响应打挂。
    func testSparseBootstrapStillDecodes() throws {
        let payload = try decode(LotteryV2.Bootstrap.self,
                                 Data(LotteryV2Fixtures.sparseBootstrapJSON.utf8))
        let result = LotteryV2Mapper.bootstrap(payload)

        XCTAssertEqual(result.latest.count, 1)
        let ssq = try XCTUnwrap(result.latest.first)
        // pool / sales / prizes / fetched_at 全缺，不该是错误，只该是空值
        XCTAssertEqual(ssq.saleAmount, "")
        XCTAssertEqual(ssq.totalMoney, "")
        XCTAssertTrue(ssq.prizeList.isEmpty)
        // draw_time / sale_close_time 缺失
        XCTAssertEqual(result.schedules[.ssq]?.drawTime, "")
    }

    // MARK: - 下一期的语义

    /// `confirmed == false` 时一律降级成「预计」，不管 `status` 写的是什么。
    ///
    /// 把推算值当官方值展示，用户会照着它去买票 —— 期号错了，
    /// 这张票就永远核对不上。
    func testUnconfirmedNextDrawIsInferred() throws {
        let payload = try decode(LotteryV2.Bootstrap.self, LotteryV2Fixtures.bootstrap)
        let result = LotteryV2Mapper.bootstrap(payload)

        let next = try XCTUnwrap(result.schedules[.ssq]?.next)
        XCTAssertEqual(next.status, .inferred)
        XCTAssertFalse(next.confirmed)
        XCTAssertEqual(next.issue, "2026110")
        XCTAssertEqual(next.openTime, "2026-09-22 21:15:00")
        XCTAssertEqual(next.basisIssue, "2026109")
    }

    func testConfirmedNextDrawStaysConfirmed() throws {
        let payload = try decode(LotteryV2.Bootstrap.self, LotteryV2Fixtures.bootstrap)
        let result = LotteryV2Mapper.bootstrap(payload)

        let next = try XCTUnwrap(result.schedules[.qlc]?.next)
        XCTAssertEqual(next.status, .confirmed)
        XCTAssertTrue(next.confirmed)
    }

    /// `status == unavailable`：服务端也给不出下一期，客户端不许自己编。
    func testUnavailableNextDrawProducesNothingUsable() throws {
        let payload = try decode(LotteryV2.Bootstrap.self,
                                 Data(LotteryV2Fixtures.sparseBootstrapJSON.utf8))
        let result = LotteryV2Mapper.bootstrap(payload)

        let next = try XCTUnwrap(result.schedules[.ssq]?.next)
        XCTAssertEqual(next.status, .unavailable)
        XCTAssertFalse(next.isUsable)
        XCTAssertTrue(next.issue.isEmpty)
    }

    // MARK: - 最近 30 期 / 按年

    func testRecentDrawsDecode() throws {
        let payload = try decode(LotteryV2.DrawsPayload.self, LotteryV2Fixtures.recentDraws)
        XCTAssertEqual(payload.limit, 30, "服务端上限是 30 期，不要再按 50 期设计")
        let draws = LotteryV2Mapper.draws(payload.draws, game: .ssq)
        XCTAssertEqual(draws.map(\.expect), ["2026109", "2026108"])
    }

    /// 奖级字段名 V2 和 V1 全不一样，对错了整张奖级表都是空的。
    func testPrizeFieldsAreRemapped() throws {
        let payload = try decode(LotteryV2.DrawsPayload.self, LotteryV2Fixtures.recentDraws)
        let draws = LotteryV2Mapper.draws(payload.draws, game: .ssq)
        let withPrizes = try XCTUnwrap(draws.first { !$0.prizeList.isEmpty })
        let first = try XCTUnwrap(withPrizes.prizeList.first)

        XCTAssertEqual(first.prizeName, "一等奖")   // name
        XCTAssertEqual(first.require, "中6+1")      // match
        XCTAssertEqual(first.winningCount, 2)       // winners
        XCTAssertEqual(first.amount, 10_000_000)    // amount
    }

    /// 奖级整个缺失时不能当成解码失败 —— 当期没公布奖级是正常情况。
    func testDrawWithoutPrizesIsStillADraw() throws {
        let payload = try decode(LotteryV2.DrawsPayload.self, LotteryV2Fixtures.recentDraws)
        let draws = LotteryV2Mapper.draws(payload.draws, game: .ssq)
        let latest = try XCTUnwrap(draws.first)
        XCTAssertTrue(latest.prizeList.isEmpty)
        XCTAssertFalse(latest.drawValues[.red].isEmpty)
    }

    /// 现行契约：`year` / `earliest_year` 都是 JSON 数字。
    func testYearPayloadReadsNumericYearAndBoundary() throws {
        let payload = try decode(LotteryV2.YearPayload.self, LotteryV2Fixtures.yearDraws)
        XCTAssertEqual(payload.year.text, "2026")
        XCTAssertEqual(payload.earliestYear.text, "2026")
        XCTAssertEqual(LotteryV2Mapper.draws(payload.draws, game: .ssq).count, 2)
    }

    /// 迁移之前生成的 GitHub 镜像：`year` 是**字符串**，没有 `earliest_year`。
    ///
    /// 镜像要等下一次导出才更新，在那之前读到的就是这一份。写死 `Int?` 的话
    /// 整份响应解码失败 —— 表现是「查看今年全部」永远没反应，而且不报错。
    func testYearPayloadStillReadsLegacyStringYear() throws {
        let payload = try decode(LotteryV2.YearPayload.self, LotteryV2Fixtures.legacyYearDraws)
        XCTAssertEqual(payload.year.text, "2026")
        XCTAssertTrue(payload.earliestYear.text.isEmpty)
        XCTAssertEqual(LotteryV2Mapper.draws(payload.draws, game: .ssq).count, 1)
    }

    // MARK: - 年度日历

    /// V2 的日历是扁平数组、时刻不带日期，必须还原成按彩种分组的完整时刻。
    func testCalendarRegroupsAndJoinsDateTime() throws {
        let payload = try decode(LotteryV2.CalendarPayload.self, LotteryV2Fixtures.calendar)
        let year = LotteryV2Mapper.calendarYear(payload, year: 2026)

        XCTAssertEqual(year.year, 2026)
        let ssq = try XCTUnwrap(year.entry(for: .ssq))
        XCTAssertEqual(ssq.issues.map(\.issue), ["2026001", "2026002"])

        let first = try XCTUnwrap(ssq.issues.first)
        // 这是整条链上最容易断的一环：只给 "21:15:00" 的话 DateText 解不出时间点，
        // `isOnSale` 永远返回 false，录入页会直接找不到可绑定的期次。
        XCTAssertEqual(first.drawTime, "2026-01-01 21:15:00")
        XCTAssertEqual(first.saleCloseTime, "2026-01-01 20:00:00")
        XCTAssertNotNil(first.saleClosesAt)
        XCTAssertNotNil(first.drawsAt)
    }

    /// V2 条目里没有 weekday，得自己从日期算，而且编号要和 `ChinaClock` 一致。
    func testCalendarDerivesWeekday() throws {
        let payload = try decode(LotteryV2.CalendarPayload.self, LotteryV2Fixtures.calendar)
        let year = LotteryV2Mapper.calendarYear(payload, year: 2026)
        let ssq = try XCTUnwrap(year.entry(for: .ssq))

        // 2026-01-01 是周四 → 4；2026-01-04 是周日 → 0
        XCTAssertEqual(ssq.issues.first?.weekday, 4)
        XCTAssertEqual(ssq.issues.last?.weekday, 0)
        XCTAssertEqual(Set(ssq.drawWeekdays), [0, 4])
    }

    /// 快乐8 在日历里也要按 `kl8` 认出来。
    func testCalendarMapsKL8() throws {
        let payload = try decode(LotteryV2.CalendarPayload.self, LotteryV2Fixtures.calendar)
        let year = LotteryV2Mapper.calendarYear(payload, year: 2026)
        XCTAssertEqual(year.entry(for: .k8)?.issues.count, 2)
    }

    /// 期次在售判断照旧可用 —— 这是录入页能不能绑定期号的地基。
    func testCalendarIssueStaysSellableBeforeCutoff() throws {
        let payload = try decode(LotteryV2.CalendarPayload.self, LotteryV2Fixtures.calendar)
        let year = LotteryV2Mapper.calendarYear(payload, year: 2026)
        let first = try XCTUnwrap(year.entry(for: .ssq)?.issues.first)

        let before = try XCTUnwrap(DateText.parse("2026-01-01 19:59:00"))
        let after = try XCTUnwrap(DateText.parse("2026-01-01 20:01:00"))
        XCTAssertTrue(first.isOnSale(at: before))
        XCTAssertFalse(first.isOnSale(at: after))
    }

    // MARK: - 数据源体检

    /// V1 的 `health.json` 用 `ok` + `updated_at`，实测就长这样。
    func testHealthAcceptsOkBool() throws {
        let json = """
        {"schema":"random_draw_agent_public_data_health","version":1,
         "ok":true,"updated_at":"2026-09-21T00:52:29.144+08:00",
         "message":"exported_from_cloudbase",
         "results":[{"lottery_type":"ssq","issue":"2026109","draw_date":"2026-09-20"},
                    {"lottery_type":"kl8","issue":"2026253","draw_date":"2026-09-20"}]}
        """
        let health = LotteryV2Mapper.health(try decode(LotteryV2.Health.self, Data(json.utf8)))
        XCTAssertEqual(health.isHealthy, true)
        XCTAssertEqual(health.label, "正常")
        XCTAssertEqual(health.message, "exported_from_cloudbase")
        XCTAssertEqual(health.gameCount, 2)
    }

    /// 文档没给 `/v2/health` 的 schema，GitHub 的 V2 镜像里也没有这个文件，
    /// 所以另一种常见写法（`status` 字符串 + `generated_at`）也必须认。
    func testHealthAcceptsStatusString() throws {
        let json = """
        {"status":"ok","generated_at":"2026-09-21T00:00:00+08:00","message":"fine"}
        """
        let health = LotteryV2Mapper.health(try decode(LotteryV2.Health.self, Data(json.utf8)))
        XCTAssertEqual(health.isHealthy, true)
        XCTAssertEqual(health.updatedAt, "2026-09-21T00:00:00+08:00")
    }

    func testHealthReportsNotOk() throws {
        let json = """
        {"ok": false, "message": "scrape stalled"}
        """
        let health = LotteryV2Mapper.health(try decode(LotteryV2.Health.self, Data(json.utf8)))
        XCTAssertEqual(health.isHealthy, false)
        XCTAssertEqual(health.label, "异常")
    }

    /// 两套字段都没有时不许瞎猜「正常」——  那会把故障说成健康。
    func testHealthWithoutAnyFlagIsUnknown() throws {
        let health = LotteryV2Mapper.health(try decode(LotteryV2.Health.self, Data("{}".utf8)))
        XCTAssertNil(health.isHealthy)
        XCTAssertEqual(health.label, "未知")
    }

    func testJoinDateTimeLeavesCompleteValuesAlone() {
        XCTAssertEqual(LotteryV2Mapper.joinDateTime("2026-01-01", "21:15:00"), "2026-01-01 21:15:00")
        // 已经是完整时刻就别再拼一次
        XCTAssertEqual(LotteryV2Mapper.joinDateTime("2026-01-01", "2026-01-01 21:15:00"),
                       "2026-01-01 21:15:00")
        // 没有时刻就不要造半截字符串出来
        XCTAssertEqual(LotteryV2Mapper.joinDateTime("2026-01-01", ""), "")
    }
}
