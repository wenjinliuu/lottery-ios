import XCTest
@testable import LotteryWallet

/// 复式 / 胆拖票的中奖明细。
///
/// 起因是一张真实的复式票：中了奖，票夹上只有票尾一个净收支「+¥15」——
/// 看不出那是中了 1 注 20 块，还是 3 注各 5 块。
///
/// 复式和胆拖是**按整票画**的，没有单式那种逐注「+¥X」可看，所以中奖注数
/// 和奖金必须由整票那行小结给出来。这一组用例钉的就是「两种票型都算得对」，
/// 而不是只有复式对。
final class TicketCardPrizeTests: XCTestCase {

    // MARK: - 造票

    /// 用真实的展开逻辑造一张复式 / 胆拖票。
    ///
    /// **不手写那几注号码。** `TicketCard.wholeZones` 会拿展开数和记录条数
    /// 对账（对不上就当成互不相干的单式），手写号码很容易造出一张
    /// 「看起来像复式、其实对不上账」的票，那时候测的就不是这个功能了。
    private func records(game: GameKey,
                         selections: [SectionKey: SectionSelection],
                         mode: EntryMode,
                         prizes: [Double],
                         statuses: [RecordStatus]) -> [TicketRecord] {
        let tickets = TicketBuilder.expand(game: game,
                                           selections: selections,
                                           mode: mode,
                                           playMode: "",
                                           addOn: false) ?? []
        XCTAssertEqual(tickets.count, prizes.count, "前提没对上：展开注数和给定的奖金条数不一致")
        XCTAssertEqual(tickets.count, statuses.count)
        return tickets.enumerated().map { index, ticket in
            // `entryLabel` 用 `expand` 自己写进去的那个（`EntryMode.label`），
            // 不在测试里另写一份 —— 票面类型是靠它判的，写死等于绕开真实路径。
            // id 必须**补零**：`TicketBatch.group` 是按 id 字符串排序的，
            // 不补零的话 "r10" < "r2"，展开顺序和卡片里的顺序对不上，
            // 「第 200 注」到底落在哪儿就说不准了。
            let record = TicketRecord(id: String(format: "r%04d", index),
                                      batchId: "batch",
                                      game: game,
                                      ticket: ticket,
                                      entryKind: mode.kind,
                                      target: DrawTarget(expect: "2026109", openDate: "2026-09-20"),
                                      price: 2,
                                      multiple: 1,
                                      source: "test")
            record.prizeAmount = prizes[index]
            record.status = statuses[index]
            return record
        }
    }

    private func card(_ records: [TicketRecord]) throws -> TicketCard {
        let batches = TicketBatch.group(records)
        let batch = try XCTUnwrap(batches.first)
        return TicketCard(batch: batch)
    }

    // MARK: - 复式

    /// 双色球红球 7 个复式 → 7 注，其中 2 注中奖。
    func testSystemTicketCountsWinningLines() throws {
        let items = records(game: .ssq,
                            selections: [.red: SectionSelection(selected: [1, 2, 3, 4, 5, 6, 7]),
                                         .blue: SectionSelection(selected: [8])],
                            mode: .system,
                            prizes: [0, 10, 0, 5, 0, 0, 0],
                            statuses: [.lost, .won, .lost, .won, .lost, .lost, .lost])
        let card = try card(items)

        XCTAssertFalse(card.whole.isEmpty, "前提：这必须是一张按整票画的复式票")
        XCTAssertEqual(card.count, 7)
        XCTAssertEqual(card.wonCount, 2)
        XCTAssertEqual(card.prize, 15)
        XCTAssertEqual(card.pendingPrizeCount, 0)
        // 票尾那个净收支单独看是说不清的：7 注共 14 元，中了 15 元，
        // 净收支 +1 —— 谁也猜不到那是「中 2 注、奖金 15」。
        XCTAssertEqual(card.netProfit, 1)
    }

    /// 一注都没中的复式票要说「均未中奖」，不能什么都不说。
    func testSystemTicketWithNoWinners() throws {
        let items = records(game: .ssq,
                            selections: [.red: SectionSelection(selected: [1, 2, 3, 4, 5, 6, 7]),
                                         .blue: SectionSelection(selected: [8])],
                            mode: .system,
                            prizes: Array(repeating: 0, count: 7),
                            statuses: Array(repeating: .lost, count: 7))
        let card = try card(items)

        XCTAssertFalse(card.whole.isEmpty)
        XCTAssertEqual(card.wonCount, 0)
        XCTAssertEqual(card.pendingPrizeCount, 0)
        XCTAssertTrue(card.status.hasResult)
    }

    // MARK: - 胆拖

