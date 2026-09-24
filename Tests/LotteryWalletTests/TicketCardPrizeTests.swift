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

    // MARK: - 快乐8：整票对账也要按玩法算

    /// **快乐8 的复式票在票夹里要画得成整票。**
    ///
    /// `wholeZones` 用「展开数 == 记录条数」对账，而展开数原来是按
    /// `section.count`（快乐8 是开奖的 20 个）算的：一张选五复式选了 7 个号，
    /// 算出来是 `binomial(7, 20) = 0`，和真实的 21 注对不上 —— 于是快乐8 的
    /// 复式和胆拖票**永远画不成整票**，连带「中 N 注 · 奖金」那行小结
    /// 也跟着消失，正是这张票最该显示的东西。
    func testK8SystemTicketFormsWholeView() throws {
        let selections: [SectionKey: SectionSelection] = [
            .nums: SectionSelection(selected: [1, 2, 3, 4, 5, 6, 7])
        ]
        let tickets = try XCTUnwrap(TicketBuilder.expand(game: .k8, selections: selections,
                                                         mode: .system, playMode: "5", addOn: false))
        XCTAssertEqual(tickets.count, 21, "前提：选五从 7 个号里展开是 C(7,5) = 21 注")

        let items = tickets.enumerated().map { index, ticket -> TicketRecord in
            let record = TicketRecord(id: String(format: "r%04d", index),
                                      batchId: "batch",
                                      game: .k8,
                                      ticket: ticket,
                                      entryKind: .system,
                                      target: DrawTarget(expect: "2026253", openDate: "2026-09-20"),
                                      price: 2,
                                      multiple: 1,
                                      source: "test")
            record.status = index == 3 ? .won : .lost
            record.prizeAmount = index == 3 ? 19 : 0
            return record
        }
        let card = try card(items)

        XCTAssertFalse(card.whole.isEmpty,
                       "按 section.count(20) 对账会得到 0 注，这张票就画不成整票了")
        let zone = try XCTUnwrap(card.whole.first { $0.key == .nums })
        XCTAssertEqual(zone.selected, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(card.count, 21)
        // 中奖明细只在整票视图里，所以上面那条不成立时这里也一起没了
        XCTAssertEqual(card.wonCount, 1)
        XCTAssertEqual(card.prize, 19)
    }

    // MARK: - 展不展得开

    /// **复式 / 胆拖一律要能展开，跟注数无关。**
    ///
    /// 这两种票收起时只画整票那两行号码，逐注号码只有展开才有。原来的判据
    /// 只看「注数 > 5」，于是双色球 6 红 2 蓝（2 注）、2 胆 5 拖（5 注）、
    /// 大乐透 1 胆 5 拖（5 注）这些常见票型**永远看不到自己那几注号码**，
    /// 点了也没反应 —— 常见胆拖有一半落在这个区间。
    ///
    /// 判据在视图里（`WalletTicketCard.isCollapsible`），这里钉的是它依赖的
    /// 那个事实：这些票的 `whole` 非空而 `count` 很小，两个条件同时成立。
    func testSmallSystemAndDantuoTicketsStillHaveWholeView() throws {
        // 双色球 6 红 + 2 蓝复式 → 2 注
        let small = try card(records(game: .ssq,
                                     selections: [.red: SectionSelection(selected: [1, 2, 3, 4, 5, 6]),
                                                  .blue: SectionSelection(selected: [7, 8])],
                                     mode: .system,
                                     prizes: [0, 0],
                                     statuses: [.lost, .lost]))
        XCTAssertEqual(small.count, 2)
        XCTAssertFalse(small.whole.isEmpty,
                       "2 注的复式仍然按整票画 —— 所以它必须能展开，否则逐注号码永远看不到")

        // 双色球 2 胆 5 拖 → 5 注，正好卡在旧判据的边界上
        let dantuo = try card(records(game: .ssq,
                                      selections: [.red: SectionSelection(selected: [1, 2, 3, 4, 5, 6, 7], dan: [1, 2]),
                                                   .blue: SectionSelection(selected: [8])],
                                      mode: .dantuo,
                                      prizes: Array(repeating: 0, count: 5),
                                      statuses: Array(repeating: .lost, count: 5)))
        XCTAssertEqual(dantuo.count, 5)
        XCTAssertFalse(dantuo.whole.isEmpty)
        XCTAssertLessThanOrEqual(dantuo.count, 5,
                                 "前提：注数没超过旧判据的阈值，否则这条用例测不到那个 bug")
    }

    /// 单式票不受影响：5 注以内本来就全展开，没有「藏起来的号码」。
    ///
    /// ## 号码必须**真的互不相干**
    ///
    /// 这条用例第一版写成了「红球只差最后一个号」的三注
    /// （1-2-3-4-5-6 / 1-2-3-4-5-7 / 1-2-3-4-5-8），结果挂了 ——
    /// 而且挂得对。那三注的并集是 8 个号、交集是 5 个号，按 5 胆 3 拖
    /// 展开正好是 C(3,1) = 3 注，和记录条数严丝合缝，所以 `wholeZones`
    /// 判定它是一张胆拖票。**它在数据上和真的胆拖票没有任何区别。**
    ///
    /// 这不是 bug，是 `combinations == records.count` 这条判据的固有代价：
    /// 手选出来的几注恰好构成一个合法展开时，两者无从分辨。核对仍然逐注进行，
    /// 只是画法变了。
    ///
    /// 所以这里的号码要选成**怎么凑都凑不出一个合法展开**的：三注红球完全
    /// 不重叠，并集 18 个号选 6 是 18564 种，和 3 差了四个数量级。
    func testSmallSingleTicketHasNoWholeView() throws {
        let reds = [[1, 2, 3, 4, 5, 6], [10, 11, 12, 13, 14, 15], [20, 21, 22, 23, 24, 25]]
        let blues = [7, 16, 26]
        let items = (0..<3).map { index -> TicketRecord in
            let ticket = Ticket(numbers: NumberSet([.red: reds[index], .blue: [blues[index]]]),
                                entryLabel: "单式")
            let record = TicketRecord(id: String(format: "r%04d", index),
                                      batchId: "batch",
                                      game: .ssq,
                                      ticket: ticket,
                                      entryKind: .manual,
                                      target: DrawTarget(expect: "2026109", openDate: "2026-09-20"),
                                      price: 2,
                                      multiple: 1,
                                      source: "test")
            record.status = .lost
            return record
        }
        let card = try card(items)
        XCTAssertTrue(card.whole.isEmpty, "三注互不相干的单式不该被当成复式或胆拖")
        XCTAssertEqual(card.count, 3)
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
