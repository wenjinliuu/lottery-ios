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

    /// 「数据源更新时间」取各彩种 `fetched_at` 里**最晚**的一条。
    ///
    /// 和 `generated_at` 是两回事：后者是这份文件拼出来的时刻，每次导出都变，
    /// 哪怕后端一个号码都没抓到；前者是号码和金额真正落库的时刻。
    /// fixture 里 generated_at 是 09-21 00:52，而最晚的 fetched_at 是
    /// 09-20 21:44 —— 两个值不一样，正好证明没有拿错。
    func testBootstrapTakesLatestFetchedAt() throws {
        let payload = try decode(LotteryV2.Bootstrap.self, LotteryV2Fixtures.bootstrap)
        let result = LotteryV2Mapper.bootstrap(payload)

        XCTAssertEqual(result.fetchedAt, "2026-09-20T21:44:07.049+08:00")
        XCTAssertNotEqual(result.fetchedAt, result.generatedAt)
    }

    /// 服务端省略 `fetched_at` 时给空串，不能崩也不能瞎编一个时间。
    func testBootstrapWithoutFetchedAtIsEmpty() throws {
        let payload = try decode(LotteryV2.Bootstrap.self, Data(LotteryV2Fixtures.sparseBootstrapJSON.utf8))
        let result = LotteryV2Mapper.bootstrap(payload)

        XCTAssertTrue(result.fetchedAt.isEmpty)
        XCTAssertFalse(result.latest.isEmpty, "前提：这份 fixture 本身是能解出开奖记录的")
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

    /// 契约违例必须**抛出来并说清缺了什么**，不能变成一个「状态未知」的结果。
    private func expectContractViolation(_ json: String,
                                         mentioning fragment: String,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        let dto = try decode(LotteryV2.Health.self, Data(json.utf8))
        XCTAssertThrowsError(try LotteryV2Mapper.health(dto), file: file, line: line) { error in
            guard case LotteryDataError.contractViolation(_, let problems) = error else {
                return XCTFail("应该是契约违例，实际是 \(error)", file: file, line: line)
            }
            XCTAssertTrue(problems.contains { $0.contains(fragment) },
                          "契约违例里应该提到「\(fragment)」，实际是 \(problems)",
                          file: file, line: line)
        }
    }

    func testHealthDecodesFormalContract() throws {
        let health = try LotteryV2Mapper.health(
            try decode(LotteryV2.Health.self, LotteryV2Fixtures.health))

        XCTAssertTrue(health.isHealthy)
        XCTAssertEqual(health.label, "正常")
        XCTAssertEqual(health.generatedAt, "2026-09-21T11:31:00+08:00")
        XCTAssertEqual(health.source, "cloudbase_postgresql")
        XCTAssertEqual(health.reportedGames, 2)
        XCTAssertTrue(health.missingGames.isEmpty)
    }

    /// 某个彩种没有记录时它的值是 `null`，同时 `ok` 为 `false`。
    /// 把缺的那几个列出来 —— 那基本就是「异常」的原因。
    func testHealthListsGamesWithoutRecords() throws {
        let health = try LotteryV2Mapper.health(
            try decode(LotteryV2.Health.self, Data(LotteryV2Fixtures.unhealthyJSON.utf8)))

        XCTAssertFalse(health.isHealthy)
        XCTAssertEqual(health.label, "异常")
        XCTAssertEqual(health.missingGames, ["qlc"])
        XCTAssertEqual(health.reportedGames, 1)
    }

    /// **这条是这次改动的核心。**
    ///
    /// V1 那份 `health.json` 用的是 `status` / `updated_at` / `message`，
    /// V2 明确不返回它们。上一版把两套字段都当兼容项收下，于是读到一份
    /// 不符合 V2 契约的东西也「解码成功」，界面显示「未知」，而没人分得清
    /// 是数据源没给还是我们字段写错了。现在它必须当场报出来。
    func testLegacyV1HealthIsRejectedNotSilentlyUnknown() throws {
        try expectContractViolation(LotteryV2Fixtures.legacyHealthJSON, mentioning: "schema")
    }

    func testMissingOkIsAContractViolation() throws {
        try expectContractViolation("""
        {"schema": "duigehao.lottery.health", "version": 2,
         "generated_at": "2026-09-21T11:31:00+08:00",
         "source": "cloudbase_postgresql", "latest": {}}
        """, mentioning: "ok")
    }

    func testMissingGeneratedAtIsAContractViolation() throws {
        try expectContractViolation("""
        {"schema": "duigehao.lottery.health", "version": 2, "ok": true,
         "source": "cloudbase_postgresql", "latest": {}}
        """, mentioning: "generated_at")
    }

    func testMissingSourceIsAContractViolation() throws {
        try expectContractViolation("""
        {"schema": "duigehao.lottery.health", "version": 2, "ok": true,
         "generated_at": "2026-09-21T11:31:00+08:00", "latest": {}}
        """, mentioning: "source")
    }

    func testMissingLatestIsAContractViolation() throws {
        try expectContractViolation("""
        {"schema": "duigehao.lottery.health", "version": 2, "ok": true,
         "generated_at": "2026-09-21T11:31:00+08:00", "source": "cloudbase_postgresql"}
        """, mentioning: "latest")
    }

    /// `schema` 和 `version` 是契约里的固定值。对不上就说明打到的不是这个
    /// 接口，或者契约变了 —— 两种都该当场说出来，而不是照老结构去读新东西。
    func testWrongVersionIsAContractViolation() throws {
        try expectContractViolation("""
        {"schema": "duigehao.lottery.health", "version": 3, "ok": true,
         "generated_at": "2026-09-21T11:31:00+08:00",
         "source": "cloudbase_postgresql", "latest": {}}
        """, mentioning: "version")
    }

    /// 一次报全，不是报一个就停 —— 排查时最想知道的是「到底差多少」。
    func testAllMissingFieldsAreReportedTogether() throws {
        let dto = try decode(LotteryV2.Health.self, Data("{}".utf8))
        XCTAssertThrowsError(try LotteryV2Mapper.health(dto)) { error in
            guard case LotteryDataError.contractViolation(let endpoint, let problems) = error else {
                return XCTFail("应该是契约违例，实际是 \(error)")
            }
            XCTAssertEqual(endpoint, "/v2/health")
            XCTAssertEqual(problems.count, 6, "六个必需字段都该被点名：\(problems)")
        }
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
