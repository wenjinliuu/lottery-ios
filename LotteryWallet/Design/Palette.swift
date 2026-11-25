import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// 浅色 / 深色各给一套色值。深色模式下同一个色号往往亮度不够，
    /// 靠系统自动反色是反不出来的，只能显式给两份。
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

/// 八个彩种的颜色身份，色值与 web 版 styles.css 的 `--red / --blue / …` 保持一致。
///
/// 但**文字色不能直接用这套色号**：这些是给球面填充用的高饱和色，
/// 白字压在浅端（黄、琥珀、浅蓝）上对比度只有 1.5–2.3:1，小号粗体也读不清。
/// 所以这里分成三类 token：
/// - `light` / `deep` / `gradient`：填充用，视觉身份；
/// - `ink`：压在球面上的数字色；
/// - `accentColor` / `onAccentColor`：当作文字或实心底时用的自适应对。
extension BallColor {
    /// 渐变上端（浅）。
    ///
    /// 采用「只齐渐变」方案：**八个深端色一个像素都不改**，只把浅端重算成
    /// 统一的规则（亮度按剩余色域空间提，彩度尽量保住），让八个球的渐变强度一致。
    /// 例外是七乐彩黄和七星彩琥珀 —— 这两个深端本来就在色域顶附近，
    /// 再提亮会被洗成米白/桃色，所以保留它们原本的浅端。
    var lightHex: UInt32 {
        switch self {
        case .red: 0xFF9188
        case .blue: 0x81B1FF
        case .yellow: 0xFFC85C
        case .k8orange: 0xFF9F82
        case .fc3d: 0x5ACAF2
        case .plum: 0xED88CC
        case .indigo: 0x7883D3
        case .amber: 0xEDBF73
        }
    }

    /// 渐变下端（深），同时用作辉光与文字强调色的浅色模式取值。
    var deepHex: UInt32 {
        switch self {
        case .red: 0xEF4444
        case .blue: 0x3B82F6
        case .yellow: 0xFF9C34
        case .k8orange: 0xF05A28
        case .fc3d: 0x239FC5
        case .plum: 0xBF5EA1
        case .indigo: 0x525BA7
        case .amber: 0xE0A24A
        }
    }

    var light: Color { Color(hex: lightHex) }
    var deep: Color { Color(hex: deepHex) }

    /// 亮到白字对比度偏低的两个彩种（七乐彩黄、七星彩特别号琥珀）。
    /// 现在不再换墨色，只用来给这两个球加一层描边把边缘勾出来。
    var isBright: Bool { self == .yellow || self == .amber }

    /// 球面数字色。八个彩种统一用白 —— 一致性比单个球的对比度重要，
    /// 黄球和琥珀球靠 `rimStroke` 补边缘可辨识度。
    var ink: Color { .white }

    /// 亮色球的边缘描边。深色球不需要。
    var rimStroke: Color { isBright ? deep.opacity(0.55) : .clear }

    /// 球面填充。浅端到深端的完整渐变，保持八个彩种鲜亮的视觉身份。
    var gradient: LinearGradient {
        LinearGradient(colors: [light, deep], startPoint: .top, endPoint: .bottom)
    }

    /// 当作文字 / 描边 / 小面积填充时的彩种色。
    /// 深色模式下改用浅端，否则深端压在近黑底上只有 2.x:1。
    var accentColor: Color { Color(light: deepHex, dark: lightHex) }

    /// 压在 `accentColor` 实心底上的前景色。
    ///
    /// 八个彩种**统一用白字** —— 之前给黄和琥珀换深墨是为了对比度，
    /// 但那让七乐彩的按钮在一堆白字按钮里显得像另一个 App。
    /// 亮色底靠 `solidStroke` 描一圈同色深端来补边缘可辨识度。
    var onAccentColor: Color { Color(light: 0xFFFFFF, dark: 0x101014) }

    /// 亮色彩种当实心底时补的一圈描边。深色彩种不需要。
    var solidStroke: Color {
        isBright ? Color(light: deepHex, dark: 0x000000).opacity(0.28) : .clear
    }

    /// 卡片与票面左上角极淡微染透明度（浅色模式）。
    /// 按人眼感知明度与彩度校准，以排列 5 的轻盈通透感为基准，
    /// 压低大乐透蓝、七星彩靛、福彩 3D 青等冷高彩度颜色的占比，避免肉眼看起来深浅不一。
    var paperTintLightOpacity: Double {
        switch self {
        case .blue: 0.017
        case .indigo: 0.018
        case .fc3d: 0.019
        case .red: 0.021
        case .k8orange: 0.022
        case .plum: 0.024
        case .yellow, .amber: 0.032
        }
    }

    var paperTintDarkOpacity: Double {
        switch self {
        case .blue, .indigo, .fc3d: 0.065
        case .red, .k8orange, .plum: 0.075
        case .yellow, .amber: 0.090
        }
    }

    /// 卡片与票面描边透明度（浅色模式），同步按彩度校准让八个彩种轮廓轻重一致。
    var paperBorderLightOpacity: Double {
        switch self {
        case .blue, .indigo, .fc3d: 0.16
        case .red, .k8orange, .plum: 0.18
        case .yellow, .amber: 0.24
        }
    }

