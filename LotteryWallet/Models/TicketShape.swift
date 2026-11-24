import Foundation

/// 票面类型：用户手里那张实体彩票印的是单式票、复式票还是胆拖票。
///
/// 这是**票据本身的属性**，不是"用户打算怎么投注"。以前这件事在三个地方
/// 各写了一遍，而且写法还不一样：
///
/// - 录入页的 `EntryMode.label` 是「手选 / 复式 / 胆拖」
/// - 扫描页的 `ScanPlay.label` 是「单式 / 复式 / 胆拖」
/// - 票夹靠 `RecordService.shapeLabel` 把上面两套字符串**按全等**折回票面用词
///
/// 三套写法共用一个 `entryLabel` 字段落库，谁改一个字都会把票夹里的标签
/// 打回「单式」—— 这正是这次重构要消灭的耦合。现在三条路径都先落到
/// `TicketShape`，显示名只有这里一处。
enum TicketShape: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// 一行一注，票面印「单式」。
    case single
    /// 一个区多选几个号，展开成多注，票面印「复式」。
    case system
    /// 胆码必出 + 拖码组合，票面印「胆」「拖」两行。
    case dantuo

    var id: String { rawValue }

    /// 用户可见的名字。
    ///
    /// 带「票」字是刻意的：这一栏说的是**用户手里那张纸是什么票**，
    /// 不是"接下来要投哪一种"。
    var label: String {
        switch self {
        case .single: "单式票"
        case .system: "复式票"
        case .dantuo: "胆拖票"
        }
    }

    /// 从落库的 `entryLabel` 反推票面类型。
    ///
    /// 用**包含**判断而不是全等：历史记录里存过「随机」「普通」「手选」
    /// 「扫描」「单式」「复式」「胆拖」，新记录存的是「单式票」「复式票」
    /// 「胆拖票」。全等匹配过一次线上事故 —— 文案改一个字，所有复式票的
    /// 标签就变成「单式」。包含判断对新旧写法都成立，以后再改文案也不会再犯。
    // MARK: - 套餐票

    /// 大乐透的「套餐票」：一张票上印着几注单式，下面再加一块复式选号。
    ///
    /// 它**不是第四种枚举值**。单式那几注和复式那一块在记录里各存各的标签：
    /// 单式的几注是「套餐票」，复式展开出来的几注是「套餐票复式」。
    /// 整张票仍然是一个批次、一张电子票，票头写「套餐票」，
    /// 画的时候上面是那几注单式、下面是复式的整票选号，和纸质票一个样。
    ///
    /// 不加枚举值是因为它不是一种「选号方式」：录入页的单式 / 复式 / 胆拖
    /// 三个分支都不该多出一个套餐来，它只能从扫描进来。
    static let packageLabel = "套餐票"
    static let packageSystemLabel = "套餐票复式"

    /// 这条记录属于一张套餐票（不管是单式那几注还是复式那一块）。
    static func isPackage(entryLabel raw: String) -> Bool { raw.contains("套餐") }

    /// 这条记录是套餐票里复式那一块展开出来的。
    static func isPackageSystem(entryLabel raw: String) -> Bool {
        raw.contains("套餐") && raw.contains("复式")
    }

    static func from(entryLabel raw: String) -> TicketShape {
        if raw.contains("胆拖") { return .dantuo }
        if raw.contains("复式") { return .system }
        return .single
    }
}
