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

    func testWelfareGameComesFromPrintedFieldAcrossLayouts() {
        let issuer = "中国福利彩票\n第2026123期\nA01B-A02C-A03D/12345678"
        let samples: [(String, GameKey)] = [
            ("双色球", .ssq), ("玩法：\n快乐 八-选五", .k8),
            ("七乐彩-单式", .qlc), ("玩法:3D-单式", .fc3d)
        ]
        for (field, game) in samples {
            let text = issuer + "\n" + field
            XCTAssertEqual(TicketTextParser.detectGame(text, guess: false), game)
            XCTAssertEqual(TicketHeaderModel.Label.welfare.identifiesGame(in: text), game)
        }
        for missing in ["", "玩法：单式\n① 3 2 1", "购买双色球获赠好礼", "双色球与快乐8联合促销"] {
            XCTAssertNil(TicketTextParser.detectGame(issuer + "\n" + missing))
        }
        XCTAssertNil(TicketTextParser.detectGame(issuer + "\n玩法：双色球\n彩种：快乐八"))
    }

    func testIssueAndPlayFieldStayOnOneTicket() {
        let text = "中国福利彩票\n第2026123期\n玩法：双色球-单式\nA.01 02 03 04 05 06-07"
        XCTAssertEqual(TicketTextParser.splitBlocks(text).count, 1)
        XCTAssertEqual(TicketTextParser.parse(text).tickets.map(\.game), [.ssq])
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
