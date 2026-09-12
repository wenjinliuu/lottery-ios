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

    /// 一条厚 3 行的虚线。内沿离中线 3/2 + 1 = 2.5 行。
    private func rule(intercept: Double, slope: Double = 0) -> DashedRule {
        DashedRule(bins: 0...2, projectionSlope: 0, columns: 20...969,
                   segments: [], slope: slope, intercept: intercept)
    }

    /// 号码区上下边相对虚线中线让进来的量（像素）。
    private let inset: CGFloat = 2.5

    /// 摆正的票：四个角就是两条线和左右端点的交点。
    func testFrameFromTwoRules() {
        guard let frame = TicketFrame.between(rules: [rule(intercept: 51), rule(intercept: 301)],
                                              in: blankMask) else {
            return XCTFail("两条虚线应该夹得出号码区")
        }
        XCTAssertEqual(frame.anchor, .dashedRules)
        XCTAssertEqual(frame.topLeft.x, 0.020, accuracy: 1e-9)
        XCTAssertEqual(frame.topRight.x, 0.969, accuracy: 1e-9)
        // 上下边取的是虚线的**内沿**，不是中线：虚线自己的墨不能落进号码区
        XCTAssertEqual(frame.topLeft.y, (51 + inset) / 400, accuracy: 1e-9)
        XCTAssertEqual(frame.bottomLeft.y, (301 - inset) / 400, accuracy: 1e-9)
        XCTAssertEqual(frame.bottomRight.y, (301 - inset) / 400, accuracy: 1e-9)
    }

    /// 虚线的墨必须落在号码区**外面**。
    ///
    /// 实测的后果：大乐透第③注和下面那条虚线在投影上连成一条带，
    /// 一行切出几十段，整注的格子全没了 —— 而号码照样读出来了，
    /// 用户只会看到"有一行没框"。
    func testRulesStayOutsideTheZone() {
        guard let frame = TicketFrame.between(rules: [rule(intercept: 51), rule(intercept: 301)],
                                              in: blankMask) else {
            return XCTFail("两条虚线应该夹得出号码区")
        }
        // 上虚线占 49.5–52.5 行，下虚线占 299.5–302.5 行
        XCTAssertGreaterThan(frame.topLeft.y, 52.5 / 400 - 1e-9, "上虚线整条在号码区外")
        XCTAssertLessThan(frame.bottomLeft.y, 299.5 / 400 + 1e-9, "下虚线整条在号码区外")
    }

    /// 上下颠倒着传进来也要摆对 —— 检测顺序不该影响结果。
    func testRulesSortedTopToBottom() {
        let frame = TicketFrame.between(rules: [rule(intercept: 301), rule(intercept: 51)],
                                        in: blankMask)
        XCTAssertEqual(frame?.topLeft.y ?? 1, (51 + inset) / 400, accuracy: 1e-9)
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
        let expectedLeft: CGFloat = (47 + 0.008 * 20 + 2.5) / 400
        let expectedRight: CGFloat = (47 + 0.008 * 969 + 2.5) / 400
        XCTAssertEqual(frame.topLeft.y, expectedLeft, accuracy: 1e-9)
        XCTAssertEqual(frame.topRight.y, expectedRight, accuracy: 1e-9)
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

    // MARK: - 文本行基准（主力）

    /// 按**左上原点**的坐标造一块文字（内部转成 Vision 的左下原点）。
    private func line(_ text: String, left: CGFloat, right: CGFloat, top: CGFloat,
                      height: CGFloat = 0.02,
                      slope: CGFloat = 0) -> TicketVisionScanner.TextFragment {
        func vision(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: 1 - y) }
        let drop = slope * (right - left)
        let topLeft = vision(left, top)
        let topRight = vision(right, top + drop)
        let bottomLeft = vision(left, top + height)
        let bottomRight = vision(right, top + height + drop)
        let low = Swift.min(bottomLeft.y, bottomRight.y)
        let high = Swift.max(topLeft.y, topRight.y)
        return .init(text: text,
                     box: CGRect(x: left, y: low, width: right - left, height: high - low),
                     topLeft: topLeft, topRight: topRight,
                     bottomLeft: bottomLeft, bottomRight: bottomRight)
    }

    /// 体彩：机号行 + 公益行夹出号码区。
    ///
    /// 这是**主力基准**。虚线要同时过五道阈值，其中「横跨 > 80% 宽度」的分母
    /// 本身就没有稳定答案，实测五张真票只稳住两张；而这两行文字每张票都有，
    /// Vision 给的还是四边形，一道阈值都不用过。
    func testFrameFromSportsLotteryTextLines() {
        let fragments = [
            line("第26102期 2026年09月07日开奖", left: 0.1, right: 0.9, top: 0.20),
            line("110310-292261-111967-377226 455878", left: 0.1, right: 0.9, top: 0.25),
            line("① 12 15 19 31 33 + 05 09", left: 0.15, right: 0.85, top: 0.40),
            line("感谢您为公益事业贡献 19.44元", left: 0.3, right: 0.7, top: 0.70)
        ]
        guard let frame = TicketFrame.betweenTextLines(
            fragments, anchors: .sportsLottery) else {
            return XCTFail("机号行 + 公益行应该夹得出号码区")
        }
        XCTAssertEqual(frame.anchor, .textLines)
        // 上边是机号行的**下沿**
        XCTAssertEqual(frame.topLeft.y, 0.27, accuracy: 1e-6)
        XCTAssertEqual(frame.topLeft.x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(frame.topRight.x, 0.9, accuracy: 1e-6)
        // 下边是公益行的**上沿**，而且横向被延长到和上边一样宽 ——
        // 公益行居中而且短，直接拿它定宽度会把号码切掉
        XCTAssertEqual(frame.bottomLeft.y, 0.70, accuracy: 1e-6)
        XCTAssertEqual(frame.bottomLeft.x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(frame.bottomRight.x, 0.9, accuracy: 1e-6)
    }

    /// 票是斜的时候，两条基准跟着斜，号码区是个平行四边形。
    func testTextLineFrameFollowsTheTilt() {
        let fragments = [
            line("110310-292261-111967-377226", left: 0.1, right: 0.9, top: 0.25, slope: 0.05),
            line("感谢您为公益事业贡献", left: 0.3, right: 0.7, top: 0.70, slope: 0.05)
        ]
        guard let frame = TicketFrame.betweenTextLines(
            fragments, anchors: .sportsLottery) else {
            return XCTFail("歪票也该夹得出号码区")
        }
        XCTAssertEqual(frame.topLeft.y, 0.27, accuracy: 1e-6)
        XCTAssertEqual(frame.topRight.y, 0.27 + 0.05 * 0.8, accuracy: 1e-6)
        // 公益行只覆盖 0.3–0.7，两端要按它自己的方向延长出去
        XCTAssertEqual(frame.bottomLeft.y, 0.70 - 0.05 * 0.2, accuracy: 1e-6)
        XCTAssertEqual(frame.bottomRight.y, 0.70 + 0.05 * 0.6, accuracy: 1e-6)
    }

    /// 福彩走另一对基准：哈希行 + 开奖期行。
    func testFrameFromWelfareLotteryTextLines() {
        let fragments = [
            line("玩法:3D-单式 机号:31130622", left: 0.1, right: 0.9, top: 0.20),
            line("7D92-04AE-1FB5-E411-B960/32798871/C084C", left: 0.1, right: 0.9, top: 0.25),
            line("开奖期:2026091 26-04-11 合计10元", left: 0.1, right: 0.8, top: 0.60)
        ]
        guard let frame = TicketFrame.betweenTextLines(
            fragments, anchors: .welfareLottery) else {
            return XCTFail("哈希行 + 开奖期行应该夹得出号码区")
        }
        XCTAssertEqual(frame.topLeft.y, 0.27, accuracy: 1e-6)
        XCTAssertEqual(frame.bottomLeft.y, 0.60, accuracy: 1e-6)
    }

    /// 两套正则互不相容：拿错了只会一条都匹配不上，不会认错行。
    func testAnchorPatternsDoNotCrossMatch() {
        let machine = "110310-292261-111967-377226 455878"
        let hash = "7D92-04AE-1FB5-E411-B960/32798871/C084C"
        let sports = TicketFrame.TextAnchors.sportsLottery.top
        let welfare = TicketFrame.TextAnchors.welfareLottery.top
        XCTAssertNotNil(machine.range(of: sports, options: .regularExpression))
        XCTAssertNil(machine.range(of: welfare, options: .regularExpression))
        XCTAssertNotNil(hash.range(of: welfare, options: .regularExpression))
        XCTAssertNil(hash.range(of: sports, options: .regularExpression))
    }

    /// 同一个模式命中好几行时：上基准取最靠下的，下基准取最靠上的 ——
    /// 中间夹出来的那一块才是号码区。
    func testAnchorLinePicksTheInnermost() {
        let fragments = [
            line("公益 上面那条", left: 0.3, right: 0.7, top: 0.60),
            line("公益 下面那条", left: 0.3, right: 0.7, top: 0.80)
        ]
        let bottom = TicketFrame.anchorLine(fragments, matching: "公益", lowest: false)
        XCTAssertEqual(bottom?.text, "公益 上面那条")
        let lowest = TicketFrame.anchorLine(fragments, matching: "公益", lowest: true)
        XCTAssertEqual(lowest?.text, "公益 下面那条")
    }

    /// 上下颠倒（公益行跑到机号行上面）时不硬凑，返回 nil。
    func testTextLineFrameRefusesInvertedAnchors() {
        let fragments = [
            line("感谢您为公益事业贡献", left: 0.3, right: 0.7, top: 0.20),
            line("110310-292261-111967-377226", left: 0.1, right: 0.9, top: 0.60)
        ]
        XCTAssertNil(TicketFrame.betweenTextLines(fragments, anchors: .sportsLottery))
    }

    // MARK: - 票头区

    /// 期号那一行要认得出来，而且只认号码区**上面**的。
    ///
    /// 票底那行出票时间（`26/09/07 10:01:58`）也带日期，认错的话票头区会倒着罩下来。
    func testIssueTopOnlyLooksAbove() {
        let fragments = [
            fragment("第26102期 2026年09月07日开奖", x: 0.1, y: 0.90, width: 0.6),
            fragment("20-020689-101 00008 26/09/07 10:01:58", x: 0.1, y: 0.08, width: 0.7)
        ]
        // 号码区顶在 0.25（左上原点）；期号那一行在它上面
        let top = TicketFrame.issueTop(fragments, above: 0.25)
        XCTAssertEqual(top ?? -1, 1 - 0.91, accuracy: 1e-6, "取的是期号行的顶")
    }

    /// 票头区接在号码区上面，**底边和号码区上边是同一条线**。
    ///
    /// 两块严丝合缝，基准找对没找对一眼就看得出来。
    func testHeadZoneSitsOnTheNumberZone() {
        guard let frame = TicketFrame.between(rules: [rule(intercept: 100, slope: 0.008),
                                                      rule(intercept: 300, slope: 0.008)],
                                              in: blankMask) else {
            return XCTFail("两条虚线应该夹得出号码区")
        }
        let headed = frame.addingHead(topAt: frame.topLeft.y - 0.05)
        guard let head = headed.headCorners, head.count == 4 else {
            return XCTFail("票头区没接上")
        }
        XCTAssertEqual(head[2], frame.topRight, "票头的右下角就是号码区的右上角")
        XCTAssertEqual(head[3], frame.topLeft, "票头的左下角就是号码区的左上角")
        // 上边和号码区的上边平行：票是斜的，框也得跟着斜
        let headSlope = (head[1].y - head[0].y) / (head[1].x - head[0].x)
        let zoneSlope = (frame.topRight.y - frame.topLeft.y) / (frame.topRight.x - frame.topLeft.x)
        XCTAssertEqual(headSlope, zoneSlope, accuracy: 1e-9)
        XCTAssertEqual(head[0].y, frame.topLeft.y - 0.05, accuracy: 1e-9)
    }

    /// 期号行算到票外面去、或者根本在号码区下面时，宁可不画。
    func testHeadZoneRefusesNonsense() {
        guard let frame = TicketFrame.between(rules: [rule(intercept: 51), rule(intercept: 301)],
                                              in: blankMask) else {
            return XCTFail("两条虚线应该夹得出号码区")
        }
        XCTAssertNil(frame.addingHead(topAt: frame.topLeft.y + 0.1).headCorners, "在号码区下面")
        XCTAssertNil(frame.addingHead(topAt: -0.5).headCorners, "顶到票外面去了")
    }

    // MARK: - 只量票面那一块

    /// 票面在照片里占的那一块：认出来的文字往外让一点。
    func testTicketRegionWrapsTheText() {
        let fragments = [
            fragment("体彩 超级大乐透", x: 0.30, y: 0.90, width: 0.4),
            fragment("① 12 15 19 31 33", x: 0.20, y: 0.50, width: 0.5),
            fragment("感谢您为公益事业贡献", x: 0.25, y: 0.20, width: 0.4)
        ]
        guard let region = TicketRegistration.ticketRegion(fragments) else {
            return XCTFail("票面框不出来")
        }
        // 文字横跨 0.20–0.70，往外让 3% 之后要比它稍宽，但绝不能铺满整张照片
        XCTAssertLessThan(region.minX, 0.20)
        XCTAssertGreaterThan(region.maxX, 0.70)
        XCTAssertLessThan(region.width, 0.6, "让出去的只是一点点，不是整张照片")
        XCTAssertGreaterThan(region.minY, 0.0)
    }

    /// 认出来的字太少时不硬框 —— 宁可退回按整张照片量。
    func testTicketRegionRefusesTooLittleText() {
        let tiny = [fragment("3", x: 0.5, y: 0.5, width: 0.02)]
        XCTAssertNil(TicketRegistration.ticketRegion(tiny))
    }

    /// 墨迹图里的坐标要能换算回整张照片。
    func testInkMaskMapsBackToTheWholePhoto() {
        let region = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        let mask = InkMask(width: 100, height: 200,
                           ink: [Bool](repeating: false, count: 100 * 200), region: region)
        let point = mask.imagePoint(x: 50, y: 100)
        XCTAssertEqual(point.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(point.y, 0.5, accuracy: 1e-9)
    }

    // MARK: - 票歪多少是量出来的

    /// 文字行自己的走向就是票面的倾角，不用挨个猜。
    ///
    /// Vision 的 y 向上、位图的 y 向下，所以这里**必须**反号：
    /// 文字行往右上走（Vision 里 y 变大），在位图里就是往右上，斜率为负。
    func testTextTiltFromLineDirection() {
        let size = CGSize(width: 1000, height: 500)
        var fragments: [TicketVisionScanner.TextFragment] = []
        for index in 0..<3 {
            let y = 0.4 + CGFloat(index) * 0.1
            fragments.append(TicketVisionScanner.TextFragment(
                text: "行\(index)",
                box: CGRect(x: 0.1, y: y, width: 0.4, height: 0.03),
                topLeft: CGPoint(x: 0.1, y: y),
                topRight: CGPoint(x: 0.5, y: y + 0.04)))
        }
        // dx = 0.4 * 1000 = 400px，dy = 0.04 * 500 = 20px
        let tilt = TicketVisionScanner.textTilt(fragments, size: size)
        XCTAssertEqual(tilt ?? 0, -0.05, accuracy: 1e-9)
    }

    /// 量不出来就老实返回 nil，让检测退回从正着扫一圈。
    func testTextTiltNeedsEnoughLines() {
        let short = [TicketVisionScanner.TextFragment(
            text: "3", box: CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.02),
            topLeft: CGPoint(x: 0.5, y: 0.52), topRight: CGPoint(x: 0.51, y: 0.52))]
        XCTAssertNil(TicketVisionScanner.textTilt(short, size: CGSize(width: 1000, height: 500)))
    }
}
