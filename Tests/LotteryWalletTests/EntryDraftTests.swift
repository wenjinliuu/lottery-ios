import XCTest
@testable import LotteryWallet

/// 「修改一张票」的还原逻辑。
///
/// 这块最容易错的是复式和胆拖：票夹里存的是**展开后的每一注**，
/// 而选号盘要的是**整票选号**。拿展开的注逐条塞回选号盘会得到一堆重复号；
/// 反过来漏掉胆码，胆拖票一改就变成复式票。两个方向都得钉住。
final class EntryDraftTests: XCTestCase {

    private func record(_ numbers: [SectionKey: [Int]],
                        entryLabel: String,
                        game: GameKey = .ssq,
                        playMode: String = "",
                        addOn: Bool = false,
                        index: Int) -> TicketRecord {
        var set = NumberSet()
        for (key, values) in numbers { set[key] = values }
        var ticket = Ticket(numbers: set, playMode: playMode, entryLabel: entryLabel)
        ticket.addOn = addOn
        return TicketRecord(
            id: "batch_test_\(String(format: "%03d", index))",
            batchId: "batch_test",
            game: game,
            ticket: ticket,
            entryKind: .manual,
            target: DrawTarget(expect: "2026100", openDate: "2026-09-20"),
            price: 2,
            multiple: 3,
            source: "manual",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// 单式票：几注就是几注，原样还原。
    func testSingleKeepsEveryLine() {
        let records = [
            record([.red: [1, 2, 3, 4, 5, 6], .blue: [7]], entryLabel: "单式票", index: 1),
            record([.red: [10, 11, 12, 13, 14, 15], .blue: [8]], entryLabel: "单式票", index: 2)
        ]
        let draft = EntryDraft(records: records)
        XCTAssertNotNil(draft)
        XCTAssertEqual(draft?.shape, .single)
        XCTAssertEqual(draft?.lines.count, 2)
        XCTAssertEqual(draft?.lines.first?[.red], [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(draft?.selections.isEmpty ?? false)
    }

    /// 复式票：还原成**整票选号**，不是展开后那一堆注。
    ///
    /// 7 红选 6 展开是 7 注，每注 6 个红球。还原出来必须是那 7 个红球，
    /// 而不是 7×6=42 个（或去重后仍带重复结构的东西）。
    func testSystemRestoresUnionNotExpandedLines() {
        let reds = [1, 2, 3, 4, 5, 6, 7]
        let lines = (0..<7).map { skip -> [Int] in reds.enumerated().filter { $0.offset != skip }.map(\.element) }
        let records = lines.enumerated().map { index, red in
            record([.red: red, .blue: [9]], entryLabel: "复式票", index: index + 1)
        }
        let draft = EntryDraft(records: records)
        XCTAssertEqual(draft?.shape, .system)
        XCTAssertEqual(draft?.selections[.red]?.selected, reds)
        XCTAssertEqual(draft?.selections[.blue]?.selected, [9])
        // 复式没有胆码
        XCTAssertTrue(draft?.selections[.red]?.dan.isEmpty ?? false)
        XCTAssertTrue(draft?.lines.isEmpty ?? false)
    }

    /// 胆拖票：胆码是**每一注都出现的那些号**，必须还原出来。
    ///
    /// 漏掉胆码的话，用户一打开修改页看到的就是一张复式票 —— 保存之后
    /// 这张胆拖票会被真的改成复式票，注数和金额全变。
    func testDantuoRestoresDanNumbers() {
        // 胆码 1、2 固定，拖码从 3/4/5/6/7 里选 4 个
        let dan = [1, 2]
        let tuo = [3, 4, 5, 6, 7]
        let combos = [[3, 4, 5, 6], [3, 4, 5, 7], [3, 4, 6, 7], [3, 5, 6, 7], [4, 5, 6, 7]]
        let records = combos.enumerated().map { index, combo in
            record([.red: (dan + combo).sorted(), .blue: [9]], entryLabel: "胆拖票", index: index + 1)
        }
        let draft = EntryDraft(records: records)
        XCTAssertEqual(draft?.shape, .dantuo)
        XCTAssertEqual(draft?.selections[.red]?.selected, (dan + tuo).sorted())
        XCTAssertEqual(draft?.selections[.red]?.dan, dan)
        // 蓝球整个区都是定选的，不该被当成胆码
        XCTAssertTrue(draft?.selections[.blue]?.dan.isEmpty ?? false)
    }

    /// 大乐透的「追加」存在 addOn 上，不在 playMode 上，还原时要翻译回来。
    func testDLTAddOnBecomesPlayMode() {
        let addOn = record([.front: [1, 2, 3, 4, 5], .back: [1, 2]],
                           entryLabel: "单式票", game: .dlt, addOn: true, index: 1)
        XCTAssertEqual(EntryDraft(records: [addOn])?.playMode, "add")

        let normal = record([.front: [1, 2, 3, 4, 5], .back: [1, 2]],
                            entryLabel: "单式票", game: .dlt, addOn: false, index: 1)
        XCTAssertEqual(EntryDraft(records: [normal])?.playMode, "normal")
    }

    /// batchId 和 createdAt 必须原样留住 —— 改一张票不该让它在票夹里跳位置。
    func testIdentityIsPreserved() {
        let records = [record([.red: [1, 2, 3, 4, 5, 6], .blue: [7]], entryLabel: "单式票", index: 1)]
        let draft = EntryDraft(records: records)
        XCTAssertEqual(draft?.batchId, "batch_test")
        XCTAssertEqual(draft?.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(draft?.multiple, 3)
        XCTAssertEqual(draft?.expect, "2026100")
    }

    func testEmptyRecordsYieldNil() {
        XCTAssertNil(EntryDraft(records: []))
    }
}
