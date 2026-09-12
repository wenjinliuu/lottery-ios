import XCTest
@testable import LotteryWallet

/// 号码行的「二次识别」要不要采纳。
///
/// 上一版这道闸是 `数字更多就换`，方向正好是反的 —— 裁条时扫进来的机号、
/// 金额、邻行残字天生数字更多，于是垃圾永远赢，快乐8/七乐彩/七星彩/排列5
/// 四个彩种一注都读不出来。下面这些串全部来自真机识别结果。
final class SecondPassGateTests: XCTestCase {

    // MARK: - 垃圾一律不许赢

    /// 快乐8：右边那一竖排机号被裁进来，拼在号码后面。
    func testRejectsMachineNumberBleed() {
        let original = "A.05 16 24 33 45 52 66 80"
        let garbage = "05 16 24 33 45 52 66 80 ( 1 R 1. 07 Z0 CO 70"
        XCTAssertFalse(TicketVisionScanner.isImprovement(garbage, over: original, game: .k8))
    }

    /// 七乐彩：同一条裁带里混进了上下两行。
    func testRejectsNeighbourRowBleed() {
        let original = "A.09 12 16 18 19 23 30"
        let garbage = "09 12 16 18 19 23 17 10 10 27 00)"
        XCTAssertFalse(TicketVisionScanner.isImprovement(garbage, over: original, game: .qlc))
    }

    /// 七星彩：裁带扫到了票号那一长串。
    func testRejectsSerialNumberBleed() {
        let original = "① 3 9 5 4 7 7 13"
        let garbage = "717 110310 251461 3 9 5 4 7 7 13"
        XCTAssertFalse(TicketVisionScanner.isImprovement(garbage, over: original, game: .qxc))
    }

    /// 候选**干净**但把一注本来读得出的号码改坏了，同样不许换。
    ///
    /// `3 9 5 4 7 7 13` 是合法的一注七星彩；多认出一位就不是了。
    /// 这条闸是「只补漏、不改坏」的那一半。
    func testRejectsCleanButUnparsableCandidate() {
        XCTAssertTrue(TicketTextParser.singleLineForTesting("3 9 5 4 7 7 13", game: .qxc) != nil)
        XCTAssertFalse(TicketVisionScanner.isImprovement("3 9 5 4 7 7 13 8",
                                                        over: "3 9 5 4 7 7 13", game: .qxc))
    }

    // MARK: - 该补的漏还得补上

    /// 福彩 3D 的玩法标签把号码挤没了：`组六: U 7` 只剩一位数字。
    /// 这正是二次识别存在的理由，必须放行。
    func testAcceptsRecoveredDigits() {
        XCTAssertTrue(TicketVisionScanner.isImprovement("1 8 9", over: "组六: U 7", game: .fc3d))
    }

    /// 排列5 丢了两位：`8 4 1` 补回 `8 4 4 1 5`。
    func testAcceptsRecoveredDigitsForPL5() {
        XCTAssertTrue(TicketVisionScanner.isImprovement("8 4 4 1 5", over: "① 8 4 1", game: .pl5))
    }

    /// 原行里混进了右边那一竖排机号 —— 裁条把机号挡在外面之后，
    /// 数字**变少**了，但这一行第一次读得成一注了。按数字个数比会把它否掉，
    /// 所以判据必须是「读不读得成」。
    func testAcceptsFewerDigitsWhenLineFinallyParses() {
        let original = "A.05 16 24 33 45 52 66 80 32030192"
        XCTAssertNil(TicketTextParser.singleLineForTesting(original, game: .k8))
        XCTAssertTrue(TicketVisionScanner.isImprovement("05 16 24 33 45 52 66 80",
                                                       over: original, game: .k8))
    }

    /// 认不出彩种时只剩「干净 + 更多数字」两道闸，仍然要挡住带符号的垃圾。
    func testUnknownGameStillRejectsDirtyText() {
        XCTAssertFalse(TicketVisionScanner.isImprovement("05 16 (1 R", over: "05 16", game: nil))
        XCTAssertTrue(TicketVisionScanner.isImprovement("05 16 24", over: "05 16", game: nil))
    }

    // MARK: - 裁条的横向边界

