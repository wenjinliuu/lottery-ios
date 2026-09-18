import Foundation

/// 各彩种的奖级对照表。**纯静态参考资料，不参与任何核对计算。**
///
/// 真正判奖走的是 `PrizeRules`，奖金金额一律读官方每期公布的 `prizeList`
/// （见 `PrizeRules.resolveFloatingAmount`）。这里这份表只是给用户看的说明书，
/// 两者刻意不互相引用 —— 表抄错了最多是说明写错，不会把谁的票核错。
///
/// 数据来自中国体彩网 / 中国福彩网公布的游戏规则与奖级对照表。
/// 固定奖金额官方会调整（七星彩三等奖就从 1800 元调到过 3000 元），
/// 所以页面上必须写明「以官方公布为准」。
enum PrizeTable {

    /// 一条中奖条件。球用来表达「对上几个」，文字用来表达数字型玩法那种规则。
    enum Condition: Hashable {
        case balls([BallGroup])
        case text(String)
    }

    /// 一组球：`hit` 颗实心（对上的），其余画成中性灰。
    struct BallGroup: Hashable {
        let color: BallColor
        let hit: Int
        let total: Int
    }

    /// 一个奖级。
    struct Tier: Hashable, Identifiable {
        let name: String
        /// 多行 = 多种中奖方式，满足任意一行即可。
        let conditions: [Condition]
        let amount: String
        /// 补充说明，比如大乐透随奖池变动的那一档。
        var note: String? = nil

        var id: String { name + amount }
    }

    /// 一组奖级。快乐8 每个「选几」是一组，其余彩种只有一组。
    struct Group: Hashable, Identifiable {
        var title: String? = nil
        let tiers: [Tier]

        var id: String { (title ?? "") + (tiers.first?.id ?? "") }
    }

    struct Table {
        let groups: [Group]
        /// 整张表的脚注，比如七星彩那条「任意位置，不要求连续」。
        var note: String? = nil
    }

    // MARK: - 取表

    static func table(for game: GameKey) -> Table {
        switch game {
        case .ssq: ssq
        case .dlt: dlt
        case .qlc: qlc
        case .qxc: qxc
        case .fc3d: fc3d
        case .pl3: pl3
        case .pl5: pl5
        case .k8: k8
        }
    }

    // MARK: - 球色
    //
    // 一律跟着 `GameKey.sections` 里的配色走，和录入页、票夹、开奖卡是同一套。

    private static func red(_ hit: Int) -> BallGroup { BallGroup(color: .red, hit: hit, total: 6) }
    private static func blue(_ hit: Int) -> BallGroup { BallGroup(color: .blue, hit: hit, total: 1) }
    private static func front(_ hit: Int) -> BallGroup { BallGroup(color: .blue, hit: hit, total: 5) }
    private static func back(_ hit: Int) -> BallGroup { BallGroup(color: .yellow, hit: hit, total: 2) }
    private static func basic(_ hit: Int) -> BallGroup { BallGroup(color: .yellow, hit: hit, total: 7) }
    private static func special(_ hit: Int) -> BallGroup { BallGroup(color: .k8orange, hit: hit, total: 1) }
    private static func qxcFront(_ hit: Int) -> BallGroup { BallGroup(color: .indigo, hit: hit, total: 6) }
    private static func qxcTail(_ hit: Int) -> BallGroup { BallGroup(color: .amber, hit: hit, total: 1) }

    // MARK: - 双色球

