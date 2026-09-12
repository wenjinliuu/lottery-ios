import XCTest
import CoreGraphics
@testable import LotteryWallet

/// 虚线检测。体彩数字型票的基准就是它。
///
/// 判据来自三张真票的实测（见 `Engineering/vision-rebuild.md`）：
/// 高 ≤ 6 行、横跨 > 80%、段数 ≥ 12、最长段 ≤ 5% 宽度、占空比 0.25–0.75。
/// 下面摆的这张"假票"按七星彩的实测版式画：数字 21 宽 29 高、列距 76。
final class DashedRuleDetectorTests: XCTestCase {

    private let width = 1000
    private let height = 400

    private final class Canvas {
        var ink: [Bool]
        let width: Int
        let height: Int
        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            ink = [Bool](repeating: false, count: width * height)
        }

        func fill(x: Range<Int>, y: Range<Int>) {
            for row in y where row >= 0 && row < height {
                for column in x where column >= 0 && column < width {
                    ink[row * width + column] = true
                }
            }
        }

        /// 一条长虚线：每 20px 印 10px，从 x=20 一直印到 x=970。
        func dashedRule(top: Int, thickness: Int = 3, slope: Double = 0) {
            for start in stride(from: 20, to: 980, by: 20) {
                for x in start..<(start + 10) {
                    let y = top + Int((slope * (Double(x) - Double(width) / 2)).rounded())
                    fill(x: x..<(x + 1), y: y..<(y + thickness))
                }
            }
        }

        /// 号码矩阵：一行 7 个数字，字 21 宽 29 高、列距 76（七星彩实测）。
        func digitRows(tops: [Int], slope: Double = 0) {
            for top in tops {
                for column in 0..<7 {
                    let left = 120 + column * 76
                    for x in left..<(left + 21) {
                        let y = top + Int((slope * (Double(x) - Double(width) / 2)).rounded())
                        fill(x: x..<(x + 1), y: y..<(y + 29))
                    }
                }
            }
        }

        var mask: InkMask { InkMask(width: width, height: height, ink: ink) }
    }

    private func ticket(slope: Double = 0) -> Canvas {
        let canvas = Canvas(width: width, height: height)
        canvas.dashedRule(top: 50, slope: slope)
        canvas.digitRows(tops: [100, 150, 200, 250], slope: slope)
        canvas.dashedRule(top: 300, slope: slope)
        return canvas
    }

    /// 摆正的票：上下两条虚线，一条不多一条不少。
    func testFindsExactlyTwoRules() {
        let rules = DashedRuleDetector.rules(in: ticket().mask)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].midY, 51, accuracy: 0.01, "上虚线的墨迹中心在第 51 行")
        XCTAssertEqual(rules[1].midY, 301, accuracy: 0.01)
        XCTAssertEqual(rules[0].slope, 0, accuracy: 1e-6, "票是正的，斜率就该是 0")
        XCTAssertEqual(rules[0].segments.count, 48)
        XCTAssertEqual(rules[0].columns, 20...969)
        XCTAssertEqual(rules[0].thickness, 3)
    }

    /// 号码那几行**不是**虚线：它们有 29 行高，第一条判据就把它们挡了。
    ///
    /// 这一条是整套判据的命根子 —— 把号码行认成基准的话，
    /// 配准出来的"号码区"整体错一行，而用户完全看不出来。
    func testDigitRowsAreNotRules() {
        let rules = DashedRuleDetector.rules(in: ticket().mask)
        for rule in rules {
            XCTAssertLessThanOrEqual(rule.thickness, 6)
            XCTAssertFalse((90...290).contains(Int(rule.midY)), "号码区里面不该有基准")
        }
    }

    /// 三种最像虚线的东西都必须被挡住：整条实线、一长串机号、只横跨半张票的点线。
    func testDecoysRejected() {
        let canvas = ticket()
        // 实线：横跨整张票，但只有一段
        canvas.fill(x: 20..<980, y: 360..<362)
        // 机号那一串：段够多、也够长，但有 20 行高
        for start in stride(from: 100, to: 900, by: 12) {
            canvas.fill(x: start..<(start + 6), y: 370..<390)
        }
        let rules = DashedRuleDetector.rules(in: canvas.mask)
        XCTAssertEqual(rules.count, 2, "两个诱饵都不该被当成虚线")

        // 只横跨半张票的点线
        let short = Canvas(width: width, height: height)
        for start in stride(from: 20, to: 480, by: 20) {
            short.fill(x: start..<(start + 10), y: 50..<53)
        }
        XCTAssertTrue(DashedRuleDetector.rules(in: short.mask).isEmpty, "横跨不够就不是基准")
    }

    /// 票还歪着 0.46° 时也得找得到 —— 而且要把倾角一并量出来。
    ///
    /// 这是**按行投影办不到**的事：一条横跨 950px 的线歪 0.46°，
    /// 摊开就是十几行高，「高 ≤ 6 行」当场判不出来。所以投影方向要跟着票斜。
    /// 预处理只在认出至少三块文字时才拉平基线，拉不动的票就是这个样子。
    func testTiltedTicketStillFound() {
        let tilted = ticket(slope: 0.008).mask
        XCTAssertNotEqual(DashedRuleDetector.rules(in: tilted, slope: 0,
                                                   criteria: .measured).count, 2,
                          "按行投影在歪票上找不齐 —— 这正是要沿倾角投影的原因")

        let rules = DashedRuleDetector.rules(in: tilted)
        XCTAssertEqual(rules.count, 2)
        // 扫倾角是 0.005 一档的粗粒度，但重心拟合能把真实倾角还原出来
        XCTAssertEqual(rules[0].slope, 0.008, accuracy: 0.0005)
        XCTAssertEqual(rules[1].slope, 0.008, accuracy: 0.0005)
        XCTAssertEqual(rules[0].y(at: 0), 47, accuracy: 0.5, "x=0 处这条线在第 47 行")
        XCTAssertEqual(rules[1].y(at: 0), 297, accuracy: 0.5)
    }

    /// 一张白纸上什么都没有。空图不能崩，也不能凭空找出基准。
    func testBlankImage() {
        let blank = Canvas(width: width, height: height)
        XCTAssertTrue(DashedRuleDetector.rules(in: blank.mask).isEmpty)
        XCTAssertNil(TicketFrame.between(rules: [], in: blank.mask))
    }
}
