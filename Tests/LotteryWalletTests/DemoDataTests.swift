import XCTest
import SwiftData
@testable import LotteryWallet

/// `--demo-data` 的示例票据。截图、UI 测试都靠它，所以把它答应过的几件事锁住：
/// 只有双色球和大乐透、覆盖 6 月 1 日到 9 月 27 日、六成的票中奖、投入五六百、整体赚钱，
/// 而且奖级是 App 自己的 `PrizeRules` 按真实开奖号码判出来的。
@MainActor
final class DemoDataTests: XCTestCase {

    private lazy var records = DemoData.records()
    private lazy var draws = DemoData.draws()

    func testOnlyDoubleColorAndSuperLotto() {
        XCTAssertFalse(records.isEmpty)
        XCTAssertEqual(Set(records.map(\.game)), [.ssq, .dlt])
    }

    /// 每一期都有一张票，一期不落，也不越出 6-01 到 9-27。
    func testEveryDrawFromJuneToSeptember27HasOneTicket() {
        let days = records.map(\.targetOpenDate)
        XCTAssertEqual(days.min(), "2026-06-01")
        XCTAssertEqual(days.max(), "2026-09-27")
        let ticketed = Set(records.map { "\($0.game.rawValue)_\($0.targetExpect)" })
        let drawn = Set(draws.map { "\($0.gameKey.rawValue)_\($0.expect)" })
        XCTAssertEqual(ticketed, drawn)
        XCTAssertEqual(Set(records.map(\.batchId)).count, draws.count)
    }

    /// 按张算六成中奖：一张票里有一注中了就算这张中了。
    func testSixtyPercentOfTicketsWin() {
        let batches = Dictionary(grouping: records, by: \.batchId)
        let won = batches.values.filter { $0.contains { $0.status == .won } }.count
        XCTAssertEqual(Double(won) / Double(batches.count), 0.6, accuracy: 0.02)
    }

    /// 投入五六百块，整体是赚的。
    func testSpendsFiveToSixHundredAndEndsInProfit() {
        let cost = records.reduce(0) { $0 + $1.cost }
        let prize = records.reduce(0) { $0 + $1.prizeAmount }
        XCTAssertGreaterThanOrEqual(cost, 500)
        XCTAssertLessThanOrEqual(cost, 600)
        XCTAssertGreaterThan(prize - cost, 0)
    }

    /// 全部已结算、带逐球命中标记，奖金都是确定值，不会停在「奖金待公布」。
    func testEveryRecordIsSettledWithMatches() {
        for record in records {
            XCTAssertTrue(record.status == .won || record.status == .lost, record.id)
            XCTAssertTrue(record.hasMatches, record.id)
            XCTAssertEqual(record.status == .won, record.prizeAmount > 0, record.id)
            XCTAssertEqual(record.profitDay, record.targetOpenDate, record.id)
        }
    }

    /// 落库的结论和拿同一期开奖重新核对的结论一致。
    func testStoredResultsMatchPrizeRules() {
        var index: [String: Draw] = [:]
        for draw in draws { index["\(draw.gameKey.rawValue)_\(draw.expect)"] = draw }
        for record in records {
            guard let draw = index["\(record.game.rawValue)_\(record.targetExpect)"] else {
                return XCTFail("\(record.id) 找不到开奖")
            }
            let result = PrizeRules.evaluate(gameKey: record.game, ticket: record.ticket, draw: draw)
            XCTAssertEqual(record.prizeName, result.prizeName, record.id)
            XCTAssertEqual(record.prizeAmount, result.amount, record.id)
        }
    }

    /// 只有最近几张票留着「没看过」，票夹角标才有数字可看。
    func testOnlyLatestBatchesAreUnseen() {
        let unseen = Set(records.filter { $0.resultSeenAt == nil }.map(\.batchId))
        XCTAssertEqual(unseen.count, DemoData.unseenBatchCount)
        let latest = records.map(\.targetOpenDate).max()
        XCTAssertTrue(records.filter { unseen.contains($0.batchId) }.contains { $0.targetOpenDate == latest })
    }

    /// 示例库只在内存里，播种后能按正常路径读出来。
    func testContainerIsInMemoryAndSeeded() throws {
        let container = DemoData.makeContainer()
        XCTAssertTrue(container.configurations.allSatisfy(\.isStoredInMemoryOnly))
        let count = try container.mainContext.fetchCount(FetchDescriptor<TicketRecord>())
        XCTAssertEqual(count, records.count)
    }
}
