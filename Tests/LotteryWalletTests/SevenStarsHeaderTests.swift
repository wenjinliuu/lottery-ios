import UIKit
import XCTest
@testable import LotteryWallet

final class SevenStarsHeaderTests: XCTestCase {
    func testIssuerAndGameEvidence() {
        XCTAssertNil(TicketHeaderModel.Label.welfare.identifiesGame(in: "中国福利彩票"))
        XCTAssertEqual(TicketHeaderModel.Label.welfare.identifiesGame(in: "中国福利彩票\n期号\n玩法：双色球-单式"), .ssq)
        XCTAssertNil(TicketHeaderModel.Label.dlt.identifiesGame(in: "中国福利彩票 +"))
        XCTAssertNil(TicketHeaderModel.Label.pl5.identifiesGame(in: "体彩"))
        XCTAssertEqual(TicketHeaderModel.Label.dlt.identifiesGame(in: "体彩 01 05 + 08"), .dlt)
    }

    func testBundledSportsHeader() throws {
        let model = try XCTUnwrap(TicketHeaderModel.shared)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "HeaderDLT", withExtension: "png"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        XCTAssertEqual(model.classify(image), .dlt)
    }

    func testReadsSoftRotatedWordmarkWithoutAnyTicketTextOrDigits() throws {
        let model = try XCTUnwrap(TicketHeaderModel.shared)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SevenStarsLogo", withExtension: "png"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        XCTAssertEqual(model.classify(image), .qxc)
        let blank = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 110, width: 200, height: 150)))
        XCTAssertNil(model.classify(blank))
    }
}
