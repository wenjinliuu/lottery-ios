import XCTest
@testable import LotteryWallet

/// 预识别页的框要贴着票纸的边。
final class PaperEdgeTests: XCTestCase {
    private let width = 400, height = 600

    /// 暗背景上几块亮的「纸」。
    private func scene(_ papers: [(x: ClosedRange<Int>, y: ClosedRange<Int>)]) -> [UInt8] {
        var gray = [UInt8](repeating: 120, count: width * height)
        for paper in papers {
            for y in paper.y { for x in paper.x { gray[y * width + x] = 235 } }
        }
        return gray
    }

    private func box(_ x: ClosedRange<Double>, _ y: ClosedRange<Double>) -> [PaperEdge.Point] {
        [.init(x: x.lowerBound, y: y.lowerBound), .init(x: x.upperBound, y: y.lowerBound),
         .init(x: x.upperBound, y: y.upperBound), .init(x: x.lowerBound, y: y.upperBound)]
    }

    /// 文字的框比纸小一圈、还偏了一点：四条边都贴到纸边上。
    func testBoxSnapsOutToThePaper() {
        let gray = scene([(100...300, 100...450)])
        let fitted = PaperEdge.fit(gray, width: width, height: height, corners: box(130...270, 125...420))
        XCTAssertEqual(fitted[0].x, 100, accuracy: 3)
        XCTAssertEqual(fitted[0].y, 100, accuracy: 3)
        XCTAssertEqual(fitted[2].x, 300, accuracy: 3)
        XCTAssertEqual(fitted[2].y, 450, accuracy: 3)
    }

    /// 文字的框伸到纸外面去了（票头上方留得太多）：收回到纸边。
    func testBoxSnapsInWhenItOvershoots() {
        let gray = scene([(100...300, 150...450)])
        let fitted = PaperEdge.fit(gray, width: width, height: height, corners: box(90...310, 110...460))
        XCTAssertEqual(fitted[0].y, 150, accuracy: 3)
        XCTAssertEqual(fitted[0].x, 100, accuracy: 3)
        XCTAssertEqual(fitted[2].x, 300, accuracy: 3)
    }

    /// 两张票连着没撕开：中间没有暗缝，下面那条边留在原处，不能一路伸到下一张票里去。
    func testJoinedTicketsKeepTheSharedEdge() {
        let gray = scene([(100...300, 60...560)])
        let fitted = PaperEdge.fit(gray, width: width, height: height, corners: box(120...280, 80...300))
        XCTAssertEqual(fitted[2].y, 300, accuracy: 1, "找不到纸边的那条边不动")
        XCTAssertEqual(fitted[0].x, 100, accuracy: 3, "左右两边照样贴")
        XCTAssertEqual(fitted[1].x, 300, accuracy: 3)
    }

    /// 条码是一排黑白相间的竖条：往下找纸边时要穿过去，不能停在条码上沿。
    func testBottomEdgePassesThroughTheBarcode() {
        var gray = scene([(100...300, 100...480)])
        for y in 400...460 { for x in 120...280 where (x / 4) % 2 == 0 { gray[y * width + x] = 30 } }
        let fitted = PaperEdge.fit(gray, width: width, height: height, corners: box(110...290, 120...410))
        XCTAssertEqual(fitted[2].y, 480, accuracy: 3)
    }

    func testDarkPhotoOrBadInputLeavesTheBoxAlone() {
        let dark = [UInt8](repeating: 40, count: width * height)
        let original = box(130...270, 140...400)
        XCTAssertEqual(PaperEdge.fit(dark, width: width, height: height, corners: original), original)
        XCTAssertEqual(PaperEdge.fit([], width: width, height: height, corners: original), original)
    }
}
