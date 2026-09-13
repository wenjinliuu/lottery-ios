import XCTest
import CoreGraphics
@testable import LotteryWallet

/// 票面合计、倍数、票种 —— 这三样印在**同一行**上，而它们读不到时全是默认值
/// （`?? 1` 倍、`.single` 单式）。这一行丢了，一张 2 倍的票会安安静静显示 1 倍，
/// 唯一能发现这件事的金额校验也在同一行、一起没了。
final class TicketChecksumTests: XCTestCase {

    // MARK: - compose 不许把合计那一行吃掉

    /// 26042 那张七星彩量出来的真实版式（票面缩到 1000 宽，高 1157）：
    ///
    /// | | 纵向 | 归一化 |
    /// |---|---|---|
    /// | `单式票 1倍 合计10元` | 369–405 | 0.319–0.350 |
    /// | 第一注 | 416–449 | 0.359–0.388 |
    /// | 五注整块（含倾角撑开 6px） | 410–649 | 0.354–0.561 |
    ///
    /// 两行只隔 11px，而行高 35。上一版「纵向沾一点就算号码行 → 整行丢」
    /// 在这个版式上**必然**把合计那一行吃掉。
    func testTotalRowSurvivesRightAboveTheNumberBlock() {
        let span: ClosedRange<CGFloat> = 0.354...0.561
        XCTAssertFalse(TicketVisionScanner.isNumberRow(0.319...0.350, in: span),
                       "合计那一行一点都没落进号码块")
        // Vision 的文字框自带上下留白，最坏情况蹭进去一点点 —— 还是不算号码行
        XCTAssertFalse(TicketVisionScanner.isNumberRow(0.315...0.356, in: span),
                       "蹭进去 2px 不算号码行")
        XCTAssertTrue(TicketVisionScanner.isNumberRow(0.359...0.388, in: span),
                      "第一注整个在里面")
    }

    /// 判据的分母是**行自己的高度**，不是矩阵那一段。
    /// 拿矩阵当分母的话，每一行的占比都很小，判据永远不成立，号码行全留着。
    func testMajorityIsMeasuredAgainstTheRowNotTheBlock() {
        let span: ClosedRange<CGFloat> = 0.2...0.8
        XCTAssertTrue(TicketVisionScanner.isNumberRow(0.30...0.34, in: span))
        // 一半一半：正好压在边界上的行不算号码行，宁可留着
        XCTAssertFalse(TicketVisionScanner.isNumberRow(0.15...0.25, in: span))
    }

    // MARK: - 「台计」

    /// 真机实测：排列3 的识别原文是 `组选单式票 1倍 台计6元` ——
    /// `合` 被认成 `台`（就差顶上那一横），整张票的金额校验就此没了。
    func testMisreadTotalCharactersStillParse() {
        XCTAssertEqual(TicketTextParser.extractTotal("组选单式票 1倍 台计6元"), 6)
        XCTAssertEqual(TicketTextParser.extractTotal("单式票 1倍 合计10元"), 10)
        XCTAssertEqual(TicketTextParser.extractTotal("直选单式票 1倍 合计4元"), 4)
        XCTAssertEqual(TicketTextParser.extractTotal("共计 12 元"), 12)
        XCTAssertEqual(TicketTextParser.extractTotal("合计32.00元"), 32)
    }

    /// **不能**把票底那行公益金当成票面合计 —— 前缀照旧是必须的。
    func testDonationLineIsNotTheTicketTotal() {
        XCTAssertNil(TicketTextParser.extractTotal("感谢您为公益事业贡献 3.70元"))
        XCTAssertNil(TicketTextParser.extractTotal("感谢您 公益事业贡献 2.04元"))
        XCTAssertNil(TicketTextParser.extractTotal("理性购买彩票 享受小小乐趣"))
    }
}
