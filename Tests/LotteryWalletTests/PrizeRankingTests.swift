import XCTest
import CoreGraphics
@testable import LotteryWallet

/// 首页开奖卡上那两行奖级。
///
/// 快乐8 的奖级表是按「选几」从大到小列的，不是按钱列的 —— 照抄行序会把
/// 「选十中10」以外的大奖埋掉，或者把一个 4 元的小奖摆在头一行。
final class PrizeRankingTests: XCTestCase {

    private func entry(_ name: String, count: Int, bonus: String) -> PrizeEntry {
        var e = PrizeEntry()
        e.prizeName = name
        e.winningCount = count
        e.singleBonus = bonus
        return e
    }

    /// 官方表里「选十中10」排在最前，但当期它没开出来；
    /// 真正值钱的是「选九中9」，它得排到第一行。
    func testKuaile8RanksByMoneyNotByTableOrder() {
        let list = [
            entry("选十中10", count: 0, bonus: "5000000"),
            entry("选十中9", count: 12, bonus: "8000"),
            entry("选九中9", count: 3, bonus: "300000"),
            entry("选八中8", count: 40, bonus: "20000")
        ]
        let top = PrizeRanking.topTwo(of: list, game: .k8)
        XCTAssertEqual(top.map(\.prizeName), ["选九中9", "选八中8"])
    }

    /// 一档都没开出来就一行都不画，卡片下半截留白，不能拿 0 注的奖级凑数。
    func testKuaile8SkipsTiersNobodyWon() {
        let list = [
            entry("选十中10", count: 0, bonus: "5000000"),
            entry("选七中7", count: 0, bonus: "10000")
        ]
        XCTAssertTrue(PrizeRanking.topTwo(of: list, game: .k8).isEmpty)
    }

    /// 金额打平时按官方表的原序，翻来翻去顺序不能变。
    func testKuaile8KeepsTableOrderOnTies() {
        let list = [
            entry("选三中3", count: 100, bonus: "19"),
            entry("选二中2", count: 200, bonus: "19"),
            entry("选一中1", count: 300, bonus: "4")
        ]
        let top = PrizeRanking.topTwo(of: list, game: .k8)
        XCTAssertEqual(top.map(\.prizeName), ["选三中3", "选二中2"])
    }

    /// 其余彩种的两行是固定的一、二等奖，不按金额排 ——
    /// 二等奖总奖池比一等奖高的期数是有的，但一等奖还是得在上面。
    func testOtherGamesKeepFirstAndSecondPrize() {
        let list = [
            entry("一等奖", count: 1, bonus: "10000000"),
            entry("二等奖", count: 80, bonus: "200000"),
            entry("三等奖", count: 900, bonus: "3000")
        ]
        let top = PrizeRanking.topTwo(of: list, game: .ssq)
        XCTAssertEqual(top.map(\.prizeName), ["一等奖", "二等奖"])
    }

    /// 一等奖空开（0 注、0 元）时这一行不画，二等奖顶上来 ——
    /// 但它还是二等奖，图标不能挂奖杯。
    func testOtherGamesDropAnEmptyFirstPrize() {
        let list = [
            entry("一等奖", count: 0, bonus: "0"),
            entry("二等奖", count: 80, bonus: "200000")
        ]
        let top = PrizeRanking.topTwo(of: list, game: .ssq)
        XCTAssertEqual(top.map(\.prizeName), ["二等奖"])
    }

    /// 八张卡片一个高度：快乐8 加了一行奖级之后，这个值得跟着长，
    /// 而且仍然是所有彩种共用的同一个数。
    func testUnifiedHeightLeavesRoomForTwoPrizeRows() {
        let width: CGFloat = 393
        let inner = DrawCardMetrics.innerWidth(screenWidth: width)
        let chrome = DrawCardMetrics.headerHeight
            + DrawCardMetrics.verticalPadding * 2
            + DrawCardMetrics.blockSpacing * 2
        let k8Ball = DrawCardMetrics.ballSize(perRow: DrawCardMetrics.k8PerRow,
                                              sections: 1,
                                              spansAllSections: false,
                                              width: inner)
        let k8 = chrome + (2 * k8Ball + k8Ball * DrawCardMetrics.lineGap)
            + DrawCardMetrics.prizeRowHeight * 2
        XCTAssertGreaterThanOrEqual(DrawCardMetrics.unifiedHeight(screenWidth: width), k8)
    }
}
