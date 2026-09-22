import XCTest
@testable import LotteryWallet

/// 「这个号码区要选几个号」—— 全彩种、全玩法的逐项审查。
///
/// ## 这一组用例存在的理由
///
/// 这个问题以前有**两个答案**在跑：`section.count`（彩种默认）和
/// `GameKey.pickCount(for:playMode:)`（玩法决定）。八个彩种里只有快乐8
/// 两者不一样，另外七个碰巧相等。
///
/// 「碰巧相等」正是它难被发现的原因：扫描复核页改号写死了 `section.count`，
/// 在七个彩种上一路正常，直到有人扫了一张快乐8 选五的票 —— 界面让他去点
/// 20 个号，选够 5 个之后「完成」还是灰的，整张票改不动。
///
/// 所以这里不挑重点，**八个彩种一个不落地过一遍**。
final class PickCountTests: XCTestCase {

    // MARK: - 快乐8：唯一一个两者不等的彩种

    /// 选一到选十，选几就是几。
    func testK8PickCountFollowsPlayMode() {
        let section = try! XCTUnwrap(GameKey.k8.sections.first)
        XCTAssertEqual(section.count, 20, "前提：快乐8 的 section.count 是开奖开出的 20 个号")

        for choose in 1...10 {
            XCTAssertEqual(GameKey.k8.pickCount(for: section, playMode: String(choose)), choose,
                           "选\(choose) 应该只让用户选 \(choose) 个号")
        }
    }

    /// 快乐8 的每一种玩法都要能算出个数来 —— 玩法列表和 `pickCount`
    /// 必须是同一套键，对不上就会退回 20。
    func testEveryK8PlayModeResolves() {
        let section = try! XCTUnwrap(GameKey.k8.sections.first)
        XCTAssertFalse(GameKey.k8.playModes.isEmpty)
        for mode in GameKey.k8.playModes {
            let need = GameKey.k8.pickCount(for: section, playMode: mode.key)
            XCTAssertLessThanOrEqual(need, 10, "\(mode.label) 算出来是 \(need)，说明玩法键没被认出来")
            XCTAssertGreaterThanOrEqual(need, 1)
        }
    }

    /// 空玩法按**彩种默认**算，不能当成 0，也不能退回 20。
    ///
    /// 老记录和扫描结果里 `playMode` 都可能是空串。退回 20 的话，
    /// 一张快乐8 的票会要求选 20 个号，永远选不完。
    func testEmptyPlayModeFallsBackToDefault() {
        let section = try! XCTUnwrap(GameKey.k8.sections.first)
        XCTAssertEqual(GameKey.k8.defaultPlayMode, "10")
        XCTAssertEqual(GameKey.k8.pickCount(for: section, playMode: ""), 10)
    }

    /// 认不出来的玩法键退回 `section.count`，不能是 0 ——
    /// 0 会让「选够了没有」永远为真，一注空号码就存进去了。
    func testUnknownPlayModeIsNeverZero() {
        for game in GameKey.ordered {
            for section in game.sections {
                let need = game.pickCount(for: section, playMode: "不存在的玩法")
                XCTAssertGreaterThan(need, 0, "\(game.label) \(section.label) 算出 0 个")
            }
        }
    }

    // MARK: - 其余七个彩种：和 section.count 一致

    /// 除快乐8 外，每个彩种的每一种玩法都不改变选号个数。
    ///
    /// 这条同时钉住了反面：哪天有别的彩种也按玩法改个数，这里会挂，
    /// 提醒把它一起纳进来。
    func testOtherGamesPickCountEqualsSectionCount() {
        for game in GameKey.ordered where game != .k8 {
            let modes = game.playModes.map(\.key) + ["", game.defaultPlayMode, "add", "normal"]
            for section in game.sections {
                for mode in modes {
                    XCTAssertEqual(game.pickCount(for: section, playMode: mode), section.count,
                                   "\(game.label) 的 \(section.label) 在玩法「\(mode)」下变成了别的个数")
                }
            }
        }
    }

