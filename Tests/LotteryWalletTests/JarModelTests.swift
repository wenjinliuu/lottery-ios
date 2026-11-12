import XCTest
@testable import LotteryWallet

/// 号码球罐放什么：换算、分档、哪些球单独放。
final class JarModelTests: XCTestCase {

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = DateText.chinaTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text) ?? Date()
    }

    /// 一注双色球。`hits` 是红球里命中的个数（从头数），`blue` 是蓝球中没中。
    private func ssq(_ day: String, hits: Int = 0, blue: Bool = false, prize: Double = 0) -> JarEntry {
        JarEntry(day: day, game: .ssq,
                 numbers: NumberSet([.red: [1, 2, 3, 4, 5, 6], .blue: [7]]),
                 matched: [.red: (0..<6).map { $0 < hits }, .blue: [blue]],
                 prize: prize)
    }

    private func count(_ jar: JarBuilder.Jar, _ kind: JarBead.Kind, _ color: BallColor? = nil) -> Int {
        jar.beads.filter { $0.kind == kind && (color == nil || $0.color == color) }.count
    }

    func testPrizeTiers() {
        XCTAssertEqual(JarTier.of(prize: 5), .small)
        XCTAssertEqual(JarTier.of(prize: 99.9), .small)
        XCTAssertEqual(JarTier.of(prize: 100), .medium)
        XCTAssertEqual(JarTier.of(prize: 9_999), .medium)
        XCTAssertEqual(JarTier.of(prize: 10_000), .big)
    }

    func testStepIsTheSmallestRoundNumberThatFits() {
        XCTAssertEqual(JarBuilder.step(atLeast: 1), 1)
        XCTAssertEqual(JarBuilder.step(atLeast: 3), 5)
        XCTAssertEqual(JarBuilder.step(atLeast: 21), 35)
        XCTAssertEqual(JarBuilder.step(atLeast: 1_000_000), 5000)
    }

    /// 买得少的时候一个号码就是一颗，一颗不少。
    func testFewNumbersAreShownOneByOne() {
        let jar = JarBuilder.build([ssq("2025-03-01", hits: 2)], scope: .year(2025), now: date("2026-11-12"))
        XCTAssertEqual(jar.per, 1)
        XCTAssertEqual(jar.total, 7)
        XCTAssertEqual(count(jar, .hit, .red), 2)
        XCTAssertEqual(count(jar, .miss, .red), 4)
        XCTAssertEqual(count(jar, .miss, .blue), 1)
        XCTAssertEqual(jar.wins, 0)
    }

    /// 中奖那一注里命中的号单独放、带号码、按奖金分档；同一注里没命中的照样是小珠子。
    func testWinningLineHitsBecomeNumberedBalls() {
        let jar = JarBuilder.build([ssq("2025-03-01", hits: 3, blue: true, prize: 200)],
                                   scope: .year(2025), now: date("2026-11-12"))
        let wins = jar.beads.filter { if case .win = $0.kind { return true } else { return false } }
        XCTAssertEqual(wins.count, 4)
        XCTAssertEqual(jar.wins, 4)
        XCTAssertTrue(wins.allSatisfy { $0.kind == .win(.medium) })
        XCTAssertEqual(Set(wins.compactMap(\.number)), [1, 2, 3, 7])
        XCTAssertEqual(count(jar, .hit), 0)
        XCTAssertEqual(count(jar, .miss, .red), 3)
    }

    /// 年罐只装那一年的；「全部」都装。
    func testScope() {
        let entries = [ssq("2025-03-01"), ssq("2026-03-01"), ssq("2026-04-01")]
        let now = date("2026-11-12")
        XCTAssertEqual(JarBuilder.build(entries, scope: .year(2025), now: now).total, 7)
        XCTAssertEqual(JarBuilder.build(entries, scope: .year(2026), now: now).total, 14)
        XCTAssertEqual(JarBuilder.build(entries, scope: .all, now: now).total, 21)
    }

    /// 今年的罐子按「照这个节奏到年底」定换算：同样多的号码，年初买到的比年底买到的换算大，
    /// 所以年初不会一下子装满，罐子是慢慢涨上去的。
    func testThisYearIsScaledToTheWholeYear() {
        let march = (0..<100).map { _ in ssq("2026-03-10") }           // 700 个号码
        let early = JarBuilder.build(march, scope: .year(2026), now: date("2026-03-31"))
        let late = JarBuilder.build(march, scope: .year(2026), now: date("2026-12-31"))
        XCTAssertGreaterThan(early.per, late.per)
        // 年底：700 个号码、约八成半 → 一颗 5 个，140 颗
        XCTAssertEqual(late.per, 5)
        // 三月底：按一年 2800 个估 → 一颗 20 个（前一档 10 个只装得下 2550 个）
        XCTAssertEqual(early.per, 20)
        XCTAssertLessThan(early.beads.count, JarBuilder.capacity / 3)
    }

    /// 「全部」的罐子永远留着地方：再多也只装到六七成。
    func testAllTimeJarKeepsHeadroom() {
        for lines in [50, 900, 20_000] {
            let entries = (0..<lines).map { _ in ssq("2024-05-01", hits: 1) }
            let jar = JarBuilder.build(entries, scope: .all, now: date("2026-11-12"))
            XCTAssertLessThanOrEqual(jar.beads.count, Int(Double(JarBuilder.capacity) * 0.7), "\(lines) 注")
        }
    }

    /// 命中的号再少，只要有就至少留一颗，不会被四舍五入掉。
    func testHitsNeverRoundAwayToNothing() {
        var entries = (0..<400).map { _ in ssq("2025-05-01") }
        entries.append(ssq("2025-05-02", hits: 1))
        let jar = JarBuilder.build(entries, scope: .year(2025), now: date("2026-11-12"))
        XCTAssertGreaterThan(jar.per, 1)
        XCTAssertEqual(count(jar, .hit, .red), 1)
    }

    /// 中奖球太多时只放最近的那些，总数照记。
    func testWinningBallsAreCapped() {
        let entries = (1...28).map { ssq(String(format: "2025-01-%02d", $0), hits: 4, prize: 10) }
        let jar = JarBuilder.build(entries, scope: .year(2025), now: date("2026-11-12"))
        let wins = jar.beads.filter { if case .win = $0.kind { return true } else { return false } }
        XCTAssertEqual(jar.wins, 112)
        XCTAssertEqual(wins.count, JarBuilder.winLimit)
    }

    func testEmpty() {
        let jar = JarBuilder.build([], scope: .all, now: date("2026-11-12"))
        XCTAssertTrue(jar.beads.isEmpty)
        XCTAssertEqual(jar.per, 1)
    }
}
