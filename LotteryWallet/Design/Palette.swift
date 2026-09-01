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
        case .red: 0xFF8793
        case .blue: 0x7CBCFF
        case .yellow: 0xFFC85C
        case .k8orange: 0xFFB184
        case .fc3d: 0x69D1EA
        case .plum: 0xDE97C7
        case .indigo: 0x858BCF
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

    /// 亮到白字读不清的两个彩种（七乐彩黄、七星彩特别号琥珀）。
    var isBright: Bool { self == .yellow || self == .amber }

    /// 球面数字色。亮球用深墨，其余用白。
    var ink: Color { isBright ? Color(hex: 0x3A2A06) : .white }

    /// 球面填充。浅端只留在顶部当高光，0.72 之后就是深端 ——
    /// 保证垂直居中的数字落在深端上，白字才有 3:1 以上的对比度。
    var gradient: LinearGradient {
        LinearGradient(
            stops: [.init(color: light, location: 0), .init(color: deep, location: 0.72)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 当作文字 / 描边 / 小面积填充时的彩种色。
    /// 深色模式下改用浅端，否则深端压在近黑底上只有 2.x:1。
    var accentColor: Color { Color(light: deepHex, dark: lightHex) }

    /// 压在 `accentColor` 实心底上的可读前景色。
    /// 深色模式下底色是浅端，一律用深墨。
    var onAccentColor: Color {
        Color(light: isBright ? 0x2A1E04 : 0xFFFFFF, dark: 0x101014)
    }
}

extension GameKey {
    /// 彩种色。文字、描边、图表、实心底都用它。
    var tint: Color { accent.accentColor }
    /// 压在 `tint` 实心底上的前景色。凡是「彩种色打底 + 文字」都必须成对使用。
    var onTint: Color { accent.onAccentColor }
    var gradient: LinearGradient { accent.gradient }
}

/// 语义色。
enum Palette {
    /// 盈利。浅色模式要压暗到 4.5:1，深色模式要提亮。
    static let profit = Color(light: 0x047857, dark: 0x34D399)
    /// 亏损。
    static let loss = Color(light: 0xDC2626, dark: 0xF87171)
    /// 提醒 / 待公布。
    static let warning = Color(light: 0xB45309, dark: 0xFBBF24)
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
        case .pending: Color.secondary
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
