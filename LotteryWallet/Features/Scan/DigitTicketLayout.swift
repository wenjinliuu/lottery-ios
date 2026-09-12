import Foundation
import CoreGraphics

/// 数字型彩种的票面版式。
///
/// 里面**全是比值，没有一个像素数**。票在照片里占多大、用户裁得松还是紧、
/// 拍得远还是近，这些比值都不变 —— 这正是「裁切稍微不准就识别失败」的解药。
///
/// 数字是把三张真票逐像素量出来的：
///
/// | | 列距 ÷ 字宽 | 行距 ÷ 字高 | 末列偏移 |
/// |---|---|---|---|
/// | 七星彩（5 注） | 3.62 | 1.41 | 1.58 |
/// | 排列5（2 注） | 3.74 | 1.44 | — |
/// | 排列3（3 注） | 3.43 | — | — |
///
/// 三张票、两家不同的打票机，比值几乎一样 —— 说明这是**印刷版式**决定的，
/// 不是巧合。所以可以拿它当先验去**算**某一列在哪儿，而不是满图去找。
struct DigitTicketLayout {
    /// 一注有几个号码，也就是号码矩阵有几列。
    let columns: Int

    /// 最后一列离前一列有几个列距。
    ///
    /// 七星彩的特别号印得比别的号码远：实测 103px 对 65px 的列距，
    /// 也就是 1.58。正因为远，Vision 的文本行到那儿就断了，
    /// 整列一个字符都拿不到 —— 而这个比值让我们能直接**算出**它在哪儿。
    /// 其余彩种最后一列和别的列一样，就是 1。
    let trailingPitch: CGFloat

    /// 最后一列的上限。七星彩的特别号是 0-14，会印成两位数。
    let trailingMaximum: Int

    /// 这个彩种的号码矩阵版式。不是数字型彩种就没有。
    ///
    /// 七乐彩、快乐8 印的是正常行距的两位数，双色球、大乐透还带分隔符 ——
    /// 它们的行 Vision 横着读得好好的，不该按矩阵去拆。
    static func of(_ game: GameKey) -> DigitTicketLayout? {
        switch game {
        case .fc3d, .pl3:
            DigitTicketLayout(columns: 3, trailingPitch: 1, trailingMaximum: 9)
        case .pl5:
            DigitTicketLayout(columns: 5, trailingPitch: 1, trailingMaximum: 9)
        case .qxc:
            DigitTicketLayout(columns: 7, trailingPitch: 1.58, trailingMaximum: 14)
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
