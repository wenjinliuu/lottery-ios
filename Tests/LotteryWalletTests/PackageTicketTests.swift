import XCTest
import SwiftData
@testable import LotteryWallet

/// 大乐透套餐票：一张票上印着几注单式，下面再加一块复式选号。
///
/// 规矩是**票面是什么类型就存什么类型，不拆**：它是一张票、票头写「套餐票」，
/// 不能变成一张单式加一张复式，更不能把其中一半号码丢掉。
@MainActor
final class PackageTicketTests: XCTestCase {

    /// 真票 26116 期的票面文字（流水号是假的）。
    private let printed = """
    体彩 超级大乐透
    第 26116期 2026年10月12日开奖
    182312-000000-001321-000000 000000 Abcdef
    套餐票 1倍 合计18元
    ① 03 04 18 21 26 + 08 09
    ② 03 13 17 32 35 + 03 04
    ③ 07 12 14 17 22 + 01 06
    ④ 06 13 22 26 34 + 02 06
    ⑤ 01 04 24 32 34 + 07 10
    ⑥ 12 20 23 24 32 + 02 11
    前区 05 18 21 22 31
    后区 02 08 12
    * * *
    * * *
    大乐透套餐票
    随机选号 少点纠结 多点惊喜
    感谢您为公益事业贡献 6.48元
    """

    // MARK: - 识别

    func testParsesAsOneTicketWithBothHalves() throws {
        let result = TicketTextParser.parse(printed)
        XCTAssertEqual(result.tickets.count, 1, "套餐票被拆成了几张")
        let ticket = try XCTUnwrap(result.tickets.first)
        XCTAssertEqual(ticket.game, .dlt)
        XCTAssertTrue(ticket.isPackage)
        XCTAssertEqual(ticket.shapeLabel, "套餐票")
        XCTAssertEqual(ticket.issue, "26116")
        // 上半截：六注单式，一注都不能少
        XCTAssertEqual(ticket.lines.count, 6)
        XCTAssertEqual(ticket.lines.first?[.front], [3, 4, 18, 21, 26])
        XCTAssertEqual(ticket.lines.last?[.back], [2, 11])
        // 下半截：前区 5 个、后区 3 个的复式
        XCTAssertEqual(ticket.selections[.front]?.selected, [5, 18, 21, 22, 31])
        XCTAssertEqual(ticket.selections[.back]?.selected, [2, 8, 12])
    }

    /// 6 注单式 + 复式展开的 3 注 = 9 注 18 元，和票面合计对得上。
    func testCountsAndAmountMatchThePrintedTotal() throws {
        let ticket = try XCTUnwrap(TicketTextParser.parse(printed).tickets.first)
        XCTAssertEqual(ticket.packageSingleCount, 6)
        XCTAssertEqual(ticket.count, 9)
        XCTAssertEqual(ticket.totalCost, 18)
        XCTAssertEqual(ticket.totalAmount, 18)
        // 展开的顺序：单式在前，复式那一块在后 —— 入库时靠这个顺序分标签
        let expanded = ticket.expandedLines
        XCTAssertEqual(expanded[5][.front], [12, 20, 23, 24, 32])
        XCTAssertTrue(expanded[6...].allSatisfy { $0[.front] == [5, 18, 21, 22, 31] && $0[.back].count == 2 })
        XCTAssertEqual(Set(expanded[6...].map { $0[.back] }), [[2, 8], [2, 12], [8, 12]])
        XCTAssertTrue(TicketTextParser.validate(ticket).isEmpty, "金额对得上就不该有提示")
    }

