import XCTest
@testable import LotteryWallet

/// 新增彩种的票面解析。
///
/// 每一条用例都逐字抄自真实票面，并且**用票面印的合计金额交叉验证**注数 ——
/// 号码少读或多读一个，注数就对不上，这是最硬的一道校验。
final class TicketTextParserGamesTests: XCTestCase {

    // MARK: - 七乐彩

    /// 福彩七乐彩单式，3 注 × 2 元 = 6 元。
    /// 注意票头写的是「中国福利彩票」—— 彩种识别必须先认「七乐彩」，
    /// 否则会被当成双色球。
    func testQiLeCaiSingle() {
        let text = """
        玩法: 七乐彩-单式   机号:31120285
        4FA7-AF13-37C3-E991-07A1/48022751/C8C14
        A.09 12 16 18 19 23 25(1)
        B.05 16 17 18 19 23 25(1)
        C.09 12 13 14 18 19 25(1)
        D.-- -- -- -- -- -- --(-)
        E.-- -- -- -- -- -- --(-)
        开奖期:2026018 26-02-11    合计6元
        销售期:2026018-2   26-02-11 16:57:04
        感谢您为公益慈善事业贡献2.16元
        """
        guard let ticket = TicketTextParser.parseTickets(text).first else {
            return XCTFail("没解析出票")
        }
        XCTAssertEqual(ticket.game, .qlc)
        XCTAssertEqual(ticket.count, 3)
        XCTAssertEqual(ticket.issue, "2026018")
        XCTAssertEqual(ticket.totalCost, 6, accuracy: 0.001)
        XCTAssertEqual(ticket.lines.first?[.nums7], [9, 12, 16, 18, 19, 23, 25])
    }

    // MARK: - 快乐8

    /// 快乐8 选八单式，2 注 × 2 元 = 4 元。
    /// 玩法「选八」必须读出来 —— 丢了它会按默认的选十去核对。
    func testKuaiLe8SelectEight() {
        let text = """
        玩法: 快乐8-选八单式   机号:31130622
        6BC7-3100-726A-B39D-5D49/50302206/C4F91
        A.05 16 24 33 45 52 66 80    (1)
        B.01 14 27 31 39 58 63 72    (1)
        C.-- -- -- -- -- -- -- --    (-)
        开奖期:2026081 26-04-01   合计4元
        销售期:2026081-4   26-04-01 10:03:29
        感谢您为公益慈善事业贡献1.20元
        """
        guard let ticket = TicketTextParser.parseTickets(text).first else {
            return XCTFail("没解析出票")
        }
        XCTAssertEqual(ticket.game, .k8)
        XCTAssertEqual(ticket.playMode, "8")
        XCTAssertEqual(ticket.count, 2)
        XCTAssertEqual(ticket.totalCost, 4, accuracy: 0.001)
        XCTAssertEqual(ticket.lines.first?[.nums], [5, 16, 24, 33, 45, 52, 66, 80])
    }

    // MARK: - 七星彩

    /// 体彩七星彩，5 注 × 2 元 = 10 元。
    /// 前六位各 0-9、第七位 0-14，**可以重复也没有顺序** ——
    /// 双色球那套「升序不重复」的校验放到这里会把整张票判死。
    func testQiXingCai() {
        let text = """
        体彩 7星彩 Seven Stars
        第 26042期    2026年04月17日开奖
        110310-251461-120958-368897 772489 Tc5xcQ
        单式票   1倍   合计10元
        ① 3 9 5 4 7 7 13
        ② 2 9 7 3 4 0 4
        ③ 7 8 1 7 1 5 9
        ④ 6 8 7 4 6 0 10
        ⑤ 5 4 9 4 4 8 2
        感谢您为公益事业贡献 3.70元
        """
        guard let ticket = TicketTextParser.parseTickets(text).first else {
            return XCTFail("没解析出票")
        }
        XCTAssertEqual(ticket.game, .qxc)
        XCTAssertEqual(ticket.count, 5)
        XCTAssertEqual(ticket.totalCost, 10, accuracy: 0.001)
        XCTAssertEqual(ticket.lines.first?[.nums6], [3, 9, 5, 4, 7, 7])
        XCTAssertEqual(ticket.lines.first?[.tail], [13])
        // 第二注带 0，而且 4 出现了两次
        XCTAssertEqual(ticket.lines.dropFirst().first?[.nums6], [2, 9, 7, 3, 4, 0])
    }

