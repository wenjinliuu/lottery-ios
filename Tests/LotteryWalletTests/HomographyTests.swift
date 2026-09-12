import XCTest
import CoreGraphics
@testable import LotteryWallet

/// 单应变换。配准这一步的全部数学就在这里。
///
/// 这些用例都是手算得出的几何事实，不是从实现反推的：
/// 四组对应点定死一个单应，映射过去必须**正好**落在目标点上。
final class HomographyTests: XCTestCase {

    private let unitSquare = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                              CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]

    private func assertClose(_ a: CGPoint?, _ b: CGPoint,
                             accuracy: CGFloat = 1e-6,
                             _ message: String = "",
                             line: UInt = #line) {
        guard let a else { return XCTFail("映射不出来 \(message)", line: line) }
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, line: line)
    }

    /// 一个矩形映射到自己，什么都不该变。
    func testIdentity() {
        let homography = Homography.mapping(unitSquare, to: unitSquare)
        XCTAssertNotNil(homography)
        assertClose(homography?.map(CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 0.5, y: 0.5))
        assertClose(homography?.map(CGPoint(x: 0.25, y: 0.75)), CGPoint(x: 0.25, y: 0.75))
    }

    /// 四个角必须**正好**落到目标的四个角上 —— 这是解出来的定义。
    func testCornersLandExactly() {
        // 梯形：上边比下边长，就是从斜上方拍一张票的样子
        let trapezoid = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0),
                         CGPoint(x: 1.5, y: 1), CGPoint(x: 0.5, y: 1)]
        guard let homography = Homography.mapping(unitSquare, to: trapezoid) else {
            return XCTFail("解不出单应")
        }
        for (source, target) in zip(unitSquare, trapezoid) {
            assertClose(homography.map(source), target, accuracy: 1e-9)
        }
    }

    /// 反变换。号码格子是在标准矩形里划的，要裁回票面上认，靠的就是它。
    func testInverseRoundTrip() {
        let quad = [CGPoint(x: 0.12, y: 0.20), CGPoint(x: 0.88, y: 0.17),
                    CGPoint(x: 0.91, y: 0.34), CGPoint(x: 0.10, y: 0.37)]
        guard let forward = Homography.mapping(quad, to: unitSquare),
              let backward = forward.inverse else {
            return XCTFail("解不出单应")
        }
        for point in [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.5, y: 0.5)] {
            guard let there = forward.map(point) else { return XCTFail("映射不出来") }
            assertClose(backward.map(there), point, accuracy: 1e-6)
        }
    }

    /// 透视是**非线性**的：梯形腰上的中点，配准后不在标准矩形的中间。
    ///
    /// 这一条正是配准的意义所在。这个梯形上边宽 4、下边宽 2，
    /// 手算得出中点落在 1/3 而不是 1/2 —— 差了整整六分之一个号码区高度。
    /// 靠"按比例取中间"那种线性估算去摆行，在有透视的票上必然偏，
    /// 而偏出来的结果看着还挺像回事（这正是最危险的那类错）。
    func testPerspectiveIsNotLinear() {
        let trapezoid = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0),
                         CGPoint(x: 3, y: 2), CGPoint(x: 1, y: 2)]
        guard let homography = Homography.mapping(trapezoid, to: unitSquare),
              let middle = homography.map(CGPoint(x: 2, y: 1)) else {
            return XCTFail("解不出单应")
        }
        XCTAssertEqual(middle.x, 0.5, accuracy: 1e-9, "左右对称，中线还是中线")
        XCTAssertEqual(middle.y, 1.0 / 3.0, accuracy: 1e-9, "不是 0.5")
    }

    /// 四个点缩成一个点时解不出来，要老老实实返回 nil。
    func testDegenerateReturnsNil() {
        let collapsed = [CGPoint](repeating: .zero, count: 4)
        XCTAssertNil(Homography.mapping(collapsed, to: unitSquare))
        XCTAssertNil(Homography.mapping(unitSquare, to: [CGPoint(x: 0, y: 0)]))
    }
}