    /// 号码印在左边，机号印在右边，中间隔着很宽一条空白。
    /// 裁条的右边界要停在号码那一簇的末尾 —— 上一版裁的是整幅宽度，
    /// 机号于是行行都被扫进来。
    func testColumnsStopBeforeMachineNumberGap() {
        let row = [
            fragment(x: 0.06, width: 0.05),   // A.
            fragment(x: 0.13, width: 0.42),   // 一排号码
            fragment(x: 0.82, width: 0.14)    // 右边那一竖排机号
        ]
        let columns = LayoutSegmenter.columns(row)
        XCTAssertEqual(columns.lowerBound, 0.06, accuracy: 0.001)
        XCTAssertEqual(columns.upperBound, 0.55, accuracy: 0.001)
    }

    /// 号码之间的正常间距远小于那条分界缝，不能被误切。
    func testColumnsKeepNormallySpacedNumbers() {
        let row = (0..<6).map { fragment(x: 0.1 + CGFloat($0) * 0.09, width: 0.06) }
        let columns = LayoutSegmenter.columns(row)
        XCTAssertEqual(columns.upperBound, 0.61, accuracy: 0.001)
    }

    private func fragment(x: CGFloat, width: CGFloat) -> TicketVisionScanner.TextFragment {
        TicketVisionScanner.TextFragment(text: "0",
                                         box: CGRect(x: x, y: 0.5, width: width, height: 0.03))
    }
}

/// 玩法标签在「扫描复核页」和「票夹卡片」上必须是同一句话。
///
/// 之前复核页只写 `单式`，票夹写 `组选单式` —— 同一张票两个名字，
/// 用户没法确认自己扫对了没有。
final class PlayLabelParityTests: XCTestCase {

    private func record(_ game: GameKey, _ playMode: String) -> TicketRecord {
        TicketRecord(id: UUID().uuidString,
                     batchId: "b",
                     game: game,
                     ticket: Ticket(numbers: NumberSet([.nums3: [1, 2, 3]]),
                                    playMode: playMode, entryLabel: "单式"),
                     entryKind: .manual,
                     target: DrawTarget(),
                     price: 2,
                     multiple: 1,
                     source: "test")
    }

    /// 排列3 的组选票：票头写「组选单式」，组三/组六 是按号码推出来的，
    /// 票面并没有印，所以逐注不标。
    func testPL3GroupTicketLabelsHeadOnly() {
        XCTAssertEqual(GameKey.pl3.ticketLabel(modes: ["group6"], shape: "单式"), "组选单式")
        XCTAssertFalse(TicketCard.showsLineModes([record(.pl3, "group6"), record(.pl3, "group6")],
                                                 game: .pl3))
    }

    /// 排列3 直选票。
    func testPL3StraightTicketLabel() {
        XCTAssertEqual(GameKey.pl3.ticketLabel(modes: ["single"], shape: "单式"), "直选单式")
    }

    /// 一张票上混了组三和组六，逐注就得标出来 —— 两者奖级不同。
    func testMixedModesLabelEveryLine() {
        XCTAssertTrue(TicketCard.showsLineModes([record(.pl3, "group6"), record(.pl3, "group3")],
                                                game: .pl3))
    }

    /// 福彩 3D 的实体票**逐注印玩法**，所以永远标；票头反而不重复写。
    func testFC3DAlwaysLabelsEveryLine() {
        XCTAssertEqual(GameKey.fc3d.ticketLabel(modes: ["group6"], shape: "单式"), "单式")
        XCTAssertTrue(TicketCard.showsLineModes([record(.fc3d, "group6"), record(.fc3d, "group6")],
                                                game: .fc3d))
        XCTAssertEqual(GameKey.fc3d.playLabel(playMode: "single", addOn: false), "单选")
        XCTAssertEqual(GameKey.pl3.playLabel(playMode: "single", addOn: false), "直选")
    }

    /// 快乐8 的「选几」和大乐透的「追加」同样要出现在票头。
    func testHeadLabelsForK8AndDLT() {
        XCTAssertEqual(GameKey.k8.ticketLabel(modes: ["8"], shape: "单式"), "选八单式")
        XCTAssertEqual(GameKey.dlt.ticketLabel(modes: ["add"], shape: "复式"), "追加复式")
        XCTAssertEqual(GameKey.dlt.ticketLabel(modes: ["normal"], shape: "复式"), "复式")
    }

    /// 没有玩法可言的彩种，票头就只写票型，别凭空多出两个字。
    func testPlainGamesKeepShapeOnly() {
        XCTAssertEqual(GameKey.qxc.ticketLabel(modes: [""], shape: "单式"), "单式")
        XCTAssertEqual(GameKey.qlc.ticketLabel(modes: [""], shape: "单式"), "单式")
        XCTAssertEqual(GameKey.ssq.ticketLabel(modes: [""], shape: "胆拖"), "胆拖")
    }
}
