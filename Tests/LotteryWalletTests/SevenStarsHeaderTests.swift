import UIKit
import XCTest
@testable import LotteryWallet

final class SevenStarsHeaderTests: XCTestCase {
    func testReadsSoftRotatedWordmarkWithoutAnyTicketTextOrDigits() throws {
        let model = try XCTUnwrap(SevenStarsHeader.shared)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SevenStarsLogo", withExtension: "png"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        XCTAssertTrue(model.matches(image))
        let blank = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 110, width: 200, height: 150)))
        XCTAssertFalse(model.matches(blank))
    }
}
