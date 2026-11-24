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
}
