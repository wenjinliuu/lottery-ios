import XCTest
@testable import LotteryWallet

final class JarModelTests: XCTestCase {
    private let now = DateText.parse("2026-11-12")!

    private func ssq(_ day: String, redHits: Int, blueHit: Bool) -> JarEntry {
        JarEntry(day: day, game: .ssq, numbers: NumberSet([.red: [1, 2, 3, 4, 5, 6], .blue: [7]]),
                 matched: [.red: (0..<6).map { $0 < redHits }, .blue: [blueHit]])
    }

    func testOnlyMatchedNumbersAppearAndRepeatedHitsCount() {
        let entry = ssq("2026-11-01", redHits: 2, blueHit: false)
        let misses = ssq("2026-11-02", redHits: 0, blueHit: false)
        let jar = JarBuilder.build([entry, entry, misses], range: .year, now: now)
        XCTAssertEqual(jar.hits, 4)
        XCTAssertEqual(jar.colors(limit: JarBuilder.displayLimit), [.red, .red, .red, .red])
        XCTAssertEqual(jar.hits, jar.colors(limit: 100).count)
    }

    func testCalendarRangeIncludesExactlyTheSelectedMonthYearOrAll() {
        let entries = ["2025-11-01", "2026-01-01", "2026-10-31", "2026-11-01", "2026-11-12", "2026-12-01"]
            .map { ssq($0, redHits: 1, blueHit: false) }
        XCTAssertEqual(JarBuilder.build(entries, range: .month, now: now).hits, 2)
        XCTAssertEqual(JarBuilder.build(entries, range: .year, now: now).hits, 4)
        XCTAssertEqual(JarBuilder.build(entries, range: .all, now: now).hits, 6)
    }

    func testLargeJarKeepsExactTotalAndCapsDisplayByColorProportion() {
        let entries = Array(repeating: ssq("2026-11-01", redHits: 3, blueHit: true), count: 10_000)
        let jar = JarBuilder.build(entries, range: .all, now: now)
        XCTAssertEqual(jar.hits, 40_000)
        XCTAssertEqual(jar.colors(limit: JarBuilder.displayLimit).count, JarBuilder.displayLimit)
        XCTAssertEqual(jar.colors(limit: JarBuilder.displayLimit).filter { $0 == .blue }.count, JarBuilder.displayLimit / 4)
        XCTAssertEqual(jar.colors(limit: 100).filter { $0 == .blue }.count, 25)
    }

    func testLargestFractionGetsLastVisibleBall() {
        let jar = JarBuilder.Jar(counts: [.red: 668, .blue: 667, .yellow: 666])
        let groups = Dictionary(grouping: jar.colors(limit: 1000), by: { $0 })
        XCTAssertEqual(groups.mapValues { $0.count }, [.red: 334, .blue: 333, .yellow: 333])
    }

    func testDenseJarLeavesRoomForMotionAndUsesSmallerBalls() {
        let width = 335.0, height = 230.0
        let count = JarBuilder.capacity(width: width, height: height)
        let smallPileRadius = JarBuilder.radius(count: 100, width: width, height: height)
        let denseRadius = JarBuilder.radius(count: count, width: width, height: height)
        XCTAssertLessThan(denseRadius, smallPileRadius)
        var physics = JarPhysics()
        physics.fillPacked(count: count, radius: denseRadius, width: width, height: height)
        XCTAssertTrue(physics.isResting)
        XCTAssertEqual(physics.balls.count, count)
        let headroom = physics.balls.map { $0.y - $0.radius }.min() ?? 0
        XCTAssertGreaterThanOrEqual(headroom, denseRadius * 2)
        XCTAssertLessThan(headroom, height * 0.16)
        XCTAssertEqual(physics.balls.map { $0.y + $0.radius }.max() ?? 0, height, accuracy: 0.001)
    }

    func testSparseAndDenseMonthsShareTheSamePhysicalLimits() {
        XCTAssertEqual(JarBuilder.radius(count: 1, width: 335, height: 222) * 2, DrawCardMetrics.maxBall)
        let capacity = JarBuilder.capacity(width: 335, height: 222)
        XCTAssertEqual(capacity, 1_000)
        XCTAssertGreaterThanOrEqual(JarBuilder.radius(count: capacity, width: 335, height: 222) * 2, JarBuilder.minimumDiameter)
        XCTAssertEqual(JarBuilder.capacity(width: 275, height: 222), capacity)
        XCTAssertLessThan(JarBuilder.capacity(width: 230, height: 190), capacity)
        XCTAssertEqual(JarBuilder.radius(count: 4, width: 335, height: 222),
                       JarBuilder.radius(count: 5, width: 335, height: 222))
    }

