import XCTest
@testable import LotteryWallet

/// 罐子里的球：不出罐子、不叠在一起、会停下来、吹一下会飞起来再落回去。
final class JarPhysicsTests: XCTestCase {

    private func radii() -> [Double] {
        Array(repeating: 8.0, count: 255)
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

    /// 轻点罐内区域：附近小球被激起弹跳、不出边界，最后能重新停稳。
    func testPokeDisplacesNearbyBallsAndSettles() {
        var physics = JarPhysics()
        physics.fill(radii: Array(repeating: 8.0, count: 120), width: 330, height: 230, settled: true)
        let before = physics.balls.map { ($0.x, $0.y) }
        physics.poke(at: 165, y: 195)
        XCTAssertFalse(physics.isResting)
        for _ in 0..<20 {
            physics.step(1.0 / 60)
            check(physics)
        }
        let maxDelta = zip(before, physics.balls).map { hypot($0.0 - $1.x, $0.1 - $1.y) }.max() ?? 0
        XCTAssertGreaterThan(maxDelta, 12, "轻点应明显弹起附近小球")
        var steps = 0
        while !physics.isResting && steps < 900 {
            physics.step(1.0 / 60)
            steps += 1
        }
        XCTAssertTrue(physics.isResting, "轻点弹起后要能重新落稳")
        check(physics)
    }

    /// 手指按住拖动搅动：附近小球顺着手指速度方向移动并始终留在罐内。
    func testStirMovesBallsAlongFingerDirection() {
        var physics = JarPhysics()
        physics.fill(radii: Array(repeating: 8.0, count: 100), width: 330, height: 230, settled: true)
        let beforeMeanX = physics.balls.map(\.x).reduce(0, +) / Double(physics.balls.count)
        for step in 0..<15 {
            physics.stir(at: 120 + Double(step) * 8, y: 195, vx: 650, vy: -260)
            physics.step(1.0 / 60)
            check(physics)
        }
        let afterMeanX = physics.balls.map(\.x).reduce(0, +) / Double(physics.balls.count)
        XCTAssertGreaterThan(afterMeanX, beforeMeanX + 4, "向右搅动应带动小球整体右移")
    }
}
