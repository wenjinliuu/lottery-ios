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

    func testSlantedConvergingRowsRecoverWithoutMixingAdjacentBets() throws {
        for name in ["PickFiveTiltLeft", "PickFiveTiltRight"] {
            var ticket = ScannedTicket(game: .pl5)
            ticket.lines = [NumberSet([.nums5: [5,8,-1,4,3]]), NumberSet([.nums5: [6,3,0,9,-1]])]
            XCTAssertEqual(PrintedDigitRecovery.fill(&ticket, image: try load(name), zone: whole), 2, name)
            XCTAssertEqual(ticket.lines.map { $0[.nums5] }, [[5,8,3,4,3], [6,3,0,9,8]], name)
        }
    }

    func testScanPhotographedTicketsAfterFraming() async throws {
        func calendarEntry(_ issue: String, _ day: String) -> GameYearCalendar {
            let item = CalendarIssue(issue: issue, drawDate: day, weekday: 0, drawTime: "", saleCloseTime: "")
            return GameYearCalendar(name: "", drawWeekdays: [], drawTime: "", saleCloseTime: "", issues: [item])
        }
        let date = "2026-11-20"
        let calendar = DrawCalendarYear(year: 2026, lotteries: [
            GameKey.qxc.apiKey: calendarEntry("26133", date), GameKey.pl5.apiKey: calendarEntry("26310", date),
            GameKey.pl3.apiKey: calendarEntry("26310", date), GameKey.dlt.apiKey: calendarEntry("26133", "2026-11-21")
        ])
        for (name, game, rows, corners) in [
            ("SevenStarsScan", GameKey.qxc, [[2,0,4,3,7,2,7], [7,0,5,9,2,0,7]],
             [CGPoint(x:34,y:1), CGPoint(x:414,y:7), CGPoint(x:422,y:425), CGPoint(x:11,y:419)]),
            ("PickFiveScan", GameKey.pl5, [[5,8,3,4,3], [6,3,0,9,8]],
             [CGPoint(x:33,y:8), CGPoint(x:440,y:0), CGPoint(x:466,y:490), CGPoint(x:23,y:499)])
        ] {
            let image = UIImage(cgImage: try load(name))
            let points = corners.map { CGPoint(x: $0.x / image.size.width, y: $0.y / image.size.height) }
            let quad = TicketQuad(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
            let corrected = await TicketImagePreprocessor.prepare(image, quad: quad)
            let page = try await TicketVisionScanner.scan(corrected, calendars: [2026: calendar])
            XCTAssertEqual(page.result.tickets.count, 1, page.result.rawText)
            guard let ticket = page.result.tickets.first else { continue }
            XCTAssertEqual(ticket.game, game)
            let numbers = ticket.lines.map { line in game.sections.flatMap { line[$0.key] } }
            XCTAssertEqual(numbers, rows, page.result.rawText)
        }
    }

    func testAmbiguousRowsAndTwoDigitTail() throws {
        var ticket = ScannedTicket(game: .qxc)
        ticket.lines = [NumberSet([.nums6: [2,0,4,3,-1,2], .tail: [14]]),
                        NumberSet([.nums6: [2,0,4,3,-1,2], .tail: [10]])]
        XCTAssertEqual(PrintedDigitRecovery.fill(&ticket, image: try load("SevenStarsRows"), zone: whole), 0)
        XCTAssertEqual(ticket.lines.map { $0[.tail] }, [[14], [10]])
    }
}
