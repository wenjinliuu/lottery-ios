import XCTest
@testable import LotteryWallet

/// 渐进式加载：**数请求**。
///
/// 「冷启动只读 bootstrap」这种事，读代码读不出来，只能数。上一版冷启动
/// 一口气发 13 个请求（latest、calendar、health、两年日历、八个彩种的往期），
/// 而且每多一个页面就容易再悄悄多一个 —— 这一组用例就是防这个的。
@MainActor
final class ProgressiveLoadingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    /// 每个用例一个独立的缓存目录，免得上一个用例的缓存让这一个不发请求。
    private func makeStore(cacheFolder: String = UUID().uuidString) -> DrawStore {
        let client = LotteryAPIClient(session: StubURLProtocol.makeSession())
        let repository = LotteryRepository(client: client,
                                           cache: LotteryCache(folder: "tests/\(cacheFolder)"))
        return DrawStore(repository: repository)
    }

    private func stubEverything() {
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        for game in GameKey.ordered {
            StubURLProtocol.stub("v2/draws/\(game.apiKey)", body: LotteryV2Fixtures.recentDraws)
            for year in (ChinaClock.year() - 3)...ChinaClock.year() {
                StubURLProtocol.stub("v2/by-year/\(game.apiKey)/\(year)", body: LotteryV2Fixtures.yearDraws)
            }
        }
        for year in (ChinaClock.year() - 1)...(ChinaClock.year() + 1) {
            StubURLProtocol.stub("v2/calendar/\(year)", body: LotteryV2Fixtures.calendar)
        }
    }

    // MARK: - 冷启动

    /// **冷启动只有一个请求。** 这是整份改造最核心的一条。
    func testColdStartRequestsBootstrapOnly() async {
        stubEverything()
        let store = makeStore()
        await store.bootstrap()

        XCTAssertEqual(StubURLProtocol.requestCount, 1,
                       "冷启动发了 \(StubURLProtocol.requestCount) 个请求：\(StubURLProtocol.requestedPaths)")
        XCTAssertEqual(StubURLProtocol.count("v2/bootstrap"), 1)
    }

    /// 逐条钉住上一版冷启动做过、现在不该再做的事。
    func testColdStartTouchesNothingElse() async {
        stubEverything()
        let store = makeStore()
        await store.bootstrap()

        let paths = StubURLProtocol.requestedPaths
        XCTAssertFalse(paths.contains { $0.contains("/draws/") }, "冷启动不该拉任何彩种的最近开奖")
        XCTAssertFalse(paths.contains { $0.contains("/by-year/") }, "冷启动不该拉任何年度历史")
        XCTAssertFalse(paths.contains { $0.contains("/calendar/") }, "冷启动不该拉年度日历")
        XCTAssertFalse(paths.contains { $0.contains("health") }, "冷启动不该拉 health")
    }

    /// 冷启动之后首页要的东西必须齐：八个彩种的最新一期和开奖日程。
    func testBootstrapFillsHomeScreen() async {
        stubEverything()
        let store = makeStore()
        await store.bootstrap()

        XCTAssertEqual(store.bootstrapState, .loaded)
        XCTAssertNotNil(store.latestDraw(for: .ssq))
        XCTAssertNotNil(store.latestDraw(for: .k8))
        XCTAssertFalse(store.schedules.isEmpty)
        XCTAssertFalse(store.latestUpdatedAt.isEmpty)
    }

    // MARK: - 单彩种最近 30 期

    /// 进双色球历史，只请求双色球。不得顺带把另外七个拉下来。
    func testOpeningOneGameLoadsOnlyThatGame() async {
        stubEverything()
        let store = makeStore()
        await store.loadRecent(for: .ssq)

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertEqual(StubURLProtocol.count("v2/draws/ssq"), 1)
        for game in GameKey.ordered where game != .ssq {
            XCTAssertEqual(StubURLProtocol.count("v2/draws/\(game.apiKey)"), 0)
        }
    }

    /// 快乐8 走 `kl8` 这个远端标识。
    func testK8UsesKL8Path() async {
        stubEverything()
        let store = makeStore()
        await store.loadRecent(for: .k8)

        XCTAssertEqual(StubURLProtocol.count("v2/draws/kl8"), 1)
        XCTAssertFalse(store.draws(for: .k8).isEmpty)
    }

    /// 已经加载过就不再请求。`.task` / `onAppear` 会重复触发，这一条必须成立。
    func testAlreadyLoadedGameIsNotRefetched() async {
        stubEverything()
        let store = makeStore()
        await store.loadRecent(for: .ssq)
        await store.loadRecent(for: .ssq)
        await store.loadRecent(for: .ssq)

        XCTAssertEqual(StubURLProtocol.count("v2/draws/ssq"), 1)
    }

    /// 并发触发同一个彩种也只发一次。
    func testConcurrentLoadsCoalesce() async {
        stubEverything()
        let store = makeStore()
        async let a: Void = store.loadRecent(for: .ssq)
        async let b: Void = store.loadRecent(for: .ssq)
        async let c: Void = store.loadRecent(for: .ssq)
        _ = await (a, b, c)

        XCTAssertEqual(StubURLProtocol.count("v2/draws/ssq"), 1)
    }

    // MARK: - 按年历史

    /// 「查看全部」才请求当前年度，而且只请求这一年。
    func testViewAllRequestsCurrentYearOnly() async {
        stubEverything()
        let store = makeStore()
        let year = ChinaClock.year()
        await store.loadOlderHistory(for: .ssq)

        XCTAssertEqual(StubURLProtocol.count("v2/by-year/ssq/\(year)"), 1)
        XCTAssertEqual(StubURLProtocol.count("v2/by-year/ssq/\(year - 1)"), 0)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    /// 继续往前看时，一次只推进一年。
    func testOlderHistoryAdvancesOneYearAtATime() async {
        stubEverything()
        let store = makeStore()
        let year = ChinaClock.year()

        await store.loadOlderHistory(for: .ssq)
        XCTAssertEqual(store.nextYearToLoad(for: .ssq), year - 1)

        await store.loadOlderHistory(for: .ssq)
        XCTAssertEqual(store.nextYearToLoad(for: .ssq), year - 2)

        XCTAssertEqual(StubURLProtocol.count("v2/by-year/ssq/\(year)"), 1)
        XCTAssertEqual(StubURLProtocol.count("v2/by-year/ssq/\(year - 1)"), 1)
        XCTAssertEqual(StubURLProtocol.count("v2/by-year/ssq/\(year - 2)"), 0)
        XCTAssertEqual(store.loadedYears(for: .ssq), [year, year - 1])
    }

    /// 同一彩种同一年不会请求两次。
    func testSameYearIsNeverRequestedTwice() async {
        stubEverything()
        let store = makeStore()
        let year = ChinaClock.year()
        await store.loadYear(for: .ssq, year: year)
        await store.loadYear(for: .ssq, year: year)

        XCTAssertEqual(StubURLProtocol.count("v2/by-year/ssq/\(year)"), 1)
    }

    /// 某一年一条都没有，就说明到头了，不该再给「加载更早」。
    func testEmptyYearEndsTheHistory() async {
        StubURLProtocol.stub("v2/by-year/ssq/\(ChinaClock.year())",
                             body: Data("""
                             {"schema":"duigehao.lottery.year","version":2,
                              "lottery_type":"ssq","year":"2026","draws":[]}
                             """.utf8))
        let store = makeStore()
        await store.loadOlderHistory(for: .ssq)

        XCTAssertFalse(store.hasMoreHistory(for: .ssq))
        XCTAssertNil(store.nextYearToLoad(for: .ssq))
    }

    /// 最近 30 期和年度数据按期号去重，并按日期倒序。
    func testRecentAndYearMergeWithoutDuplicates() async {
        stubEverything()
        let store = makeStore()
        await store.loadRecent(for: .ssq)
        await store.loadYear(for: .ssq, year: ChinaClock.year())

        let rows = store.draws(for: .ssq)
        // 两份数据里 2026109 是同一期，合起来应该是 3 期而不是 4 期
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.expect), ["2026109", "2026108", "2026001"])
        XCTAssertEqual(Set(rows.map(\.expect)).count, rows.count)
    }

    // MARK: - 日历

    /// 日历按年取，默认只取当年。
    func testCalendarLoadsOneYear() async {
        stubEverything()
        let store = makeStore()
        // 固定在 9 月，避开「12 月要顺带取下一年」那条分支
        let september = DateText.parse("\(ChinaClock.year())-09-15 10:00:00")!
        await store.loadYearCalendars(september)

        XCTAssertEqual(StubURLProtocol.count("v2/calendar/\(ChinaClock.year())"), 1)
        XCTAssertEqual(StubURLProtocol.count("v2/calendar/\(ChinaClock.year() + 1)"), 0)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    /// 跨年那几天「下一期」会落到明年 001，那时候才需要明年的日历。
    func testCalendarAlsoLoadsNextYearInDecember() async {
        stubEverything()
        let store = makeStore()
        let december = DateText.parse("\(ChinaClock.year())-12-20 10:00:00")!
        await store.loadYearCalendars(december)

        XCTAssertEqual(StubURLProtocol.count("v2/calendar/\(ChinaClock.year())"), 1)
        XCTAssertEqual(StubURLProtocol.count("v2/calendar/\(ChinaClock.year() + 1)"), 1)
    }

    // MARK: - 数据源体检

    /// health **只有用户打开「开奖数据」详情页才请求**，而且只打 CloudBase。
    func testHealthIsOnDemandAndCloudBaseOnly() async {
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        StubURLProtocol.stub("v2/health", body: Data("""
        {"ok": true, "updated_at": "2026-09-21T00:00:00+08:00", "message": "ok"}
        """.utf8))
        let store = makeStore()

        await store.bootstrap()
        XCTAssertEqual(StubURLProtocol.count("v2/health"), 0, "冷启动不该碰 health")
        XCTAssertNil(store.health)

        await store.loadHealth()
        XCTAssertEqual(StubURLProtocol.count("v2/health"), 1)
        XCTAssertEqual(store.health?.isHealthy, true)
        // 它问的就是主数据源自己，不该回落到别处去问
        XCTAssertEqual(StubURLProtocol.count("v2/health.json"), 0)
    }

    /// 已经查过就不重复查，除非明确要求。
    func testHealthIsNotRefetched() async {
        StubURLProtocol.stub("v2/health", body: Data("{\"ok\": true}".utf8))
        let store = makeStore()
        await store.loadHealth()
        await store.loadHealth()
        XCTAssertEqual(StubURLProtocol.count("v2/health"), 1)

        await store.loadHealth(force: true)
        XCTAssertEqual(StubURLProtocol.count("v2/health"), 2)
    }

    /// 查不到 health 不能影响别的东西 —— 它只是个诊断项。
    func testHealthFailureIsContained() async {
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        let store = makeStore()
        await store.bootstrap()
        await store.loadHealth()   // 没配桩，必然失败

        XCTAssertTrue(store.healthState.hasFailed)
        XCTAssertNil(store.health)
        XCTAssertEqual(store.bootstrapState, .loaded)
        XCTAssertNotNil(store.latestDraw(for: .ssq))
    }

    // MARK: - 三级降级

    /// CloudBase 成功时**不该再碰 GitHub**。
    func testCloudBaseSuccessSkipsGithub() async {
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        let store = makeStore()
        await store.bootstrap()

        let hosts = Set(StubURLProtocol.hosts())
        XCTAssertEqual(hosts.count, 1)
        XCTAssertFalse(hosts.contains("raw.githubusercontent.com"))
    }

    /// CloudBase 挂了就走 GitHub 上那份同构的静态文件。
    func testCloudBaseFailureFallsBackToGithub() async {
        StubURLProtocol.stub("v2/bootstrap", status: 503, body: Data())
        StubURLProtocol.stub("v2/bootstrap.json", body: LotteryV2Fixtures.bootstrap)
        let store = makeStore()
        await store.bootstrap()

        XCTAssertEqual(store.bootstrapState, .loaded)
        XCTAssertNotNil(store.latestDraw(for: .ssq))
        XCTAssertEqual(store.lastSource, .githubFallback)
        XCTAssertTrue(StubURLProtocol.hosts().contains("raw.githubusercontent.com"))
    }

    /// 两个在线源都挂：读本地缓存，界面上还是有开奖号。
    func testBothSourcesDownFallBackToCache() async {
        let folder = UUID().uuidString
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)

        // 第一次成功，把缓存写进去
        let warm = makeStore(cacheFolder: folder)
        await warm.bootstrap()
        XCTAssertNotNil(warm.latestDraw(for: .ssq))

        // 第二次两个源都打不通，但共用同一个缓存目录
        StubURLProtocol.reset()
        StubURLProtocol.stub("v2/bootstrap", status: 500, body: Data())
        StubURLProtocol.stub("v2/bootstrap.json", status: 500, body: Data())
        let cold = makeStore(cacheFolder: folder)
        await cold.bootstrap()

        XCTAssertNotNil(cold.latestDraw(for: .ssq), "在线源全挂时应该回落缓存")
        XCTAssertEqual(cold.lastSource, .localCache)
    }

    /// 刷新失败不能把已经显示出来的数据清掉。
    func testFailedRefreshKeepsExistingData() async {
        let folder = UUID().uuidString
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        let store = makeStore(cacheFolder: folder)
        await store.bootstrap()
        let before = store.draws.count
        XCTAssertGreaterThan(before, 0)

        StubURLProtocol.reset()
        StubURLProtocol.stub("v2/bootstrap", status: 500, body: Data())
        StubURLProtocol.stub("v2/bootstrap.json", status: 500, body: Data())
        await store.refresh()

        XCTAssertEqual(store.draws.count, before, "刷新失败后列表不该变空")
    }

    /// 缓存里是坏文件：当没有，去网络重取，不能崩。
    func testCorruptCacheIsIgnored() async {
        let folder = UUID().uuidString
        let cache = LotteryCache(folder: "tests/\(folder)")
        await cache.write(Data("{ 这不是 JSON".utf8), for: .bootstrap)

        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        let client = LotteryAPIClient(session: StubURLProtocol.makeSession())
        let store = DrawStore(repository: LotteryRepository(client: client, cache: cache))
        await store.bootstrap()

        XCTAssertNotNil(store.latestDraw(for: .ssq))
        XCTAssertEqual(store.bootstrapState, .loaded)
    }

    /// 全挂而且没有缓存：状态是失败，页面可以据此显示重试按钮。
    func testNoSourceAndNoCacheFails() async {
        let store = makeStore()
        await store.bootstrap()

        XCTAssertTrue(store.bootstrapState.hasFailed)
        XCTAssertTrue(store.draws.isEmpty)
    }

    /// 某个彩种的往期挂了，**不能影响首页**。各端点的状态是分开的。
    func testOneGameFailureDoesNotAffectBootstrap() async {
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        let store = makeStore()
        await store.bootstrap()
        await store.loadRecent(for: .qlc)   // 没配桩，必然失败

        XCTAssertEqual(store.bootstrapState, .loaded)
        XCTAssertTrue((store.recentStates[.qlc] ?? .idle).hasFailed)
        XCTAssertNotNil(store.latestDraw(for: .ssq), "首页数据不该被往期页的失败带走")
    }
}
