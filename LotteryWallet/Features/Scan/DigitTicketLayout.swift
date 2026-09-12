import Foundation
import CoreGraphics

/// 号码矩阵的票面版式。
///
/// 里面**全是比值，没有一个像素数**。票在照片里占多大、用户裁得松还是紧、
/// 拍得远还是近，这些比值都不变 —— 这正是「裁切稍微不准就识别失败」的解药。
///
/// 数字是把真票逐像素量出来的（见 `Engineering/vision-rebuild.md` 第 3 节和第十四节）：
///
/// | | 列距 ÷ 字宽 | 分组 | 组间距 |
/// |---|---|---|---|
/// | 七星彩 | 3.62 | 6 + 1（特别号） | 1.58 列距 |
/// | 排列5 | 3.74 | 5 | — |
/// | 排列3 / 福彩3D | 3.43 / 2.65 | 3 | — |
/// | 大乐透 | 1.61 | 5 + 2（前区/后区） | 2.34 列距，中间印 `+` |
/// | 双色球 | 1.42 | 6 + 1（红/蓝） | 待实测 |
///
/// **分组是这张表的核心**。票面上的号码不是一路等距印到底的：
/// 七星彩的特别号离前六位远（1.58 个列距），大乐透的后区离前区更远（2.34），
/// 中间还印着一个 `+`。把「组内等距、组间隔一个已知的倍数」写成规则之后，
/// 这两件看着不一样的事其实是同一件事 —— 挑列的时候一条规则全覆盖。
struct DigitTicketLayout {

    /// 一组号码。票面上连续等距印的那一串。
    struct Group {
        /// 这一组印几个号码。
        let count: Int
        /// 这一组里每个号码的上限。七星彩的特别号是 0–14，大乐透后区 1–12。
        let maximum: Int
        /// 这一组的第一个号码，离**上一组最后一个**隔几个列距。
        ///
        /// 组内列距是 1，所以这个数只在组与组之间有意义；第一组写 0。
        let gap: CGFloat
    }

    let groups: [Group]

    /// 组与组之间**印不印分隔符**。
    ///
    /// 大乐透前后区之间印一个 `+`，双色球红蓝之间印 `-`。它们会在墨迹里
    /// 切出多余的一段，夹在号码中间 —— 挑列时要允许跳过，收行时要允许它
    /// 落在号码区里面而不算数。七星彩的特别号前面什么都不印，只是空得远。
    let separated: Bool

    init(groups: [Group], separated: Bool = false) {
        self.groups = groups
        self.separated = separated
    }

    /// 一注一共几个号码，也就是号码矩阵有几列。
    var columns: Int { groups.reduce(0) { $0 + $1.count } }

    /// 每一列的上限，按组摊平。
    var maximums: [Int] {
        groups.flatMap { Array(repeating: $0.maximum, count: $0.count) }
    }

    /// 每一列离前一列隔几个列距。第一列没有前一列，所以有 `columns - 1` 个。
    ///
    /// 组内都是 1，组与组之间是那一组的 `gap`。挑列和补列都按这张表算。
    var pitches: [CGFloat] {
        var out: [CGFloat] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { out.append(group.gap) }
            out.append(contentsOf: Array(repeating: 1, count: group.count - 1))
        }
        return out
    }

    /// 最后一列离前一列几个列距。
    ///
    /// 只有「最后一组只有一个号码」时它才不是 1 —— 七星彩的特别号、
    /// 双色球的蓝球都是这样。大乐透后区有两个号码，末列是组内的，所以是 1。
    var trailingPitch: CGFloat {
        guard let last = groups.last, groups.count > 1, last.count == 1 else { return 1 }
        return last.gap
    }

    /// 最后一列的上限。
    var trailingMaximum: Int { groups.last?.maximum ?? 9 }

    /// 一格里只印一位数字。
    ///
    /// 排列3/5、福彩3D、七星彩都是这样（七星彩的特别号到 14 是例外，
    /// 单独按 `trailingMaximum` 处理）。双色球和大乐透印的是两位数，
    /// **老那条「从识别结果里估几何」的路按一格一位写的，喂给它只会读出垃圾** ——
    /// 所以它只服务于这一类票，两位数的票配准失败就直接退到逐行二次识别。
    var singleDigit: Bool { groups.dropLast().allSatisfy { $0.maximum <= 9 } }

    /// 这个彩种的号码矩阵版式。不是矩阵排版的彩种就没有。
    ///
    /// 七乐彩、快乐8 印的是一长排两位数，Vision 横着读得好好的，
    /// 不该按矩阵去拆。
    static func of(_ game: GameKey) -> DigitTicketLayout? {
        switch game {
        case .fc3d, .pl3:
            DigitTicketLayout(groups: [Group(count: 3, maximum: 9, gap: 0)])
        case .pl5:
            DigitTicketLayout(groups: [Group(count: 5, maximum: 9, gap: 0)])
        case .qxc:
            // 前六位 0–9，特别号 0–14，离前一位 1.58 个列距（实测 103px 对 65px）
            DigitTicketLayout(groups: [Group(count: 6, maximum: 9, gap: 0),
                                       Group(count: 1, maximum: 14, gap: 1.58)])
        case .dlt:
            // 实测 26102 那张：列距 43.4、两位数宽 27、前区末位到后区首位 101.5px
            // = 2.34 个列距，中间印一个 `+`（宽 10px，不是号码）
            DigitTicketLayout(groups: [Group(count: 5, maximum: 35, gap: 0),
                                       Group(count: 2, maximum: 12, gap: 2.34)],
                              separated: true)
        default:
            nil
        }
    }

    /// 最后一列整列没认出来时，它该在哪儿。
    ///
    /// 已知前面那些列的位置和列距，这一列的位置是**算出来的**，不是找出来的。
    /// 之前是在最后一列右边扫一大片区域碰运气，既容易扫到票号，
    /// 也容易什么都扫不着。
    func trailingColumn(after last: ClosedRange<CGFloat>,
                        pitch: CGFloat) -> ClosedRange<CGFloat>? {
        guard pitch > 0 else { return nil }
        let width = last.upperBound - last.lowerBound
        let center = (last.lowerBound + last.upperBound) / 2 + trailingPitch * pitch
        let column = (center - width / 2)...(center + width / 2)
        // 算到票外面去了就是算错了
        guard column.lowerBound >= 0, column.upperBound <= 1 else { return nil }
        return column
    }
}