    private static let ssq = Table(groups: [Group(tiers: [
        Tier(name: "一等奖", conditions: [.balls([red(6), blue(1)])], amount: "浮动奖"),
        Tier(name: "二等奖", conditions: [.balls([red(6), blue(0)])], amount: "浮动奖"),
        Tier(name: "三等奖", conditions: [.balls([red(5), blue(1)])], amount: "3,000 元"),
        Tier(name: "四等奖", conditions: [.balls([red(5), blue(0)]), .balls([red(4), blue(1)])], amount: "200 元"),
        Tier(name: "五等奖", conditions: [.balls([red(4), blue(0)]), .balls([red(3), blue(1)])], amount: "10 元"),
        Tier(name: "六等奖",
             conditions: [.balls([red(2), blue(1)]), .balls([red(1), blue(1)]), .balls([red(0), blue(1)])],
             amount: "5 元"),
        Tier(name: "福运奖", conditions: [.balls([red(3), blue(0)])], amount: "5 元",
             note: "仅在官方执行特别规定期间设奖")
    ])], note: "一、二等奖为浮动奖，单注奖金由当期销量与中奖注数决定，开奖后由官方公布。")

    // MARK: - 大乐透

    private static let dlt = Table(groups: [Group(tiers: [
        Tier(name: "一等奖", conditions: [.balls([front(5), back(2)])], amount: "浮动奖",
             note: "基本投注最高 1000 万元，追加投注最高 1800 万元"),
        Tier(name: "二等奖", conditions: [.balls([front(5), back(1)])], amount: "浮动奖",
             note: "追加投注奖金比基本投注多 80%"),
        Tier(name: "三等奖", conditions: [.balls([front(5), back(0)]), .balls([front(4), back(2)])],
             amount: "5,000 元", note: "奖池 8 亿及以上时为 6,666 元"),
        Tier(name: "四等奖", conditions: [.balls([front(4), back(1)])],
             amount: "300 元", note: "奖池 8 亿及以上时为 380 元"),
        Tier(name: "五等奖", conditions: [.balls([front(4), back(0)]), .balls([front(3), back(2)])],
             amount: "150 元", note: "奖池 8 亿及以上时为 200 元"),
        Tier(name: "六等奖", conditions: [.balls([front(3), back(1)]), .balls([front(2), back(2)])],
             amount: "15 元", note: "奖池 8 亿及以上时为 18 元"),
        Tier(name: "七等奖",
             conditions: [.balls([front(3), back(0)]), .balls([front(2), back(1)]),
                          .balls([front(1), back(2)]), .balls([front(0), back(2)])],
             amount: "5 元", note: "奖池 8 亿及以上时为 7 元")
    ])], note: "三等奖及以下的固定奖金随奖池规模变动。本应用核对时读取的是官方当期公布的实际金额，不使用本表数值。")

    // MARK: - 七乐彩

    private static let qlc = Table(groups: [Group(tiers: [
        Tier(name: "一等奖", conditions: [.balls([basic(7), special(0)])], amount: "浮动奖"),
        Tier(name: "二等奖", conditions: [.balls([basic(6), special(1)])], amount: "浮动奖"),
        Tier(name: "三等奖", conditions: [.balls([basic(6), special(0)])], amount: "浮动奖"),
        Tier(name: "四等奖", conditions: [.balls([basic(5), special(1)])], amount: "200 元"),
        Tier(name: "五等奖", conditions: [.balls([basic(5), special(0)])], amount: "50 元"),
        Tier(name: "六等奖", conditions: [.balls([basic(4), special(1)])], amount: "10 元"),
        Tier(name: "七等奖", conditions: [.balls([basic(4), special(0)])], amount: "5 元")
    ])], note: "黄球为基本号码，橙球为特别号码。一至三等奖为浮动奖。")

    // MARK: - 七星彩

    private static let qxc = Table(groups: [Group(tiers: [
        Tier(name: "一等奖", conditions: [.balls([qxcFront(6), qxcTail(1)])], amount: "最高 500 万元"),
        Tier(name: "二等奖", conditions: [.balls([qxcFront(6), qxcTail(0)])], amount: "浮动奖"),
        Tier(name: "三等奖", conditions: [.balls([qxcFront(5), qxcTail(1)])], amount: "3,000 元"),
        Tier(name: "四等奖", conditions: [.balls([qxcFront(5), qxcTail(0)]), .balls([qxcFront(4), qxcTail(1)])],
             amount: "500 元"),
        Tier(name: "五等奖", conditions: [.balls([qxcFront(4), qxcTail(0)]), .balls([qxcFront(3), qxcTail(1)])],
             amount: "30 元"),
        Tier(name: "六等奖",
             conditions: [.balls([qxcFront(3), qxcTail(0)]), .balls([qxcFront(1), qxcTail(1)]),
                          .balls([qxcFront(0), qxcTail(1)])],
             amount: "5 元")
    ])], note: "前区 6 位按位比对：任意位置对上都计入，不要求连续。末位单独比对。")

