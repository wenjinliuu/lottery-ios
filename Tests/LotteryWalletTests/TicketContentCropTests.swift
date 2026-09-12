import XCTest
@testable import LotteryWallet

/// 复核页每张票下面那张缩略图，要裁到「有意义的内容」为止。
///
/// 票面底部的条形码和「XX市福利彩票发行中心承销」那行落款，核对时一点用没有，
/// 却占掉预览框近一半高度 —— 而它们**也会被 OCR 认出来**，所以不能简单地
/// 取「所有文字的并集」。
final class TicketContentCropTests: XCTestCase {

    /// Vision 的归一化坐标：原点左下角，y 向上为正。
    private func fragment(_ text: String, bottom: CGFloat, height: CGFloat = 0.04) -> TicketVisionScanner.TextFragment {
        TicketVisionScanner.TextFragment(
            text: text,
            box: CGRect(x: 0.1, y: bottom, width: 0.8, height: height)
        )
    }

    /// 一张典型的福彩票：落款和条码在最下面，应该被切掉。
    func testDropsBarcodeAndFooterBelowWelfareLine() {
        let fragments = [
            fragment("玩法: 双色球-单式", bottom: 0.88),
            fragment("A.11 13 14 27 31 33-04 (3)", bottom: 0.72),
            fragment("开奖期:2026106 26-09-13 合计18元", bottom: 0.52),
            fragment("销售期:2026104-25", bottom: 0.46),
            fragment("感谢您为公益慈善事业贡献6.48元", bottom: 0.38),
            // 下面这两块是要被丢掉的
            fragment("1234567890123456789", bottom: 0.14, height: 0.10),
            fragment("上海市福利彩票发行中心承销", bottom: 0.04)
        ]
        let kept = TicketVisionScanner.fragmentsAboveFooter(fragments)
        XCTAssertEqual(kept.count, 5)
        XCTAssertFalse(kept.contains { $0.text.contains("承销") })
        XCTAssertFalse(kept.contains { $0.text.contains("1234567890") })
        // 公益金那一行必须留着 —— 用户点名要裁到这里为止
        XCTAssertTrue(kept.contains { $0.text.contains("公益") })
    }

    /// 一个锚点都没有的票面：原样返回。
    ///
    /// 宁可裁得松一点，也不能因为一条启发式规则把号码那几行切掉 ——
    /// 体彩票面的用词和福彩不完全一样，不能假设锚点一定命中。
    func testKeepsEverythingWhenNoAnchorMatches() {
        let fragments = [
            fragment("超级大乐透", bottom: 0.80),
            fragment("01 13 18 27 33 + 04 07", bottom: 0.60),
            fragment("2 元 1 注", bottom: 0.40)
        ]
        XCTAssertEqual(TicketVisionScanner.fragmentsAboveFooter(fragments).count, 3)
    }

    /// 锚点落在票面很靠上的位置时不能采信 —— 那样会把大半张票切掉。
    func testFallsBackWhenAnchorWouldRemoveMostOfTheTicket() {
        let fragments = [
            fragment("合计 18元", bottom: 0.93),
            fragment("A.11 13 14 27 31 33-04", bottom: 0.60),
            fragment("B.08 11 14 19 20 29-16", bottom: 0.40),
            fragment("C.01 10 13 14 16 18-07", bottom: 0.20)
        ]
        // 只留「合计」那一行就等于把三注号码全丢了，必须退回原样
        XCTAssertEqual(TicketVisionScanner.fragmentsAboveFooter(fragments).count, 4)
    }
}
