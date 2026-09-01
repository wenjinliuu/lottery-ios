import SwiftUI

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
}

/// 八个彩种的颜色身份，色值与 web 版 styles.css 的 `--red / --blue / …` 完全一致，
/// 两端看起来必须是同一款产品。
extension BallColor {
    /// 渐变上端（浅）。
    var light: Color {
        switch self {
        case .red: Color(hex: 0xFF8793)
        case .blue: Color(hex: 0x7CBCFF)
        case .yellow: Color(hex: 0xFFC85C)
        case .k8orange: Color(hex: 0xFFB184)
        case .fc3d: Color(hex: 0x69D1EA)
        case .plum: Color(hex: 0xDE97C7)
        case .indigo: Color(hex: 0x858BCF)
        case .amber: Color(hex: 0xEDBF73)
        }
    }

    /// 渐变下端（深），同时用作辉光与文字强调色。
    var deep: Color {
        switch self {
        case .red: Color(hex: 0xEF4444)
        case .blue: Color(hex: 0x3B82F6)
        case .yellow: Color(hex: 0xFF9C34)
        case .k8orange: Color(hex: 0xF05A28)
        case .fc3d: Color(hex: 0x239FC5)
        case .plum: Color(hex: 0xBF5EA1)
        case .indigo: Color(hex: 0x525BA7)
        case .amber: Color(hex: 0xE0A24A)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [light, deep], startPoint: .top, endPoint: .bottom)
    }
}

extension GameKey {
    var tint: Color { accent.deep }
    var gradient: LinearGradient { accent.gradient }
}

/// 语义色。深浅两套由系统 `Color` 的动态特性提供，
/// 不再像 web 版那样手写两份主题变量。
enum Palette {
    /// 盈利。
    static let profit = Color(hex: 0x10B981)
    /// 亏损。
    static let loss = Color(hex: 0xEF4444)
    /// 中性/待定。
    static let neutral = Color.secondary

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
        case .prizeFloat: Color(hex: 0xF59E0B)
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