    func testNoMatchingBalls() {
        XCTAssertEqual(JarBuilder.build([], range: .month, now: now), JarBuilder.Jar())
    }

    func testBreakdownSeparatesSameColorZonesAcrossGames() {
        let ssqEntry = ssq("2026-11-01", redHits: 3, blueHit: true)
        let dltEntry = JarEntry(
            day: "2026-11-02",
            game: .dlt,
            numbers: NumberSet([.front: [1, 2, 3, 4, 5], .back: [1, 2]]),
            matched: [.front: [true, true, true, true, false], .back: [true, false]]
        )
        let qlcEntry = JarEntry(
            day: "2026-11-03",
            game: .qlc,
            numbers: NumberSet([.nums7: [1, 2, 3, 4, 5, 6, 7]]),
            matched: [.nums7: [true, true, false, false, false, false, false]]
        )

        let jar = JarBuilder.build([ssqEntry, dltEntry, qlcEntry], range: .year, now: now)
        XCTAssertEqual(jar.hits, 11)
        // 双色球蓝球(1)和大乐透前区(4)共用 .blue；大乐透后区(1)和七乐彩基本号(2)共用 .yellow，
        // 汇总颜色表合并它们，但明细表必须按彩种和号码区准确分开。
        XCTAssertEqual(jar.counts[.blue], 5)
        XCTAssertEqual(jar.counts[.yellow], 3)
        XCTAssertEqual(jar.breakdown.map(\.game), [.dlt, .ssq, .qlc])

        let dltZones = jar.breakdown[0].zones
        XCTAssertEqual(dltZones.map(\.label), ["前区", "后区"])
        XCTAssertEqual(dltZones.map(\.hits), [4, 1])

        let ssqZones = jar.breakdown[1].zones
        XCTAssertEqual(ssqZones.map(\.label), ["红球", "蓝球"])
        XCTAssertEqual(ssqZones.map(\.hits), [3, 1])

        let qlcZones = jar.breakdown[2].zones
        XCTAssertEqual(qlcZones.map(\.label), ["基本号"])
        XCTAssertEqual(qlcZones.map(\.hits), [2])
    }

    func testScaledZoneCountsSumsToVisibleLimitProportionally() {
        let jar = JarBuilder.demoPreview(hits: 2_000)
        XCTAssertEqual(jar.hits, 2_000)
        XCTAssertEqual(jar.breakdown.reduce(0) { $0 + $1.hits }, 2_000)
        let scaled = jar.scaledZoneCounts(limit: JarBuilder.displayLimit)
        XCTAssertEqual(scaled.values.reduce(0, +), JarBuilder.displayLimit)
        XCTAssertEqual(scaled["ssq.red"], 550)
    }

    /// 回归：之前在 `ScrollView.background` 的 `GeometryReader` 里重复减了一次 `safeAreaInsets`，
    /// 连 6.9 英寸大屏都被压到最小高度 172pt。修完后大屏回升到 280pt，各机型都不遮挡底栏。
    func testBallJarAdaptiveHeightFitsAcrossScreenSizes() {
        // 6.9 英寸 Pro Max（440×956pt，扣除顶/底安全区后可见高度约 766pt）
        let proMax = BallJarView.adaptiveHeight(viewportHeight: 766, screenWidth: 440)
        XCTAssertEqual(proMax, 280)
        XCTAssertLessThan(proMax + 283 + DrawCardMetrics.unifiedHeight(screenWidth: 440), 766)

        // 6.3 英寸 Pro（402×874pt，可见高度约 684pt）
        let pro = BallJarView.adaptiveHeight(viewportHeight: 684, screenWidth: 402)
        XCTAssertGreaterThanOrEqual(pro, 230)
        XCTAssertLessThan(pro + 283 + DrawCardMetrics.unifiedHeight(screenWidth: 402), 684)

        // 6.1 英寸标准屏（393×852pt，可见高度约 662pt）
        let standard = BallJarView.adaptiveHeight(viewportHeight: 662, screenWidth: 393)
        XCTAssertGreaterThanOrEqual(standard, BallJarView.minHeight)
        XCTAssertLessThan(standard + 283 + DrawCardMetrics.unifiedHeight(screenWidth: 393), 662)

        // 极矮屏幕仍兜底在最小高度
        XCTAssertEqual(BallJarView.adaptiveHeight(viewportHeight: 500, screenWidth: 375), BallJarView.minHeight)
    }
}