    /// 庆祝烟花用的一整套亮色，比球面色更跳。
    static let festive: [Color] = [
        Color(hex: 0xFF3B5C), Color(hex: 0xFFB020), Color(hex: 0x22D3A7),
        Color(hex: 0x3B9BFF), Color(hex: 0xB86BFF), Color(hex: 0xFF7AC4),
        Color(hex: 0x5BE1FF), Color(hex: 0xFFE066)
    ]
}

extension GameKey {
    /// 彩种色。文字、描边、图表、实心底都用它。
    var tint: Color { accent.accentColor }
    /// 压在 `tint` 实心底上的前景色。凡是「彩种色打底 + 文字」都必须成对使用。
    var onTint: Color { accent.onAccentColor }
    var gradient: LinearGradient { accent.gradient }

    /// 按感知明度校准后的卡片极淡微染色。
    func paperTint(for colorScheme: ColorScheme) -> Color {
        tint.opacity(colorScheme == .dark ? accent.paperTintDarkOpacity : accent.paperTintLightOpacity)
    }

    /// 按彩度校准后的卡片细描边色。
    func paperBorder(for colorScheme: ColorScheme) -> Color {
        tint.opacity(colorScheme == .dark ? 0.26 : accent.paperBorderLightOpacity)
    }
}

/// 语义色。
///
/// **红涨绿跌**：按中文市场习惯，红色代表盈利、绿色代表亏损 —— 和欧美相反。
/// 这里刻意选鲜亮的取值而不是压暗到 WCAG 4.5:1：这几个色只出现在
/// semibold 及以上的数字和图标上（大号粗体的阈值是 3:1）。
enum Palette {
    static let chartSpending = Color.accentColor
    /// 盈利 —— 红。
    static let profit = Color(light: 0xF5333F, dark: 0xFF6B76)
    /// 亏损 —— 绿。
    static let loss = Color(light: 0x00A651, dark: 0x43DD84)
    /// 提醒 / 待核对 / 奖金待公布。
    static let warning = Color(light: 0xFF9500, dark: 0xFFB340)
    /// 「今日开奖」这类正向状态标记。
    static let live = Color(light: 0x00B884, dark: 0x3DE0A6)
    /// 危险 / 删除 / 胆码标记。和「盈利红」分开，避免语义打架。
    static let danger = Color(light: 0xE0322F, dark: 0xFF6A64)
    /// 未命中号码球。
    ///
    /// 第一版用「整颗压到 34% 透明」——白字跟着变淡，整张票像褪了色。
    /// 第二版用「实心中性灰 + 白字」——不褪色了，但灰球太实，
    /// 和命中的彩球抢注意力。
    /// 这一版让它真正退到后面：很淡的灰底配深灰数字，号码依然清晰，
    /// 但视觉重量明显低于彩色球。
    static let missLight = Color(light: 0xEDEEF1, dark: 0x2E3238)
    static let missDeep = Color(light: 0xDFE1E6, dark: 0x24272C)
    /// 未命中球上的数字色。
    static let missInk = Color(light: 0x8A8F98, dark: 0x8C929B)
    /// 中性/待定。
    static let neutral = Color.secondary
    /// 压在系统强调色实心底上的前景色。
    /// AccentColor 深色模式是 #7CBCFF 这种浅蓝，白字只有 1.9:1。
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x101014)

    static func profitColor(_ value: Double) -> Color {
        if value > 0 { return profit }
        if value < 0 { return loss }
        return neutral
    }

    /// 页面底色。浅色下纯净高明度白，让内容和彩色球罐自由呼吸；深色下为深曜石黑。
    static let canvas = Color(light: 0xFFFFFF, dark: 0x090A0D)
    /// 表单类二级页（备份、数据状态）的极浅瓷白底，让纯白行块保持清晰分组层次。
    static let groupedCanvas = Color(light: 0xF7F8FB, dark: 0x090A0D)
    /// 内容卡片底色。浅色为纯净悬浮白，配细描边与柔和中性纸影；深色为深灰石板面。
    static let card = Color(light: 0xFFFFFF, dark: 0x17191F)
    /// 卡片细描边。给纯白悬浮卡片一条克制利落的轮廓线。
    static let cardBorder = Color(light: 0xE8ECF4, dark: 0x282E3A)
    /// 实体票据纸面底色。浅色回归纯净白底，消除偏冷灰底感，靠极淡彩种微染与细描边界定票面。
    static let paper = Color(light: 0xFFFFFF, dark: 0x181B22)
    /// 静态辅助胶囊底色。
    static let surfaceChip = Color(light: 0xF1F4F9, dark: 0x232734)
    /// 分隔线。
    static let separator = Color(.separator)
}

// MARK: - 跟随 Dynamic Type 的小字号

/// 固定视觉尺寸、但跟着系统字号一起缩放的小字。
///
/// `.font(.system(size: 10))` 写死之后**完全不随 Dynamic Type 变化** ——
/// 用户把字号调到最大，免责声明、奖级行、图例这些本来就最小的字还是 10pt，
/// 是 HIG 无障碍那一关的硬失败。
///
/// 但直接换成 `.caption2` 会改变默认字号下的观感（这些位置的字号是按票面
/// 排版调过的）。`@ScaledMetric` 两头都占：默认字号下**和原来一模一样**，
/// 系统字号变大时按 `.caption2` 的比例跟着长。
private struct ScaledFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: .caption2)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// 见 `ScaledFontModifier`：默认字号下等同 `.font(.system(size:))`，
    /// 但会跟随 Dynamic Type 缩放。
    func scaledFont(_ size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }
}
