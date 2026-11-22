import UIKit
import XCTest
@testable import LotteryWallet

final class PrintedDigitRecoveryTests: XCTestCase {
    private let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    private func load(_ name: String) throws -> CGImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "png"))
        return try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
    }

    func testSevenStarsOnPhotographedRows() throws {
        var ticket = ScannedTicket(game: .qxc)
        ticket.lines = [NumberSet([.nums6: [2,0,4,3,-1,2], .tail: [7]]),
                        NumberSet([.nums6: [7,0,5,9,2,0], .tail: [7]])]
        XCTAssertEqual(PrintedDigitRecovery.fill(&ticket, image: try load("SevenStarsRows"), zone: whole), 1)
        XCTAssertEqual(ticket.lines[0][.nums6], [2,0,4,3,7,2])
        XCTAssertEqual(ticket.lines[1][.nums6], [7,0,5,9,2,0])
        XCTAssertEqual(ticket.lines.map { $0[.tail] }, [[7], [7]])
    }

    func testPickFiveOnPhotographedRows() throws {
        var ticket = ScannedTicket(game: .pl5)
        ticket.lines = [NumberSet([.nums5: [5,8,-1,4,3]]), NumberSet([.nums5: [6,3,0,9,-1]])]
        XCTAssertEqual(PrintedDigitRecovery.fill(&ticket, image: try load("PickFiveRows"), zone: whole), 2)
        XCTAssertEqual(ticket.lines.map { $0[.nums5] }, [[5,8,3,4,3], [6,3,0,9,8]])
    }

    func testAmbiguousRowsAndTwoDigitTail() throws {
        var ticket = ScannedTicket(game: .qxc)
        ticket.lines = [NumberSet([.nums6: [2,0,4,3,-1,2], .tail: [14]]),
                        NumberSet([.nums6: [2,0,4,3,-1,2], .tail: [10]])]
        XCTAssertEqual(PrintedDigitRecovery.fill(&ticket, image: try load("SevenStarsRows"), zone: whole), 0)
        XCTAssertEqual(ticket.lines.map { $0[.tail] }, [[14], [10]])
    }
}
