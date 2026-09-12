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
    ///
    /// **不拆票** —— 用户手里就是一张彩票，票夹里也该是一张卡片，
    /// 玩法落到每一注上。曾经按玩法拆成三张，金额还要分摊，反而更难核对。
    func testFuCai3DKeepsOneTicketWithPerLineModes() {
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
        XCTAssertEqual(tickets.count, 1, "一张票就该是一张票")
        guard let ticket = tickets.first else { return }
        XCTAssertEqual(ticket.game, .fc3d)
        XCTAssertEqual(ticket.count, 5)
        XCTAssertEqual(ticket.totalCost, 10, accuracy: 0.001)
        XCTAssertEqual(ticket.lineModes,
                       ["group6", "group6", "group3", "single", "single"])
        XCTAssertEqual(ticket.lines.first?[.nums3], [1, 8, 9])
        // 带 0 的那一注不能丢
        XCTAssertEqual(ticket.lines.dropFirst().first?[.nums3], [0, 1, 7])
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
    /// 票面只印「组选」，不说是组三还是组六 —— 那由号码本身决定：
    /// `0 1 5`、`3 6 7` 三位都不同是组六，`0 4 4` 有一对相同是组三。
    /// 奖级不同，但**仍然是一张票**，所以只标到每一注上，不拆。
    func testPaiLie3GroupPickResolvesPerLine() {
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
        XCTAssertEqual(tickets.count, 1)
        guard let ticket = tickets.first else { return }
        XCTAssertEqual(ticket.count, 3)
        XCTAssertEqual(ticket.totalCost, 6, accuracy: 0.001)
        XCTAssertEqual(ticket.lineModes, ["group6", "group6", "group3"])
        XCTAssertEqual(ticket.lines.last?[.nums3], [0, 4, 4])
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

    /// OCR 经常只认出倍数括号的半边。真实识别结果里出现过
    /// `... 63 72 1 )`（丢了左括号）和 `... 23 25(1`（丢了右括号），
    /// 那个残缺的 `1` 会被当成一个号码，整注被判掉 —— 用户看到「少了一注」。
    func testBrokenMultipleParenthesisStillStripped() {
        let missingLeft = """
        玩法: 快乐8-选八单式
        A.05 16 24 33 45 52 66 80    (1)
        B.01 14 27 31 39 58 63 72 1 )
        开奖期:2026081 26-04-01   合计4元
        """
        XCTAssertEqual(TicketTextParser.parseTickets(missingLeft).first?.count, 2)

        let missingRight = """
        玩法: 七乐彩-单式
        A.09 12 16 18 19 23 25(1)
        B.05 16 17 18 19 23 25(1
        开奖期:2026018 26-02-11   合计4元
        """
        XCTAssertEqual(TicketTextParser.parseTickets(missingRight).first?.count, 2)
    }

    /// 但括号一个都没有时**不能动** —— 否则双色球每一注都要少一个蓝球。
    func testTrailingNumberWithoutParenthesisIsKept() {
        let text = """
        玩法: 双色球-单式
        A.11 13 14 27 31 33-04
        开奖期:2026106 26-09-13   合计2元
        """
        XCTAssertEqual(TicketTextParser.parseTickets(text).first?.lines.first?[.blue], [4])
    }

    // MARK: - 票面那句话

    /// 卡片头部要写得和实体票面一字不差。
    func testTicketHeadLabelMatchesPrintedWording() {
        // 排列3 票面只分直选/组选，组三组六是组选里按号码再分的
        XCTAssertEqual(GameKey.pl3.ticketLabel(modes: ["single"], shape: "单式"), "直选单式")
        XCTAssertEqual(GameKey.pl3.ticketLabel(modes: ["group6", "group3"], shape: "单式"), "组选单式")
        // 3D 逐注印玩法，票头只写「单式」
        XCTAssertEqual(GameKey.fc3d.ticketLabel(modes: ["group6", "single"], shape: "单式"), "单式")
        XCTAssertEqual(GameKey.k8.ticketLabel(modes: ["8"], shape: "单式"), "选八单式")
        XCTAssertEqual(GameKey.dlt.ticketLabel(modes: ["add"], shape: "单式"), "追加单式")
        XCTAssertEqual(GameKey.ssq.ticketLabel(modes: [""], shape: "复式"), "复式")
    }

    /// 同一个玩法两家印法不同：3D 叫「单选」，排列3 叫「直选」。
    func testSinglePickWordingDiffersByIssuer() {
        XCTAssertEqual(GameKey.fc3d.playLabel(playMode: "single", addOn: false), "单选")
        XCTAssertEqual(GameKey.pl3.playLabel(playMode: "single", addOn: false), "直选")
    }

    /// 号码行的判据是**结构**，不是数字占比。
    ///
    /// 按占比判两头都会错：期号行数字占 61% 会被当成号码行（于是被纵向相邻的
    /// 票号行覆盖掉，排列3 从此读不到期号），而 `组六: U 7` 数字只占 20%
    /// 会被跳过 —— 那恰恰是最需要二次识别的一行。
    func testNumberRowDetectionUsesStructure() {
        XCTAssertFalse(TicketVisionScanner.looksLikeNumberRow("第26088期 2026年04月08日开奖"))
        XCTAssertFalse(TicketVisionScanner.looksLikeNumberRow("开奖期:2026018 26-02-11 合计6元"))
        XCTAssertFalse(TicketVisionScanner.looksLikeNumberRow("单式票 1倍 合计10元"))
        XCTAssertTrue(TicketVisionScanner.looksLikeNumberRow("① 0 1 5"))
        XCTAssertTrue(TicketVisionScanner.looksLikeNumberRow("A.09 12 16 18 19 23 25"))
        XCTAssertTrue(TicketVisionScanner.looksLikeNumberRow("组六: U 7"))
    }

    /// Vision 偶尔把注序号的 A 认成西里尔字母 А，还可能认出两遍。
    /// 两者都会让整行过不了「只有数字」那道闸，一注就丢了。
    func testCyrillicAndDoubledLineLabelStillParse() {
        let cyrillicA = "\u{0410}"
        let text = """
        玩法: 快乐8-选八单式
        A. \(cyrillicA).05 16 24 33 45 52 66 80 ( 1 )
        B.01 14 27 31 39 58 63 72 1 )
        开奖期:2026081 26-04-01   合计4元
        """
        let ticket = TicketTextParser.parseTickets(text).first
        XCTAssertEqual(ticket?.count, 2, "西里尔 А 或重复的注序号不该丢注")
        XCTAssertEqual(ticket?.lines.first?[.nums], [5, 16, 24, 33, 45, 52, 66, 80])
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

/// 复式 / 胆拖票在票夹里要按**整票**显示，而不是把展开的每一注铺开。
///
/// 关键在于这些信息不需要给记录加字段 —— 它们本来就藏在注里：
/// 某个区所有注的**并集**就是这个区选的号，**交集**就是胆码
/// （胆码按定义出现在每一注里，拖码只出现在一部分注里）。
final class WholeTicketDerivationTests: XCTestCase {

    private func record(_ red: [Int], _ blue: [Int]) -> TicketRecord {
        TicketRecord(id: UUID().uuidString,
                     batchId: "b",
                     game: .ssq,
                     ticket: Ticket(numbers: NumberSet([.red: red, .blue: blue]),
                                    playMode: "", entryLabel: "复式"),
                     entryKind: .manual,
                     target: DrawTarget(),
                     price: 2,
                     multiple: 1,
                     source: "test")
    }

    /// 双色球 7 红复式：展开 7 注，整票应该还原成那 7 个红球。
    func testSystemTicketUnionsAllNumbers() {
        let reds = [1, 2, 3, 4, 5, 6, 7]
        let records = (0..<7).map { skip -> TicketRecord in
            record(reds.enumerated().filter { $0.offset != skip }.map(\.element), [8])
        }
        let zones = TicketCard.wholeZones(records, game: .ssq)
        let red = zones.first { $0.key == .red }
        XCTAssertEqual(red?.selected, reds)
        // 复式没有胆码：没有哪个红球出现在全部 7 注里
        XCTAssertEqual(red?.dan, [])
    }

    /// 胆拖：出现在每一注里的就是胆码。
    func testDantuoTicketFindsDanNumbers() {
        // 2 胆（1、2）+ 5 拖（3…7）里选 4 个 —— 展开正好 5 注，每注 6 个红球
        let tuo = [3, 4, 5, 6, 7]
        let records = tuo.map { dropped in
            record([1, 2] + tuo.filter { $0 != dropped }, [9])
        }
        XCTAssertEqual(records.count, 5)
        let red = TicketCard.wholeZones(records, game: .ssq).first { $0.key == .red }
        XCTAssertEqual(red?.selected, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(red?.dan, [1, 2])
    }

    /// 两注互不相干的单式**也会**让并集"多选"，但它不是复式票。
    ///
    /// 这一条是这套推导最关键的边界：光看「有没有某个区多选了」会把
    /// 手选的两注 1-6 和 7-12 画成一张 12 选 6 的复式。真正的判据是
    /// **注数要等于这组选号的展开数** —— 12 选 6 展开是 924 注，不是 2 注。
    func testPlainSingleLinesAreNotTreatedAsWholeTicket() {
        let records = [record([1, 2, 3, 4, 5, 6], [1]),
                       record([7, 8, 9, 10, 11, 12], [2])]
        XCTAssertTrue(TicketCard.wholeZones(records, game: .ssq).isEmpty)
    }

    /// 双色球 7 红 + 2 蓝的复式：展开 C(7,6) × C(2,1) = 14 注。
    /// 两个区一起参与组合数校验，漏掉蓝球那一维就会算错。
    func testSystemTicketAcrossTwoZones() {
        let reds = [1, 2, 3, 4, 5, 6, 7]
        var records: [TicketRecord] = []
        for skip in 0..<7 {
            for blue in [8, 9] {
                records.append(record(reds.enumerated().filter { $0.offset != skip }.map(\.element),
                                      [blue]))
            }
        }
        XCTAssertEqual(records.count, 14)
        let zones = TicketCard.wholeZones(records, game: .ssq)
        XCTAssertEqual(zones.first { $0.key == .red }?.selected, reds)
        XCTAssertEqual(zones.first { $0.key == .blue }?.selected, [8, 9])
    }
}
