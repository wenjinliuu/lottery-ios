import XCTest
@testable import LotteryWallet

/// 票头那枚「单式 / 复式 / 胆拖」标签点得动之后，号码要跟着翻译过去。
///
/// 这两种票在模型里是两套号码：单式读 `lines`，复式/胆拖读 `selections`。
/// 改票种如果只改了 `play` 这个字段，那张票当场变成 0 注 ——
/// 用户点一下标签，五注号码全没了。
final class TicketShapeTests: XCTestCase {

    private func ssqSingle() -> ScannedTicket {
        var ticket = ScannedTicket(game: .ssq)
        ticket.lines = [NumberSet([.red: [3, 8, 11, 19, 26, 30], .blue: [12]]),
                        NumberSet([.red: [6, 8, 13, 21, 29, 32], .blue: [4]])]
        return ticket
    }

    /// 单式改复式：两注的号码并成一个池子，注数按组合数重算。
    func testSingleBecomesSystemByPoolingEveryLine() {
        var ticket = ssqSingle()
        XCTAssertEqual(ticket.count, 2)
        ticket.changeShape(to: .system)
        XCTAssertEqual(ticket.play, .system)
        // 红球并集：3 6 8 11 13 19 21 26 29 30 32（8 出现两次，只留一个）
        XCTAssertEqual(ticket.selections[.red]?.selected, [3, 6, 8, 11, 13, 19, 21, 26, 29, 30, 32])
        XCTAssertEqual(ticket.selections[.blue]?.selected, [4, 12])
        XCTAssertTrue(ticket.lines.isEmpty, "复式的号码不再从 lines 读")
        XCTAssertGreaterThan(ticket.count, 2, "复式展开的注数比原来两注多")
    }

    /// 复式改回单式：每个区刚好选满时收成一注，收不成就不给改。
    func testSystemCollapsesBackOnlyWhenItIsExactlyOneBet() {
        var exact = ScannedTicket(game: .ssq)
        exact.play = .system
        exact.selections = [.red: .init(selected: [3, 8, 11, 19, 26, 30]),
                            .blue: .init(selected: [12])]
        XCTAssertTrue(exact.availableShapes.contains(.single))
        exact.changeShape(to: .single)
        XCTAssertEqual(exact.lines.first?[.red], [3, 8, 11, 19, 26, 30])
        XCTAssertEqual(exact.count, 1)

        var wide = ScannedTicket(game: .ssq)
        wide.play = .system
        wide.selections = [.red: .init(selected: [3, 8, 11, 19, 26, 30, 31]),
                           .blue: .init(selected: [12])]
        XCTAssertFalse(wide.availableShapes.contains(.single), "七个红球拆不成一注单式")
        wide.changeShape(to: .single)
        XCTAssertEqual(wide.play, .system, "点不动就什么都别改")
    }

    /// **还有问号的时候不许改成复式。**
    ///
    /// 问号在 `selections` 里没有地方落脚，摊过去就等于把「这一位没认出来」
    /// 悄悄抹掉 —— 正是硬约束一要挡的那种"看起来对"。
    func testUnknownDigitsBlockTheSystemShape() {
        var ticket = ScannedTicket(game: .qxc)
        ticket.lines = [NumberSet([.nums6: [3, 9, 5, 4, 7, 7], .tail: [NumberSet.unknown]])]
        XCTAssertTrue(ticket.hasUnknown)
        XCTAssertEqual(ticket.availableShapes, [.single])
        ticket.changeShape(to: .system)
        XCTAssertEqual(ticket.play, .single)
    }

    /// 当前这一种永远在菜单里点得动，否则用户连自己是什么都确认不了。
    func testCurrentShapeIsAlwaysOffered() {
        var empty = ScannedTicket(game: .dlt)
        empty.play = .dantuo
        XCTAssertTrue(empty.availableShapes.contains(.dantuo))
    }

    /// 改成复式之后逐注玩法要清掉 —— 行都没了，它没有意义。
    func testLineModesGoAwayWithTheLines() {
        var ticket = ScannedTicket(game: .fc3d)
        ticket.lines = [NumberSet([.nums3: [1, 2, 3]]), NumberSet([.nums3: [4, 5, 6]])]
        ticket.lineModes = ["single", "group6"]
        ticket.changeShape(to: .system)
        XCTAssertTrue(ticket.lineModes.isEmpty)
    }
}
