import XCTest
import SwiftData
@testable import LotteryWallet

/// 开奖数据先回号码、后回奖金（或者奖金先回一个占位值再更正）时，
/// 已经判了中奖的票要跟着改，不能一直挂着第一次那个金额。
///
/// 真实案例：大乐透七等奖先按 5 元结算，官方公布是 7 元。
@MainActor
final class PrizeCorrectionTests: XCTestCase {

    private var container: ModelContainer!
    private var store: DrawStore!
    private var service: RecordService!

    private let now = DateText.parse("2026-09-29 12:00:00")!

    override func setUp() async throws {
        let configuration = ModelConfiguration(schema: ModelStore.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: ModelStore.schema, configurations: [configuration])
        store = DrawStore()
        service = RecordService(context: container.mainContext, drawStore: store)
    }

    /// 大乐透 26110 期：前区 03 24 25 26 35，后区 07 09。
    private func draw(seventhPrize: String, issue: String = "26110", date: String = "2026-09-26") -> Draw {
        var draw = Draw()
        draw.gameKey = .dlt
        draw.expect = issue
        draw.openDate = date
        draw.id = "dlt_\(issue)_\(date)"
        draw.drawValues = NumberSet([.front: [3, 24, 25, 26, 35], .back: [7, 9]])
        draw.prizeList = [PrizeEntry(prizeName: "六等奖", singleBonus: "18"),
                          PrizeEntry(prizeName: "七等奖", singleBonus: seventhPrize)]
        return draw
    }

    /// 前区中 2 个、后区中 1 个：七等奖。
    private func insertTicket(issue: String = "26110", date: String = "2026-09-26") throws -> TicketRecord {
        let ticket = Ticket(numbers: NumberSet([.front: [3, 24, 1, 2, 4], .back: [7, 11]]), playMode: "normal")
        try service.save(tickets: [ticket], game: .dlt, entryKind: .manual, price: 2, multiple: 1,
                         target: DrawTarget(expect: issue, openDate: date, status: .confirmed),
                         source: "manual", createdAt: now.addingTimeInterval(-3 * 86_400))
        return try XCTUnwrap(service.allRecords().first)
    }

    func testRecentWinFollowsCorrectedPrize() throws {
        let record = try insertTicket()
        store.merge([draw(seventhPrize: "5")])
        let first = try service.checkAll(now: now)
        XCTAssertEqual(first.won, 1)
        XCTAssertEqual(record.prizeName, "七等奖")
        XCTAssertEqual(record.prizeAmount, 5)

        // 奖金更正：同一期再来一份
        store.merge([draw(seventhPrize: "7")])
        let second = try service.checkAll(now: now)
        XCTAssertEqual(record.prizeAmount, 7)
        XCTAssertEqual(record.resultText, "中奖 7元")
        XCTAssertEqual(second.checked, 1)
        XCTAssertEqual(second.won, 0, "改金额不算新中奖，不该再放烟花")
    }

    /// 数据没变就不写库，也不报「核对了一注」。
    func testUnchangedWinIsNotRewritten() throws {
        _ = try insertTicket()
        store.merge([draw(seventhPrize: "7")])
        _ = try service.checkAll(now: now)
        let again = try service.checkAll(now: now)
        XCTAssertEqual(again.checked, 0)
    }

    /// 开奖超过 30 天的老票不再跟着改 —— 那时候奖金早就定了，没必要每次启动都扫一遍全表。
    func testOldWinIsLeftAlone() throws {
        let record = try insertTicket(issue: "26050", date: "2026-05-02")
        store.merge([draw(seventhPrize: "5", issue: "26050", date: "2026-05-02")])
        _ = try service.checkAll(now: now)
        store.merge([draw(seventhPrize: "7", issue: "26050", date: "2026-05-02")])
        _ = try service.checkAll(now: now)
        XCTAssertEqual(record.prizeAmount, 5)
    }
}
