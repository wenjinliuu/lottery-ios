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
                StubURLProtocol.stub("v2/by-year/\(game.apiKey)/\(year)",
                                     body: LotteryV2Fixtures.yearPayload(
                                        year: year, earliestYear: ChinaClock.year() - 5))
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
        XCTAssertFalse(paths.contains { $0.contains("status") }, "冷启动不该拉 status")
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

    /// 服务端给了 `earliest_year`，就按它定边界，不用猜。
    func testEarliestYearDefinesTheBoundary() async {
        let year = ChinaClock.year()
        StubURLProtocol.stub("v2/by-year/ssq/\(year)",
                             body: LotteryV2Fixtures.yearPayload(year: year, earliestYear: year))
        let store = makeStore()
        await store.loadOlderHistory(for: .ssq)

        XCTAssertEqual(store.earliestYears[.ssq], year)
        XCTAssertFalse(store.hasMoreHistory(for: .ssq), "已经翻到数据源的最早年份了")
        XCTAssertNil(store.nextYearToLoad(for: .ssq))
    }

    /// **中间某一年为空不代表到头了。**
    ///
    /// 某彩种可能停办过一年。只要 `earliest_year` 还在更前面，就得接着往前翻 ——
    /// 拿「这一年是空的」当终点，会把更早的历史整个藏起来。
    func testEmptyMiddleYearKeepsGoingWhenBoundaryIsKnown() async {
        let year = ChinaClock.year()
        StubURLProtocol.stub("v2/by-year/ssq/\(year)",
                             body: LotteryV2Fixtures.yearPayload(year: year, earliestYear: year - 3))
        StubURLProtocol.stub("v2/by-year/ssq/\(year - 1)",
                             body: LotteryV2Fixtures.yearPayload(year: year - 1,
                                                                 earliestYear: year - 3, empty: true))
        let store = makeStore()
        await store.loadOlderHistory(for: .ssq)
        await store.loadOlderHistory(for: .ssq)

        XCTAssertTrue(store.hasMoreHistory(for: .ssq), "空的那一年不该把更早的历史挡掉")
        XCTAssertEqual(store.nextYearToLoad(for: .ssq), year - 2)
    }

    /// 旧镜像没有 `earliest_year`，只能退回「这一年空了就算到头」。
    ///
    /// GitHub 上那份要等下一次导出才带上这个字段，在那之前读到的就是这样。
    func testEmptyYearEndsHistoryWhenBoundaryIsUnknown() async {
        let year = ChinaClock.year()
        StubURLProtocol.stub("v2/by-year/ssq/\(year)",
                             body: LotteryV2Fixtures.yearPayload(year: year, earliestYear: nil, empty: true))
        let store = makeStore()
        await store.loadOlderHistory(for: .ssq)

        XCTAssertNil(store.earliestYears[.ssq])
        XCTAssertFalse(store.hasMoreHistory(for: .ssq))
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

    /// health **只在显式调用时才请求**，而且只打 CloudBase。
    ///
    /// 界面上目前没有入口（「数据源状态」那一组已按用户要求去掉了），
    /// 但这一层保留着：它是唯一能发现「CloudBase 响应不再符合 V2 契约」
    /// 的探针 —— 别的端点走三级降级，GitHub 兜底会把主数据源的问题盖住，
    /// 只有 health 不兜底。要重新露出来时接上 `loadHealth()` 即可。
    func testHealthIsOnDemandAndCloudBaseOnly() async {
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        StubURLProtocol.stub("v2/health", body: LotteryV2Fixtures.health)
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
        StubURLProtocol.stub("v2/health", body: LotteryV2Fixtures.health)
        let store = makeStore()
        await store.loadHealth()
        await store.loadHealth()
        XCTAssertEqual(StubURLProtocol.count("v2/health"), 1)

        await store.loadHealth(force: true)
        XCTAssertEqual(StubURLProtocol.count("v2/health"), 2)
    }

    /// 响应不符合契约时，界面上要看到**具体缺了什么**，而不是一句「未知」。
    func testHealthContractViolationSurfacesTheReason() async {
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        // V1 那份 health.json 的形状：schema / version 都不对
        StubURLProtocol.stub("v2/health", body: Data(LotteryV2Fixtures.legacyHealthJSON.utf8))
        let store = makeStore()
        await store.bootstrap()
        await store.loadHealth()

        XCTAssertNil(store.health, "不符合契约就不该产出一个「状态未知」的结果")
        let reason = store.healthState.failureText
        XCTAssertTrue(reason?.contains("schema") ?? false,
                      "失败原因要说清是哪一项对不上，实际是 \(String(describing: reason))")
        XCTAssertEqual(store.bootstrapState, .loaded, "诊断项出问题不该影响开奖数据")
    }

    // MARK: - 抓取状态

    /// `/v2/status` **只在显式调用时才请求**，和 health 一样只打 CloudBase。
    func testStatusIsOnDemandAndCloudBaseOnly() async {
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        StubURLProtocol.stub("v2/status", body: LotteryV2Fixtures.status)
        let store = makeStore()

        await store.bootstrap()
        XCTAssertEqual(StubURLProtocol.count("v2/status"), 0, "冷启动不该碰 status")
        XCTAssertNil(store.fetchStatus)

        await store.loadStatus()
        XCTAssertEqual(StubURLProtocol.count("v2/status"), 1)
        XCTAssertEqual(store.fetchStatus?.completed, 6)
        // 它问的就是 CloudBase 那边的任务，不该回落到静态镜像去问
        XCTAssertEqual(StubURLProtocol.count("v2/status.json"), 0)
    }

    /// **取数失败时保留上一次成功读到的状态。**
    ///
    /// 契约就是这么定的，理由也很实在：网络抖一下就把界面变成
    /// 「暂无执行记录」，用户会以为后端出事了，而实际上只是这一次没问到。
    func testStatusKeepsLastGoodValueOnFailure() async {
        StubURLProtocol.stub("v2/status", body: LotteryV2Fixtures.status)
        let store = makeStore()
        await store.loadStatus()
        XCTAssertEqual(store.fetchStatus?.completed, 6)

        // 换成 503，再强制刷一次。
        // **必须先 reset**：桩是「先注册的先匹配」，直接再 stub 一次
        // 同样的后缀只会排在后面，永远轮不到它 —— 那样这条用例会假过。
        StubURLProtocol.reset()
        StubURLProtocol.stub("v2/status", status: 503, body: Data())
        await store.loadStatus(force: true)

        XCTAssertTrue(store.statusState.hasFailed, "失败本身要记下来")
        XCTAssertEqual(store.fetchStatus?.completed, 6, "但上一次成功的结果必须还在")
    }

    /// 查不到 status 不能影响开奖数据 —— 它只是个状态指示。
    func testStatusFailureIsContained() async {
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        let store = makeStore()
        await store.bootstrap()
        await store.loadStatus()   // 没配桩，必然失败

        XCTAssertTrue(store.statusState.hasFailed)
        XCTAssertNil(store.fetchStatus, "一次都没成功过，就该是空的")
        XCTAssertEqual(store.bootstrapState, .loaded)
        XCTAssertNotNil(store.latestDraw(for: .ssq))
    }

    /// 冷启动之后「更新时间」要有值 —— 那是**这台设备**取数的时刻。
    func testBootstrapRecordsLocalFetchTime() async {
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        let store = makeStore()
        XCTAssertNil(store.lastFetchedAt)

        await store.bootstrap()
        XCTAssertNotNil(store.lastFetchedAt)
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