    /// 各彩种一注总共几个号，按票面常识对一遍。
    func testTotalPicksPerGame() {
        let expected: [GameKey: Int] = [
            .ssq: 7,    // 6 红 + 1 蓝
            .dlt: 7,    // 5 前 + 2 后
            .qlc: 7,    // 基本号 7（特别号是开奖开出来的，不用投注选）
            .qxc: 7,    // 前六位 + 末位
            .fc3d: 3,
            .pl3: 3,
            .pl5: 5,
            .k8: 10     // 默认选十
        ]
        for game in GameKey.ordered {
            let total = game.sections.reduce(0) { $0 + game.pickCount(for: $1, playMode: game.defaultPlayMode) }
            XCTAssertEqual(total, expected[game], "\(game.label) 一注要选 \(total) 个号")
        }
    }

    // MARK: - 扫描出来的票：按注解析玩法

    private func scanned(game: GameKey, playMode: String = "", lineModes: [String] = [],
                         addOn: Bool = false) -> ScannedTicket {
        var ticket = ScannedTicket(game: game)
        ticket.playMode = playMode
        ticket.lineModes = lineModes
        ticket.addOn = addOn
        return ticket
    }

    /// 整票印的玩法。快乐8 的「选几」是整票一个值。
    func testScannedTicketUsesTicketPlayMode() {
        let ticket = scanned(game: .k8, playMode: "5")
        let section = try! XCTUnwrap(GameKey.k8.sections.first)

        XCTAssertEqual(ticket.effectivePlayMode(), "5")
        XCTAssertEqual(ticket.pickCount(for: section), 5,
                       "这正是那个 bug：选五的票要让用户选 5 个号，不是 20 个")
    }

    /// **每一注可以有自己的玩法。** 3D 一张票上能混着组六和组三。
    func testScannedTicketPrefersPerLinePlayMode() {
        let ticket = scanned(game: .fc3d, playMode: "single", lineModes: ["group6", "group3"])

        XCTAssertEqual(ticket.effectivePlayMode(lineIndex: 0), "group6")
        XCTAssertEqual(ticket.effectivePlayMode(lineIndex: 1), "group3")
        // 没有那一注的记录时退回整票的
        XCTAssertEqual(ticket.effectivePlayMode(lineIndex: 5), "single")
        XCTAssertEqual(ticket.effectivePlayMode(), "single")
    }

    /// 某一注的玩法是空串时也要退回整票的，不能当成「没有玩法」。
    func testBlankLineModeFallsBackToTicket() {
        let ticket = scanned(game: .k8, playMode: "8", lineModes: ["", ""])
        XCTAssertEqual(ticket.effectivePlayMode(lineIndex: 0), "8")
        let section = try! XCTUnwrap(GameKey.k8.sections.first)
        XCTAssertEqual(ticket.pickCount(for: section, lineIndex: 0), 8)
    }

    /// 整票也没印玩法时退回彩种默认值。
    func testScannedTicketFallsBackToGameDefault() {
        let ticket = scanned(game: .k8)
        XCTAssertEqual(ticket.effectivePlayMode(), "10")
    }

    /// 大乐透是例外：它的玩法位存的是**追加与否**，而追加不改号码个数。
    ///
    /// 不特判的话 `playMode` 会是空串，`effectivePlayMode` 退回默认值
    /// `normal`，追加那张票的玩法就丢了 —— 单注价格从 3 元变回 2 元。
    func testDLTPlayModeIsAddOn() {
        XCTAssertEqual(scanned(game: .dlt, addOn: true).effectivePlayMode(), "add")
        XCTAssertEqual(scanned(game: .dlt, addOn: false).effectivePlayMode(), "normal")

        // 追加与否都不改选几个号
        for section in GameKey.dlt.sections {
            XCTAssertEqual(scanned(game: .dlt, addOn: true).pickCount(for: section), section.count)
            XCTAssertEqual(scanned(game: .dlt, addOn: false).pickCount(for: section), section.count)
        }
    }

    /// 扫描票的选号个数和 `expandedLines` 用的是同一个玩法。
    ///
    /// 两边不一致的后果很隐蔽：界面让你按 A 玩法选号，展开却按 B 玩法算注数，
    /// 票面金额当场就对不上。
    func testScannedPickCountAgreesWithExpansion() {
        var ticket = scanned(game: .k8, playMode: "5")
        ticket.play = .system
        let section = try! XCTUnwrap(GameKey.k8.sections.first)
        let need = ticket.pickCount(for: section)
        XCTAssertEqual(need, 5)

        // 选 6 个号做复式：C(6,5) = 6 注
        ticket.selections[section.key] = SectionSelection(selected: [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(ticket.count, 6, "展开注数说明展开那一侧用的也是「选五」")
    }
}
