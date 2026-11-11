import XCTest
@testable import LotteryWallet

/// 号码区是用上下两行文字夹出来的。
final class NumberZoneTests: XCTestCase {

    private func line(_ text: String, x: ClosedRange<Double>, y: ClosedRange<Double>) -> NumberZone.Line {
        .init(text: text, minX: x.lowerBound, maxX: x.upperBound, minY: y.lowerBound, maxY: y.upperBound)
    }

    func testSportsTicketZoneRunsFromTheTotalRowToTheFirstSentence() throws {
        let lines = [
            line("体彩 超级大乐透", x: 150...450, y: 20...60),
            line("第26122期 2026年10月26日开奖", x: 40...560, y: 80...100),
            // 流水号被认成两截：后一截单独一块
            line("182312-610260-001364-284765 029261", x: 40...470, y: 104...124),
            line("qRxikg", x: 490...560, y: 104...124),
            line("套餐票", x: 40...110, y: 150...170),
            line("合计18元", x: 470...562, y: 150...170),
            line("①11 16 21 32 35 + 11 12", x: 60...540, y: 176...196),
            line("前区 02 15 30 31 33", x: 40...330, y: 330...350),
            line("购彩买套餐，好礼翻翻翻", x: 150...450, y: 420...440),
            line("感谢您为公益事业贡献 6.48元", x: 100...500, y: 700...720),
        ]
        let bounds = try XCTUnwrap(NumberZone.bounds(lines, sports: true, imageWidth: 600))
        XCTAssertEqual(bounds.top, 160, accuracy: 0.01, "从「合计」那一行的半腰起算")
        XCTAssertEqual(bounds.bottom, 420, accuracy: 0.01, "到第一行整句的话为止；「前区」只有两个汉字，不算")
        XCTAssertLessThan(bounds.left, 40)
        XCTAssertGreaterThan(bounds.right, 562, "右边界要包住「合计N元」的右端，不能只看流水号")
    }

    func testWelfareTicketZoneRunsFromTheHashRowToTheDrawDateRow() throws {
        let lines = [
            line("中国福利彩票", x: 100...500, y: 10...50),
            line("3F2A-9C41-77B0-1D5E-2A60/51849273/26079", x: 50...550, y: 90...110),
            line("A. 07 11 15 21 27 30 - 01 (3)", x: 50...520, y: 130...150),
            line("开奖期:2026-07-12 合计:18元", x: 50...500, y: 300...320),
        ]
        let bounds = try XCTUnwrap(NumberZone.bounds(lines, sports: false, imageWidth: 600))
        XCTAssertEqual(bounds.top, 110, accuracy: 0.01)
        XCTAssertEqual(bounds.bottom, 300, accuracy: 0.01)
        XCTAssertEqual(bounds.right, 600, accuracy: 0.01)
    }

    func testNoAnchorRowsMeansNoZone() {
        XCTAssertNil(NumberZone.bounds([line("① 5 2 0 9 1", x: 0...100, y: 0...20)], sports: true, imageWidth: 600))
    }

    /// 采样：一张左半黑右半白的图，取右半边，出来应该全是白的；宽度固定 1000。
    func testSamplingTakesExactlyTheRequestedRegion() throws {
        let width = 400, height = 100
        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 200..<width { gray[y * width + x] = 255 } }
        let zone = try XCTUnwrap(NumberZone.sample(gray, width: width, height: height,
                                                   bounds: .init(top: 10, bottom: 60, left: 210, right: 390)))
        XCTAssertEqual(zone.width, 1000)
        XCTAssertEqual(zone.height, Int(50.0 * 1000 / 180))
        XCTAssertTrue(zone.pixels.allSatisfy { $0 == 255 })
    }
}
