import XCTest
@testable import LotteryWallet

/// 奖级对照表的回归测试。
///
/// 这张表是**说明书**，判奖走的是 `PrizeRules`。两边分开是对的，但分开就会漂：
/// 谁改了判奖条件而忘了改表，用户看到的说明就和实际核对结果对不上，
/// 而这种错最难被发现 —— 不会崩、不会红，只是说明书在骗人。
/// 这里把两边钉在一起。
final class PrizeTableTests: XCTestCase {

    /// 球的总数必须和彩种真实的号码区一致。
    ///
    /// 手写表最容易错的就是这个：双色球红球写成 7 颗、大乐透后区写成 1 颗，
    /// 画出来一眼看不出问题，但整张表就是错的。
    func testBallTotalsMatchGameSections() {
        let expected: [GameKey: [Int]] = [
            .ssq: [6, 1],   // 红 6 蓝 1
            .dlt: [5, 2],   // 前区 5 后区 2
            .qlc: [7, 1],   // 基本号 7 特别号 1
            .qxc: [6, 1]    // 前区 6 位 末位 1
        ]
        for (game, totals) in expected {
            for group in PrizeTable.table(for: game).groups {
                for tier in group.tiers {
                    for condition in tier.conditions {
                        guard case let .balls(groups) = condition else { continue }
                        XCTAssertEqual(groups.map(\.total), totals,
                                       "\(game.label) 的「\(tier.name)」球数和号码区对不上")
                        for item in groups {
                            XCTAssertLessThanOrEqual(item.hit, item.total,
                                                     "\(game.label)「\(tier.name)」对中数超过了总数")
                        }
                    }
                }
            }
        }
    }

    /// 表里列的奖级，必须正好是 `PrizeRules` 判得出来的那几档。
    ///
    /// 少一档 = 用户中了却在表里找不到；多一档 = 表上写着一个永远中不了的奖。
    func testTierNamesMatchPrizeRules() {
        let expected: [GameKey: [String]] = [
            .ssq: ["一等奖", "二等奖", "三等奖", "四等奖", "五等奖", "六等奖", "福运奖"],
            .dlt: ["一等奖", "二等奖", "三等奖", "四等奖", "五等奖", "六等奖", "七等奖"],
            .qlc: ["一等奖", "二等奖", "三等奖", "四等奖", "五等奖", "六等奖", "七等奖"],
            .qxc: ["一等奖", "二等奖", "三等奖", "四等奖", "五等奖", "六等奖"],
            .fc3d: ["单选", "组选3", "组选6"],
            .pl3: ["直选", "组选3", "组选6"],
            .pl5: ["直选"]
        ]
        for (game, names) in expected {
            let listed = PrizeTable.table(for: game).groups.flatMap { $0.tiers.map(\.name) }
            XCTAssertEqual(listed, names, "\(game.label) 的奖级列表和判奖规则对不上")
        }
    }

    /// 双色球四等奖是「5 红」或「4 红 + 蓝」两种中法，两行都得在表里。
    ///
    /// 只列一行是上一版真实的样子（往期开奖那张卡只写一等奖），
    /// 用户按表一对，会以为自己没中。
    func testMultiWayTiersListEveryWay() {
        func ways(_ game: GameKey, _ tier: String) -> Int {
            PrizeTable.table(for: game).groups
                .flatMap(\.tiers).first { $0.name == tier }?.conditions.count ?? 0
        }
        XCTAssertEqual(ways(.ssq, "四等奖"), 2)
        XCTAssertEqual(ways(.ssq, "五等奖"), 2)
        XCTAssertEqual(ways(.ssq, "六等奖"), 3)
        XCTAssertEqual(ways(.dlt, "三等奖"), 2)
        XCTAssertEqual(ways(.dlt, "七等奖"), 4)
        XCTAssertEqual(ways(.qxc, "四等奖"), 2)
        XCTAssertEqual(ways(.qxc, "六等奖"), 3)
    }

    /// 每个彩种都要有内容和脚注，八个一个都不能漏。
    ///
    /// 快乐8 走 `k8Rows` 单独排版（十个玩法压成十行，不铺成十个分组），
    /// 所以它的 `groups` 是空的，单独判。
    func testEveryGameHasATable() {
        for game in GameKey.ordered {
            let table = PrizeTable.table(for: game)
            XCTAssertNotNil(table.note, "\(game.label) 缺少说明脚注")
            guard game != .k8 else { continue }
            XCTAssertFalse(table.groups.isEmpty, "\(game.label) 没有奖级表")
            XCTAssertFalse(table.groups.flatMap(\.tiers).isEmpty, "\(game.label) 的奖级表是空的")
        }
        XCTAssertFalse(PrizeTable.k8Rows.isEmpty, "快乐8 没有奖级表")
    }

    /// 快乐8 十个玩法都要在，且奖级名一律用中文数字。
    func testK8CoversEveryPlayMode() {
        let plays = PrizeTable.k8Rows.map(\.play)
        XCTAssertEqual(plays, ["选十", "选九", "选八", "选七", "选六", "选五", "选四", "选三", "选二", "选一"])

        // 选十到选七都设了「中零」这一档，这是快乐8 最容易被漏掉的规则
        for play in ["选十", "选九", "选八", "选七"] {
            let row = PrizeTable.k8Rows.first { $0.play == play }
            XCTAssertTrue(row?.hits.contains { $0.0 == "中零" } ?? false, "\(play) 少了「中零」那一档")
        }

        // 表里不能再出现阿拉伯数字的「中N」—— 那正是和后面注数打架的写法
        for row in PrizeTable.k8Rows {
            for hit in row.hits {
                XCTAssertFalse(hit.0.contains(where: \.isNumber),
                               "\(row.play) 的「\(hit.0)」应该用中文数字")
            }
        }
    }

    /// 开奖卡上的快乐8 奖级名要把数字换成中文，免得和后面的注数糊在一起。
    func testK8PrizeLabelUsesChineseDigits() {
        XCTAssertEqual(DrawPrizeLines.chineseHits(in: "选十中10"), "选十中十")
        XCTAssertEqual(DrawPrizeLines.chineseHits(in: "选10中10"), "选十中十")
        XCTAssertEqual(DrawPrizeLines.chineseHits(in: "选8中0"), "选八中零")
        XCTAssertEqual(DrawPrizeLines.chineseHits(in: "选七中5"), "选七中五")
        // 已经是中文的原样不动
        XCTAssertEqual(DrawPrizeLines.chineseHits(in: "选九中九"), "选九中九")
        // 超出 0...10 的数字不动（不该出现，但别把它改坏）
        XCTAssertEqual(DrawPrizeLines.chineseHits(in: "选十中12"), "选十中12")
    }
}