    /// 普通的大乐透复式票、单式票不能被当成套餐票。
    func testOrdinaryTicketsAreNotPackages() throws {
        let system = """
        体彩 超级大乐透
        第 25032期 2025年03月26日开奖
        复式票 1倍 合计12元
        前区 01 04 19 21 24 35
        后区 06 11
        """
        let systemTicket = try XCTUnwrap(TicketTextParser.parse(system).tickets.first)
        XCTAssertFalse(systemTicket.isPackage)
        XCTAssertEqual(systemTicket.play, .system)
        XCTAssertEqual(systemTicket.shapeLabel, "复式票")

        let single = """
        体彩 超级大乐透
        第 26128期 2026年11月09日开奖
        单式票 1倍 合计4元
        ① 09 11 13 16 28 + 05 07
        ② 16 20 23 29 31 + 10 11
        """
        let singleTicket = try XCTUnwrap(TicketTextParser.parse(single).tickets.first)
        XCTAssertFalse(singleTicket.isPackage)
        XCTAssertEqual(singleTicket.packageSingleCount, 0)
        XCTAssertEqual(singleTicket.count, 2)
    }

    // MARK: - 票夹

    private func packageRecords() throws -> [TicketRecord] {
        let configuration = ModelConfiguration(schema: ModelStore.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ModelStore.schema, configurations: [configuration])
        let service = RecordService(context: container.mainContext, drawStore: DrawStore())
        let ticket = try XCTUnwrap(TicketTextParser.parse(printed).tickets.first)
        // 和扫描页导入时同一条规则：前几注标「套餐票」，复式展开的标「套餐票复式」
        let built = ticket.expandedLines.enumerated().map { index, numbers in
            Ticket(numbers: numbers, playMode: "normal",
                   entryLabel: index < ticket.packageSingleCount
                       ? TicketShape.packageLabel : TicketShape.packageSystemLabel)
        }
        try service.save(tickets: built, game: .dlt, entryKind: .scan, price: 2, multiple: 1,
                         target: DrawTarget(expect: "26116", openDate: "2026-10-12", status: .confirmed),
                         source: "ticket_scan")
        self.container = container
        return service.allRecords()
    }

    private var container: ModelContainer?

    /// 票夹里它是**一张票**，票头写「套餐票」，上面六注单式、下面一块复式。
    func testWalletShowsOneCardInThePrintedShape() throws {
        let records = try packageRecords()
        XCTAssertEqual(records.count, 9)
        let batches = TicketBatch.group(records)
        XCTAssertEqual(batches.count, 1, "套餐票在票夹里变成了几张票")
        let card = TicketCard(batch: try XCTUnwrap(batches.first))
        XCTAssertTrue(card.isPackage)
        XCTAssertEqual(card.playLabel, "套餐票")
        XCTAssertEqual(card.count, 9)
        XCTAssertEqual(card.cost, 18)
        // 逐注只列单式那六注
        XCTAssertEqual(card.lines.count, 6)
        XCTAssertEqual(card.lines.first?.numbers[.front], [3, 4, 18, 21, 26])
        // 复式那一块按整票画
        XCTAssertEqual(card.whole.first { $0.key == .front }?.selected, [5, 18, 21, 22, 31])
        XCTAssertEqual(card.whole.first { $0.key == .back }?.selected, [2, 8, 12])
        XCTAssertTrue(card.whole.allSatisfy { $0.dan.isEmpty })
    }

    /// 老票和普通票不受影响：没有「套餐」标签的记录照原来的方式画。
    func testLabelsOnlyMarkPackages() {
        XCTAssertTrue(TicketShape.isPackage(entryLabel: "套餐票"))
        XCTAssertTrue(TicketShape.isPackage(entryLabel: "套餐票复式"))
        XCTAssertTrue(TicketShape.isPackageSystem(entryLabel: "套餐票复式"))
        XCTAssertFalse(TicketShape.isPackageSystem(entryLabel: "套餐票"))
        for label in ["单式票", "复式票", "胆拖票", "扫描", "随机", ""] {
            XCTAssertFalse(TicketShape.isPackage(entryLabel: label))
            XCTAssertFalse(TicketShape.isPackageSystem(entryLabel: label))
        }
        // 套餐票单式那几注在票型上仍然按单式看
        XCTAssertEqual(TicketShape.from(entryLabel: "套餐票"), .single)
    }
}
