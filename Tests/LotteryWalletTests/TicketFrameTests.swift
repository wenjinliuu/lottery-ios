import XCTest
import CoreGraphics
@testable import LotteryWallet

/// 号码区的**配准**：两条虚线 → 四个角 → 标准矩形。
///
/// 这一层是整次重构补上的那一步。以前所有几何判据都从识别结果里估，
/// 而裁切框本身是歪的；现在锚点是票面自己印的虚线，跟用户怎么裁没关系。
final class TicketFrameTests: XCTestCase {

    private let width = 1000
    private let height = 400

    private var blankMask: InkMask {
        InkMask(width: width, height: height, ink: [Bool](repeating: false, count: width * height))
    }

    private func rule(intercept: Double, slope: Double = 0) -> DashedRule {
        DashedRule(bins: 0...0, projectionSlope: 0, columns: 20...969,
                   segments: [], slope: slope, intercept: intercept)
    }

    /// 摆正的票：四个角就是两条线和左右端点的交点。
    func testFrameFromTwoRules() {
        guard let frame = TicketFrame.between(rules: [rule(intercept: 51), rule(intercept: 301)],
                                              in: blankMask) else {
            return XCTFail("两条虚线应该夹得出号码区")
        }
        XCTAssertEqual(frame.anchor, .dashedRules)
        XCTAssertEqual(frame.topLeft.x, 0.020, accuracy: 1e-9)
        XCTAssertEqual(frame.topLeft.y, 51.0 / 400, accuracy: 1e-9)
        XCTAssertEqual(frame.topRight.x, 0.969, accuracy: 1e-9)
        XCTAssertEqual(frame.bottomLeft.y, 301.0 / 400, accuracy: 1e-9)
        XCTAssertEqual(frame.bottomRight.y, 301.0 / 400, accuracy: 1e-9)
    }

    /// 上下颠倒着传进来也要摆对 —— 检测顺序不该影响结果。
    func testRulesSortedTopToBottom() {
        let frame = TicketFrame.between(rules: [rule(intercept: 301), rule(intercept: 51)],
                                        in: blankMask)
        XCTAssertEqual(frame?.topLeft.y ?? 1, 51.0 / 400, accuracy: 1e-9)
    }

    /// **不是两条就整个退回。**
    ///
    /// 少一条说明裁切时把虚线切掉了；多一条说明判据在这张票上失效了。
    /// 这两种情况都不许"挑两条凑合" —— 挑错一条，号码区整体偏掉，
    /// 而读出来的还是一串合法号码，用户根本看不出来。硬约束二说的就是这个。
    func testRefusesToGuessWhenNotExactlyTwo() {
        XCTAssertNil(TicketFrame.between(rules: [rule(intercept: 51)], in: blankMask))
        XCTAssertNil(TicketFrame.between(
            rules: [rule(intercept: 51), rule(intercept: 301), rule(intercept: 360)],
            in: blankMask))
    }

    /// 两条挨在一起的线夹不出号码区。
    func testRejectsRulesTooCloseTogether() {
        XCTAssertNil(TicketFrame.between(rules: [rule(intercept: 51), rule(intercept: 55)],
                                         in: blankMask))
    }

    /// 歪着的票：号码区是个平行四边形，配准之后左右边界落在 0 和 1 上。
    func testTiltedFrameRectifies() {
        guard let frame = TicketFrame.between(
            rules: [rule(intercept: 47, slope: 0.008), rule(intercept: 297, slope: 0.008)],
            in: blankMask) else {
            return XCTFail("歪票也该夹得出号码区")
        }
        XCTAssertEqual(frame.topLeft.y, (47 + 0.008 * 20) / 400, accuracy: 1e-9)
        XCTAssertEqual(frame.topRight.y, (47 + 0.008 * 969) / 400, accuracy: 1e-9)
        XCTAssertGreaterThan(frame.topRight.y, frame.topLeft.y, "右边比左边低，票是歪的")

        XCTAssertEqual(frame.rectifiedX(of: 0.020) ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(frame.rectifiedX(of: 0.969) ?? -1, 1, accuracy: 1e-6)
        // 平行四边形的配准是仿射的：中间那条竖线按比例落下去
        XCTAssertEqual(frame.rectifiedX(of: 0.2) ?? -1, 0.18 / 0.949, accuracy: 1e-6)
    }

    /// **每个号码来自票面哪个像素格子** —— 靠的就是这个反向映射。
    /// 标准矩形整块映射回去，必须正好是原来那四个角。
    func testRestoreRoundTrip() {
        guard let frame = TicketFrame.between(
            rules: [rule(intercept: 47, slope: 0.008), rule(intercept: 297, slope: 0.008)],
            in: blankMask),
            let corners = frame.restore(CGRect(x: 0, y: 0, width: 1, height: 1)) else {
            return XCTFail("映射不回去")
        }
        for (restored, original) in zip(corners, frame.corners) {
            XCTAssertEqual(restored.x, original.x, accuracy: 1e-6)
            XCTAssertEqual(restored.y, original.y, accuracy: 1e-6)
        }
    }

    // MARK: - 右边界

    private func fragment(_ text: String, x: CGFloat, y: CGFloat,
                          width: CGFloat = 0.04) -> TicketVisionScanner.TextFragment {
        // Vision 的坐标原点在左下角
        TicketVisionScanner.TextFragment(
            text: text,
            box: CGRect(x: x, y: y - 0.01, width: width, height: 0.02))
    }

    /// 号码区右边界 = 倍数列 `(N)` 的左侧。
    ///
    /// 这就是已知 bug 一缺的那一刀：3D 行尾 `(1)` 里的 `1` 被当成第 4 个号码，
    /// `isBetRow(columns: 3)` 一看 4 > 3 就把整行拒了 ——
    /// 福彩 3D 的矩阵路径从来没跑起来过，根因就在这儿。
    func testMultiplierBoundaryTakesLeftmostInBand() {
        let fragments = [fragment("(1)", x: 0.80, y: 0.60),
                         fragment("(1)", x: 0.78, y: 0.50),
                         fragment("(3)", x: 0.79, y: 0.40)]
        let boundary = TicketFrame.multiplierBoundary(fragments, within: 0.1275...0.7525,
                                                      contentWidth: 1)
        XCTAssertEqual(boundary ?? -1, 0.78, accuracy: 1e-9, "边界要把所有倍数都挡在外面")
    }

    /// 号码区之外的倍数、以及整行被连着读出来的碎片，都不能当边界 ——
    /// 拿它们切一刀，切掉的就是真号码。
    func testMultiplierBoundaryIgnoresOutsiders() {
        let fragments = [
            fragment("(2)", x: 0.30, y: 0.95),                       // 号码区上面，不算
            fragment("组六: 1 8 9 (1)", x: 0.10, y: 0.50, width: 0.7) // 整行，不算
        ]
        XCTAssertNil(TicketFrame.multiplierBoundary(fragments, within: 0.1275...0.7525,
                                                    contentWidth: 1))
    }
}