    // MARK: - 排列5

    /// 体彩排列5，2 注 × 2 元 = 4 元。
    func testPaiLie5() {
        let text = """
        体彩 排列5
        第 26088期   2026年04月08日开奖
        110310-276961-120948-260804 322558 v78Bcw
        直选单式票   1倍   合计4元
        ① 8 4 4 1 5
        ② 1 5 5 2 2
        理性购买彩票，享受小小乐趣
        感谢您为公益事业贡献 1.48元
        """
        guard let ticket = TicketTextParser.parseTickets(text).first else {
            return XCTFail("没解析出票")
        }
        XCTAssertEqual(ticket.game, .pl5)
        XCTAssertEqual(ticket.count, 2)
        XCTAssertEqual(ticket.totalCost, 4, accuracy: 0.001)
        XCTAssertEqual(ticket.lines.first?[.nums5], [8, 4, 4, 1, 5])
        XCTAssertEqual(ticket.lines.dropFirst().first?[.nums5], [1, 5, 5, 2, 2])
    }

    // MARK: - 福彩 3D

    /// 一张 3D 票上可以混着好几种玩法，样票就是组六 ×2、组三 ×1、单选 ×2。
    /// 玩法决定奖级，所以要按玩法拆成三张，合计 10 元按注数分摊。
    func testFuCai3DSplitsByPlayMode() {
        let text = """
        玩法:3D-单式   机号:31130622
        7D92-04AE-1FB5-E411-B960/32798871/C084C
        组六: 1 8 9   (1)
        组六: 0 1 7   (1)
        组三: 0 9 9   (1)
        单选: 5 0 6   (1)
        单选: 8 9 1   (1)
        开奖期:2026091 26-04-11   合计10元
        销售期:2026091-34   26-04-11 18:07:02
        感谢您为公益慈善事业贡献3.40元
        """
        let tickets = TicketTextParser.parseTickets(text)
        XCTAssertEqual(tickets.count, 3)
        XCTAssertTrue(tickets.allSatisfy { $0.game == .fc3d })
        XCTAssertEqual(tickets.map(\.playMode), ["group6", "group3", "single"])
        XCTAssertEqual(tickets.map(\.count), [2, 1, 2])
        // 分摊之后每一张的合计都要和自己的注数对得上
        for ticket in tickets {
            XCTAssertEqual(ticket.totalCost, ticket.totalAmount ?? -1, accuracy: 0.001)
        }
        XCTAssertEqual(tickets.first?.lines.first?[.nums3], [1, 8, 9])
        // 带 0 的那一注不能丢
        XCTAssertEqual(tickets.first?.lines.dropFirst().first?[.nums3], [0, 1, 7])
    }

    // MARK: - 排列3

    /// 体彩排列3 直选单式，2 注 × 2 元 = 4 元。
    func testPaiLie3Direct() {
        let text = """
        体彩 排列3
        第 26088期    2026年04月08日开奖
        110310-276861-120948-245844 158739  UvDpAQ
        直选单式票    1倍    合计4元
        ① 9 5 0
        ② 3 9 2
        理性购买彩票，享受小小乐趣
        感谢您为公益事业贡献 1.36元
        """
        let tickets = TicketTextParser.parseTickets(text)
        XCTAssertEqual(tickets.count, 1)
        guard let ticket = tickets.first else { return }
        XCTAssertEqual(ticket.game, .pl3)
        XCTAssertEqual(ticket.playMode, "single")
        XCTAssertEqual(ticket.count, 2)
        XCTAssertEqual(ticket.totalCost, 4, accuracy: 0.001)
        XCTAssertEqual(ticket.lines.first?[.nums3], [9, 5, 0])
        XCTAssertEqual(ticket.lines.dropFirst().first?[.nums3], [3, 9, 2])
    }

