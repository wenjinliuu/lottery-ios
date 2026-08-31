import SwiftUI

/// 液态玻璃的统一封装。
///
/// 所有 iOS 26 的 Liquid Glass 系统 API 都只在这一个文件里出现，
/// 页面代码一律走下面这些语义化修饰符。这样 SDK 若调整签名，
/// 改动范围就锁在这里，不会散落到二十几个视图里。
extension View {

    /// 卡片级玻璃：首页趋势卡、统计卡、设置分组。
    func glassCard(cornerRadius: CGFloat = 26, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return glassEffect(GlassStyle.card(tint: tint), in: shape)
    }

    /// 胶囊玻璃：筛选 chip、分段控件、悬浮按钮。
    func glassPill(tint: Color? = nil, interactive: Bool = true) -> some View {
        glassEffect(GlassStyle.pill(tint: tint, interactive: interactive), in: Capsule())
    }

    /// 圆形玻璃：右下角悬浮扫描/添加按钮。
    func glassCircle(tint: Color? = nil) -> some View {
        glassEffect(GlassStyle.pill(tint: tint, interactive: true), in: Circle())
    }

    /// 让相邻的玻璃元素在动画中融合（形变、聚拢、分离）。
    func glassMorph(id: some Hashable, in namespace: Namespace.ID) -> some View {
        glassEffectID(id, in: namespace)
    }
}

/// Glass 配置的集中定义。
enum GlassStyle {
    static func card(tint: Color?) -> Glass {
        guard let tint else { return .regular }
        // 淡淡染上彩种色，让玻璃"知道"自己属于哪个彩种，但不喧宾夺主。
        return Glass.regular.tint(tint.opacity(0.14))
    }

    static func pill(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.22)) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// 一组会互相融合的玻璃元素。放在同一个容器里，
/// 出现/消失/移动时系统会做液态形变而不是各自淡入淡出。
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
    }
}

/// 主操作按钮（"确认已购买并加入票夹"这类）。
struct ProminentGlassButton: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(tint.gradientFill, in: Capsule())
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.30), lineWidth: 0.8)
            )
            .shadow(color: tint.opacity(0.35), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 次级操作按钮：玻璃底 + 彩种色文字。
struct SecondaryGlassButton: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassPill(tint: tint)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

extension Color {
    /// 主按钮用的同色微渐变，比纯色更有体积感。
    var gradientFill: LinearGradient {
        LinearGradient(
            colors: [opacity(0.92), self],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// 分区标题，对应 web 版 `.section-title`。
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var action: (() -> Void)?
    var actionLabel: String = "更多"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if let action {
                Button(action: action) {
                    HStack(spacing: 2) {
                        Text(actionLabel)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
