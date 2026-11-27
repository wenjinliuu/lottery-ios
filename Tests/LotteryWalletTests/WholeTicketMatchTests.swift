import XCTest
@testable import LotteryWallet

final class WholeTicketMatchTests: XCTestCase {
    private func zones(game: GameKey, selected: [SectionKey: [Int]],
                       drawNumbers: [SectionKey: [Int]]?, mode: EntryMode = .system,
                       dan: [SectionKey: [Int]] = [:]) throws -> [TicketCard.WholeZone] {
        let selections = selected.map { key, values in
            (key, SectionSelection(selected: values, dan: dan[key] ?? []))
        }
        let tickets = try XCTUnwrap(TicketBuilder.expand(game: game,
            selections: Dictionary(uniqueKeysWithValues: selections), mode: mode,
            playMode: "", addOn: false))
        let records = tickets.enumerated().map { index, ticket in
            let record = TicketRecord(id: "r\(index)", batchId: "batch", game: game,
                ticket: ticket, entryKind: mode.kind,
                target: DrawTarget(expect: "test", openDate: "2026-09-20"),
                price: 2, multiple: 1, source: "test")
            if let drawNumbers {
                let draw = Draw(gameKey: game, drawValues: NumberSet(drawNumbers))
                let result = game == .ssq
                    ? PrizeRules.evaluateSSQ(ticket: ticket, draw: draw)
                    : PrizeRules.evaluateDLT(ticket: ticket, draw: draw)
                record.matched = result.matched
                record.status = result.isWin ? .prizeFloat : .lost
            }
            return record
        }
        return TicketCard.wholeZones(records, game: game)
    }

    func testSSQBlueSystemWithZeroHitsStillHasCheckedResult() throws {
        let zones = try zones(game: .ssq,
            selected: [.red: [1, 2, 3, 4, 5, 6, 7], .blue: [1, 2, 3]],
            drawNumbers: [.red: [1, 2, 3, 4, 5, 6], .blue: [16]])
        let blue = try XCTUnwrap(zones.first { $0.key == .blue })
        XCTAssertEqual(blue.selected, [1, 2, 3])
        XCTAssertTrue(blue.hits.isEmpty)
        XCTAssertTrue(blue.hasResult, "All misses must be dimmed after checking")
        XCTAssertEqual(zones.first { $0.key == .red }?.hits, Set([1, 2, 3, 4, 5, 6]))
    }

    func testDLTBackSystemOnlyHighlightsActualHits() throws {
        for back in [[11, 12], [2, 12], [1, 3]] {
            let zones = try zones(game: .dlt,
                selected: [.front: [1, 2, 3, 4, 5, 6], .back: [1, 2, 3]],
                drawNumbers: [.front: [1, 2, 3, 4, 5], .back: back])
            let zone = try XCTUnwrap(zones.first { $0.key == .back })
            XCTAssertTrue(zone.hasResult)
            XCTAssertEqual(zone.hits, Set(back).intersection([1, 2, 3]))
        }
    }

    func testUncheckedSystemPreservesNormalBallColors() throws {
        let zones = try zones(game: .ssq,
            selected: [.red: [1, 2, 3, 4, 5, 6], .blue: [1, 2, 3]],
            drawNumbers: nil)
        XCTAssertFalse(zones.isEmpty)
        XCTAssertTrue(zones.allSatisfy { !$0.hasResult && $0.hits.isEmpty })
    }

    func testDantuoSeparatesCheckedStateFromZeroHits() throws {
        let zones = try zones(game: .dlt,
            selected: [.front: [1, 2, 3, 4, 5, 6, 7], .back: [1, 2, 3]],
            drawNumbers: [.front: [1, 2, 3, 4, 5], .back: [11, 12]],
            mode: .dantuo, dan: [.front: [1, 2]])
        XCTAssertEqual(zones.first { $0.key == .front }?.dan, Set([1, 2]))
        let back = try XCTUnwrap(zones.first { $0.key == .back })
        XCTAssertTrue(back.hasResult)
        XCTAssertTrue(back.hits.isEmpty)
    }

    func testPositionalSystemAndGroup3SystemWholeZones() throws {
        // 排列3 直选定位复式：[0,1] × [2,3] × [5] = 4 注
        let pl3Tickets = try XCTUnwrap(TicketBuilder.expand(
            game: .pl3,
            selections: [.nums3: SectionSelection(positional: [[0, 1], [2, 3], [5]])],
            mode: .system, playMode: "single", addOn: false
        ))
        let draw = Draw(gameKey: .pl3, drawValues: NumberSet([.nums: [1, 3, 8]]))
        let pl3Records = pl3Tickets.enumerated().map { idx, t in
            let r = TicketRecord(id: "p\(idx)", batchId: "b", game: .pl3, ticket: t,
                                 entryKind: .system, target: DrawTarget(), price: 2, multiple: 1, source: "test")
            let eval = PrizeRules.evaluate(gameKey: .pl3, ticket: t, draw: draw, multiple: 1)
            r.matched = eval.matched
            r.status = eval.amount > 0 ? .won : .lost
            return r
        }
        let pl3Zones = TicketCard.wholeZones(pl3Records, game: .pl3)
        let zone = try XCTUnwrap(pl3Zones.first { $0.key == .nums3 })
        XCTAssertEqual(zone.positional, [[0, 1], [2, 3], [5]])
        XCTAssertEqual(zone.positionalHits, [Set([1]), Set([3]), Set()])

        // 排列3 组选3 复式 2 号（2 注）还原整票
        let g3Tickets = try XCTUnwrap(TicketBuilder.expand(
            game: .pl3,
            selections: [.nums3: SectionSelection(selected: [2, 7])],
            mode: .system, playMode: "group3", addOn: false
        ))
        let g3Records = g3Tickets.enumerated().map { idx, t in
            TicketRecord(id: "g\(idx)", batchId: "bg", game: .pl3, ticket: t,
                         entryKind: .system, target: DrawTarget(), price: 2, multiple: 1, source: "test")
        }
        let g3Zone = try XCTUnwrap(TicketCard.wholeZones(g3Records, game: .pl3).first)
        XCTAssertEqual(g3Zone.selected, [2, 7])
        XCTAssertTrue(g3Zone.dan.isEmpty)

        // 两注互不相干的排列3 单式，不得误拼成定位复式
        let plain = [
            TicketRecord(id: "s1", batchId: "bs", game: .pl3,
                         ticket: Ticket(numbers: NumberSet([.nums3: [1, 2, 3]]), playMode: "single", entryLabel: "单式票"),
                         entryKind: .manual, target: DrawTarget(), price: 2, multiple: 1, source: "test"),
            TicketRecord(id: "s2", batchId: "bs", game: .pl3,
                         ticket: Ticket(numbers: NumberSet([.nums3: [4, 5, 6]]), playMode: "single", entryLabel: "单式票"),
                         entryKind: .manual, target: DrawTarget(), price: 2, multiple: 1, source: "test")
        ]
        XCTAssertTrue(TicketCard.wholeZones(plain, game: .pl3).isEmpty)
    }
}
