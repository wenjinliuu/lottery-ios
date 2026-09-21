import XCTest
@testable import LotteryWallet

/// 端点路径、缓存键与彩种标识。
///
/// 这三样必须一起对。路径写错 → 404；缓存键写错 → 两个端点互相覆盖缓存
/// （最难查的一种：数据会莫名其妙变成另一个彩种的）；彩种标识写错 →
/// 快乐8 单独没有数据。
final class LotteryEndpointTests: XCTestCase {

    // MARK: - 路径

    func testCloudBasePaths() {
        XCTAssertEqual(LotteryEndpoint.bootstrap.cloudBasePath, "v2/bootstrap")
        XCTAssertEqual(LotteryEndpoint.recentDraws(.ssq).cloudBasePath, "v2/draws/ssq")
        XCTAssertEqual(LotteryEndpoint.yearDraws(.ssq, 2026).cloudBasePath, "v2/by-year/ssq/2026")
        XCTAssertEqual(LotteryEndpoint.calendar(2026).cloudBasePath, "v2/calendar/2026")
    }

    /// GitHub 兜底的路径是 CloudBase 路径加 `.json`，派生而不是另抄一份。
    func testGithubPathsDeriveFromCloudBase() {
        for endpoint: LotteryEndpoint in [.bootstrap, .recentDraws(.k8),
                                          .yearDraws(.dlt, 2025), .calendar(2025)] {
            XCTAssertEqual(endpoint.githubPath, endpoint.cloudBasePath + ".json")
        }
    }

    // MARK: - k8 ↔ kl8

    /// App 内是 `k8`，远端是 `kl8`。这个映射只有一处，这里把它钉死。
    func testK8MapsToKL8Everywhere() {
        XCTAssertEqual(GameKey.k8.apiKey, "kl8")
        XCTAssertEqual(LotteryEndpoint.recentDraws(.k8).cloudBasePath, "v2/draws/kl8")
        XCTAssertEqual(LotteryEndpoint.yearDraws(.k8, 2026).cloudBasePath, "v2/by-year/kl8/2026")
        XCTAssertEqual(LotteryEndpoint.recentDraws(.k8).cacheKey, "v2-draws-kl8")
        XCTAssertEqual(GameKey.fromAPIKey("kl8"), .k8)
        // 本地那个写法也照收。远端不会发 "k8"，但万一发了，认出来比拒掉好 ——
        // 拒掉的后果是快乐8 整个没有数据，而收下没有任何坏处。
        // `DrawCalendarYear.entry(for:)` 也是同一套宽进策略。
        XCTAssertEqual(GameKey.fromAPIKey("k8"), .k8)
    }

    /// 除了快乐8，其余七个彩种两边同名。
    func testOtherGamesKeepTheirKey() {
        for game in GameKey.ordered where game != .k8 {
            XCTAssertEqual(game.apiKey, game.rawValue)
            XCTAssertEqual(GameKey.fromAPIKey(game.rawValue), game)
        }
    }

    func testUnknownKeyIsRejected() {
        XCTAssertNil(GameKey.fromAPIKey(""))
        XCTAssertNil(GameKey.fromAPIKey("sports-lottery"))
    }

    // MARK: - 缓存键

    /// 每个端点一个键，互不重叠。重叠的话一个彩种的往期会盖掉另一个的。
    func testCacheKeysAreUnique() {
        var keys: Set<String> = [LotteryEndpoint.bootstrap.cacheKey]
        for game in GameKey.ordered {
            keys.insert(LotteryEndpoint.recentDraws(game).cacheKey)
            keys.insert(LotteryEndpoint.yearDraws(game, 2026).cacheKey)
            keys.insert(LotteryEndpoint.yearDraws(game, 2025).cacheKey)
        }
        keys.insert(LotteryEndpoint.calendar(2026).cacheKey)
        keys.insert(LotteryEndpoint.calendar(2025).cacheKey)
        // 1 + 8×3 + 2
        XCTAssertEqual(keys.count, 27)
    }

    /// 缓存键只能出现文件名安全的字符 —— 它直接当文件名用。
    func testCacheKeysAreFileSafe() {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for endpoint: LotteryEndpoint in [.bootstrap, .recentDraws(.k8),
                                          .yearDraws(.qxc, 2026), .calendar(2026)] {
            XCTAssertNil(endpoint.cacheKey.rangeOfCharacter(from: allowed.inverted),
                         "\(endpoint.cacheKey) 里有不能当文件名的字符")
        }
    }

    // MARK: - 刷新间隔

    /// 已经过完的年份基本不会再变，该比当年缓存得久得多。
    func testFinishedYearsCacheLonger() {
        let current = ChinaClock.year()
        XCTAssertGreaterThan(LotteryEndpoint.yearDraws(.ssq, current - 1).freshness,
                             LotteryEndpoint.yearDraws(.ssq, current).freshness)
        XCTAssertGreaterThan(LotteryEndpoint.calendar(current - 1).freshness,
                             LotteryEndpoint.calendar(current).freshness)
    }

    /// 首页那两个端点刷得最勤，日历最懒。
    func testFreshnessOrdering() {
        let current = ChinaClock.year()
        XCTAssertEqual(LotteryEndpoint.bootstrap.freshness, 60)
        XCTAssertEqual(LotteryEndpoint.recentDraws(.ssq).freshness, 60)
        XCTAssertGreaterThan(LotteryEndpoint.calendar(current).freshness,
                             LotteryEndpoint.recentDraws(.ssq).freshness)
    }
}