    // MARK: - 数字型

    private static let fc3d = Table(groups: [Group(tiers: [
        Tier(name: "单选", conditions: [.text("三位号码与开奖号码按位完全相同")], amount: "1,040 元"),
        Tier(name: "组选3", conditions: [.text("号码与开奖号码相同、顺序不限，且其中两位号码相同")], amount: "346 元"),
        Tier(name: "组选6", conditions: [.text("号码与开奖号码相同、顺序不限，且三位号码各不相同")], amount: "173 元")
    ])], note: "福彩 3D 的实体票逐注印玩法，一张票上可以混着打。")

    private static let pl3 = Table(groups: [Group(tiers: [
        Tier(name: "直选", conditions: [.text("三位号码与开奖号码按位完全相同")], amount: "1,040 元"),
        Tier(name: "组选3", conditions: [.text("号码与开奖号码相同、顺序不限，且其中两位号码相同")], amount: "346 元"),
        Tier(name: "组选6", conditions: [.text("号码与开奖号码相同、顺序不限，且三位号码各不相同")], amount: "173 元")
    ])], note: "排列3 的组选票票面只印「组选」，具体是组三还是组六由号码本身决定。")

    private static let pl5 = Table(groups: [Group(tiers: [
        Tier(name: "直选", conditions: [.text("五位号码与开奖号码按位完全相同")], amount: "100,000 元")
    ])], note: "排列5 只设一个奖级，单注固定奖金 10 万元。")

    // MARK: - 快乐8

    private static func k8Group(_ title: String, _ pairs: [(String, String)]) -> Group {
        Group(title: title,
              tiers: pairs.map { Tier(name: $0.0, conditions: [], amount: $0.1) })
    }

    private static let k8 = Table(groups: [
        k8Group("选十", [("中 10", "最高 500 万元"), ("中 9", "8,000 元"), ("中 8", "720 元"),
                        ("中 7", "80 元"), ("中 6", "5 元"), ("中 5", "3 元"), ("中 0", "2 元")]),
        k8Group("选九", [("中 9", "最高 25 万元"), ("中 8", "2,000 元"), ("中 7", "225 元"),
                        ("中 6", "22 元"), ("中 5", "5 元"), ("中 4", "3 元"), ("中 0", "2 元")]),
        k8Group("选八", [("中 8", "50,000 元"), ("中 7", "800 元"), ("中 6", "80 元"),
                        ("中 5", "10 元"), ("中 4", "3 元"), ("中 0", "2 元")]),
        k8Group("选七", [("中 7", "8,500 元"), ("中 6", "300 元"), ("中 5", "30 元"),
                        ("中 4", "4 元"), ("中 0", "2 元")]),
        k8Group("选六", [("中 6", "2,880 元"), ("中 5", "30 元"), ("中 4", "10 元"), ("中 3", "3 元")]),
        k8Group("选五", [("中 5", "1,000 元"), ("中 4", "20 元"), ("中 3", "3 元")]),
        k8Group("选四", [("中 4", "93 元"), ("中 3", "5 元"), ("中 2", "3 元")]),
        k8Group("选三", [("中 3", "52 元"), ("中 2", "3 元")]),
        k8Group("选二", [("中 2", "19 元")]),
        k8Group("选一", [("中 1", "4.5 元")])
    ], note: "每期从 80 个号码中开出 20 个。选十、选九、选八、选七各有一档「中 0 个」也中奖。")
}