    /// **胆拖和复式走的是同一条路。**
    ///
    /// 两者的区别只在 `WholeZone.dan` 空不空，中奖注数和奖金完全同一套算法。
    /// 这条用例存在的意义是把这件事钉死：将来谁把小结挪进「复式」那一支，
    /// 胆拖票就会悄悄退回「只有一个净收支」的老样子。
    func testDantuoTicketCountsWinningLines() throws {
        let items = records(game: .ssq,
                            // 2 胆 + 5 拖，红球从拖码里再选 4 个 → C(5,4) = 5 注
                            selections: [.red: SectionSelection(selected: [1, 2, 3, 4, 5, 6, 7], dan: [1, 2]),
                                         .blue: SectionSelection(selected: [8])],
                            mode: .dantuo,
                            prizes: [0, 0, 20, 0, 0],
                            statuses: [.lost, .lost, .won, .lost, .lost])
        let card = try card(items)

        XCTAssertFalse(card.whole.isEmpty, "前提：这必须是一张按整票画的胆拖票")
        // 胆码认出来了才算真的走在胆拖这条路上
        let red = try XCTUnwrap(card.whole.first { $0.key == .red })
        XCTAssertEqual(red.dan, [1, 2])
        XCTAssertEqual(card.count, 5)
        XCTAssertEqual(card.wonCount, 1)
        XCTAssertEqual(card.prize, 20)
    }

    /// 大乐透胆拖，前区 2 胆 3 拖、后区复式。换个彩种、换个号码区形状，
    /// 同一套算法仍然要对。
    func testDLTDantuoAcrossTwoZones() throws {
        let items = records(game: .dlt,
                            selections: [.front: SectionSelection(selected: [1, 2, 3, 4, 5, 6], dan: [1, 2]),
                                         .back: SectionSelection(selected: [7, 8, 9])],
                            mode: .dantuo,
                            // C(4,3) = 4 前区组合 × C(3,2) = 3 后区组合 = 12 注
                            prizes: [0, 0, 9, 0, 0, 0, 9, 0, 0, 0, 0, 0],
                            statuses: [.lost, .lost, .won, .lost, .lost, .lost,
                                       .won, .lost, .lost, .lost, .lost, .lost])
        let card = try card(items)

        XCTAssertFalse(card.whole.isEmpty)
        XCTAssertEqual(card.count, 12)
        XCTAssertEqual(card.wonCount, 2)
        XCTAssertEqual(card.prize, 18)
    }

    // MARK: - 奖金待公布

    /// 中了但奖金还没公布的注**不能混进奖金里**。
    ///
    /// 一等奖要等官方开奖公告，那几注 `prizeAmount` 还是 0、状态是
    /// `prizeFloat`。混进 `wonCount` 会写出「中 3 注 · 奖金 ¥10」这种
    /// 自相矛盾的话；不算中奖又会显示成「均未中奖」，那更错。
    func testPendingPrizeLinesCountedSeparately() throws {
        let items = records(game: .ssq,
                            selections: [.red: SectionSelection(selected: [1, 2, 3, 4, 5, 6, 7]),
                                         .blue: SectionSelection(selected: [8])],
                            mode: .system,
                            prizes: [0, 10, 0, 0, 0, 0, 0],
                            statuses: [.lost, .won, .prizeFloat, .lost, .lost, .lost, .lost])
        let card = try card(items)

        XCTAssertEqual(card.wonCount, 1, "待公布的那注不算进已知奖金的注数")
        XCTAssertEqual(card.pendingPrizeCount, 1)
        XCTAssertEqual(card.prize, 10)
        // 界面上显示的「中 N 注」是这两者之和
        XCTAssertEqual(card.wonCount + card.pendingPrizeCount, 2)
    }

    // MARK: - 只数前几注是错的

    /// 中奖注数必须按**全部记录**数，不能从 `lines` 里数。
    ///
    /// `lines` 只快照前 `lineLimit` 注。一张展开很多注的票，中奖的那注
    /// 十有八九落在快照之外 —— 从 `lines` 数出来的是「前 50 注里中了几注」，
    /// 对一张 200 注的票来说基本恒等于 0。
    func testWinningCountUsesAllRecordsNotTheSnapshot() throws {
        // 双色球红球 10 个复式 → C(10,6) = 210 注，远超 lineLimit
        let selections: [SectionKey: SectionSelection] = [
            .red: SectionSelection(selected: Array(1...10)),
            .blue: SectionSelection(selected: [11])
        ]
        var prizes = Array(repeating: 0.0, count: 210)
        var statuses = Array(repeating: RecordStatus.lost, count: 210)
        // 中奖的那注**故意放在快照之外**
        prizes[200] = 50
        statuses[200] = .won

        let items = records(game: .ssq, selections: selections, mode: .system,
                            prizes: prizes, statuses: statuses)
        let card = try card(items)

        XCTAssertEqual(card.count, 210)
        XCTAssertGreaterThan(card.count, card.lines.count, "前提：快照确实没装下全部注")
        XCTAssertEqual(card.lines.filter { $0.prizeAmount > 0 }.count, 0,
                       "前提：中奖那注不在快照里 —— 从 lines 数会得到 0")
        XCTAssertEqual(card.wonCount, 1)
        XCTAssertEqual(card.prize, 50)
    }
}