    /// 体彩排列3 组选单式，3 注 × 2 元 = 6 元。
    ///
    /// **票面只印「组选」，不说是组三还是组六** —— 那是由号码本身决定的：
    /// `0 1 5`、`3 6 7` 三位都不同是组六，`0 4 4` 有一对相同是组三。
    /// 两者奖级不同，所以要拆成两张记录，6 元按注数分摊成 4 元 + 2 元。
    func testPaiLie3GroupPickSplitsByRepeatedDigits() {
        let text = """
        体彩 排列3
        第 26088期   2026年04月08日开奖
        110310-276961-120948-245833 054049  4VCFpg
        组选单式票   1倍   合计6元
        ① 0 1 5
        ② 3 6 7
        ③ 0 4 4
        理性购买彩票，享受小小乐趣
        感谢您为公益事业贡献 2.04元
        """
        let tickets = TicketTextParser.parseTickets(text)
        XCTAssertEqual(tickets.count, 2)
        XCTAssertEqual(tickets.map(\.playMode), ["group6", "group3"])
        XCTAssertEqual(tickets.map(\.count), [2, 1])
        // accuracy 版的 XCTAssertEqual 不收可选值，先摊平再比
        XCTAssertEqual(tickets.map(\.totalCost), [4, 2])
        XCTAssertEqual(tickets.first?.lines.first?[.nums3], [0, 1, 5])
        XCTAssertEqual(tickets.dropFirst().first?.lines.first?[.nums3], [0, 4, 4])
    }

    // MARK: - 回归：这两个坑是上一版真踩出来的

    /// 「第 26088期 2026年04月08日开奖」按两位一组拆出来正好是 8、4、8，
    /// 三个都落在 0-9 里 —— 数字型彩种如果不要求"整行只有数字"，
    /// 每张排列3 都会平白多出一注。
    func testDateLineIsNotABet() {
        XCTAssertNil(TicketTextParser.singleLineForTesting("第 26088期    2026年04月08日开奖", game: .pl3))
        XCTAssertFalse(TicketTextParser.isBareNumberLine("第 26088期    2026年04月08日开奖"))
        // 票号那一行有字母和连字符，同样不能当号码
        XCTAssertFalse(TicketTextParser.isBareNumberLine("110310-276861-120948-245844 158739  UvDpAQ"))
        // 真正的一注要能过
        XCTAssertTrue(TicketTextParser.isBareNumberLine(" 9 5 0"))
        // 热敏票把 0 认成 O 是常事，这种容忍要留着
        XCTAssertTrue(TicketTextParser.isBareNumberLine("O5 16 24"))
    }

    /// 福彩四个彩种的期号都是 7 位，原来只有双色球走这条路。
    func testWelfareGamesAllUseSevenDigitIssue() {
        for game in [GameKey.ssq, .qlc, .k8, .fc3d] {
            XCTAssertEqual(TicketTextParser.extractIssue("开奖期:2026018 26-02-11", game: game),
                           "2026018", "\(game) 的期号没读出来")
        }
        // 体彩那边仍然是 5 位
        XCTAssertEqual(TicketTextParser.extractIssue("第 26042期  2026年04月17日开奖", game: .qxc), "26042")
    }

    // MARK: - 不能误伤原有彩种

    func testWelfareHeaderStillResolvesDoubleColourBall() {
        let text = """
        玩法: 双色球-单式   机号:31130622
        A.11 13 14 27 31 33-04 (3)
        开奖期:2026106 26-09-13   合计6元
        """
        XCTAssertEqual(TicketTextParser.detectGame(text), .ssq)
    }

    func testSportsHeaderStillResolvesDaLeTou() {
        XCTAssertEqual(TicketTextParser.detectGame("中国体育彩票 超级大乐透 前区 后区"), .dlt)
    }
}
