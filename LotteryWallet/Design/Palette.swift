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
    var lightHex: UInt32 {
        switch self {
        case .red: 0xFF8E85
        case .blue: 0x7EAFFF
        case .yellow: 0xFFB879
        case .k8orange: 0xFF9D7F
        case .fc3d: 0x60C8ED
        case .plum: 0xE888C9
        case .indigo: 0x9DABF9
        case .amber: 0xF7BB69
        }
    }

    /// 渐变下端（深），同时用作辉光与文字强调色的浅色模式取值。
    var deepHex: UInt32 {
        switch self {
        case .red: 0xEF4444
        case .blue: 0x3B82F6
        case .yellow: 0xE68507
        case .k8orange: 0xF05A28
        case .fc3d: 0x239FC5
        case .plum: 0xBF5EA1
        case .indigo: 0x7682D1
        case .amber: 0xCE9136
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

    /// 压在 `accentColor` 实心底上的可读前景色。
    /// 深色模式下底色是浅端，一律用深墨。
    var onAccentColor: Color {
        Color(light: isBright ? 0x2A1E04 : 0xFFFFFF, dark: 0x101014)
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
}

/// 语义色。
///
/// **红涨绿跌**：按中文市场习惯，红色代表盈利、绿色代表亏损 —— 和欧美相反。
/// 这里刻意选鲜亮的取值而不是压暗到 WCAG 4.5:1：这几个色只出现在
/// semibold 及以上的数字和图标上（大号粗体的阈值是 3:1）。
enum Palette {
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
    /// 未命中号码球的中性灰。实心、有体积，不是把彩色球调透明。
    static let missLight = Color(light: 0xC7C9CE, dark: 0x6E727A)
    static let missDeep = Color(light: 0x9DA1A9, dark: 0x4A4E56)
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

    /// 页面底色。就用系统默认的分组背景，浅色下是那层最淡的灰，
    /// 深色下是接近纯黑的底 —— 和「设置」「邮件」这些系统 App 一致。
    static let canvas = Color(.systemGroupedBackground)
    /// 卡片底色。
    static let card = Color(.secondarySystemGroupedBackground)
    /// 分隔线。
    static let separator = Color(.separator)
}

extension RecordStatus {
    var tint: Color {
        switch self {
        case .pending: Palette.warning
        case .won: Palette.profit
        case .lost: Color.secondary
        case .prizeFloat: Palette.warning
        }
    }

    var symbol: String {
        switch self {
        case .pending: "clock"
        case .won: "checkmark.seal.fill"
        case .lost: "xmark.circle"
        case .prizeFloat: "hourglass"
        }
    }
}
