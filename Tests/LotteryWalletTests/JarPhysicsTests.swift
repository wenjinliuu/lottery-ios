import XCTest
@testable import LotteryWallet

/// 罐子里的球：不出罐子、不叠在一起、会停下来、吹一下会飞起来再落回去。
final class JarPhysicsTests: XCTestCase {

    private func radii() -> [Double] {
        Array(repeating: 6.3, count: 255) + Array(repeating: 10.7, count: 30) + Array(repeating: 15, count: 4)
    }

    private func check(_ physics: JarPhysics, file: StaticString = #filePath, line: UInt = #line) {
        for ball in physics.balls {
            XCTAssertGreaterThanOrEqual(ball.x, ball.radius - 0.01, file: file, line: line)
            XCTAssertLessThanOrEqual(ball.x, physics.width - ball.radius + 0.01, file: file, line: line)
            XCTAssertGreaterThanOrEqual(ball.y, ball.radius - 0.01, file: file, line: line)
            XCTAssertLessThanOrEqual(ball.y, physics.height - ball.radius + 0.01, file: file, line: line)
        }
    }

    /// 叠得最厉害的一对，叠了半径之和的几成。
    private func worstOverlap(_ physics: JarPhysics) -> Double {
        var worst = 0.0
        let balls = physics.balls
        for a in balls.indices {
            for b in balls.indices where b > a {
                let reach = balls[a].radius + balls[b].radius
                let distance = ((balls[a].x - balls[b].x) * (balls[a].x - balls[b].x)
                                + (balls[a].y - balls[b].y) * (balls[a].y - balls[b].y)).squareRoot()
                worst = max(worst, (reach - distance) / reach)
            }
        }
        return worst
    }

    func testSettlesInsideTheJarWithoutOverlap() {
        var physics = JarPhysics()
        physics.fill(radii: radii(), width: 330, height: 230, settled: true)
        XCTAssertTrue(physics.isResting)
        check(physics)
        XCTAssertLessThan(worstOverlap(physics), 0.2)
        // 留着地方：最上面那颗球离罐口还有一截
        let top = physics.balls.map { $0.y - $0.radius }.min() ?? 0
        XCTAssertGreaterThan(top, 10)
    }

    func testSameInputGivesSameLayout() {
        var a = JarPhysics(), b = JarPhysics()
        a.fill(radii: radii(), width: 330, height: 230, settled: true)
        b.fill(radii: radii(), width: 330, height: 230, settled: true)
        XCTAssertEqual(a.balls.map(\.x), b.balls.map(\.x))
        XCTAssertEqual(a.balls.map(\.y), b.balls.map(\.y))
    }

    func testBlowLiftsTheBallsAndTheyComeBackToRest() {
        var physics = JarPhysics()
        physics.fill(radii: radii(), width: 330, height: 230, settled: true)
        let before = physics.balls.map(\.y).reduce(0, +) / Double(physics.balls.count)
        physics.blow()
        XCTAssertFalse(physics.isResting)
        var highest = before
        for _ in 0..<70 {
            physics.step(1.0 / 60)
            highest = min(highest, physics.balls.map(\.y).reduce(0, +) / Double(physics.balls.count))
            check(physics)
        }
        XCTAssertLessThan(highest, before - 25, "吹的时候球整体要明显往上")
        var steps = 0
        while !physics.isResting && steps < 1200 {
            physics.step(1.0 / 60)
            steps += 1
        }
        XCTAssertTrue(physics.isResting, "吹完要能停下来")
        check(physics)
        XCTAssertLessThan(worstOverlap(physics), 0.2)
    }

    /// 手机横过来，球滚到那一边去。
    func testGravityDirection() {
        var physics = JarPhysics()
        physics.fill(radii: Array(repeating: 6.3, count: 60), width: 330, height: 230, settled: true)
        physics.gravityX = 1400
        physics.gravityY = 0
        physics.wake()
        for _ in 0..<600 where !physics.isResting { physics.step(1.0 / 60) }
        let mean = physics.balls.map(\.x).reduce(0, +) / Double(physics.balls.count)
        XCTAssertGreaterThan(mean, 250)
    }
}
