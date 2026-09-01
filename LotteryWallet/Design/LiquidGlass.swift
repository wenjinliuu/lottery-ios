import SwiftUI

/// 视觉分层的统一封装。
///
/// 分层原则按苹果自己的用法来：
/// **液态玻璃属于悬浮在内容之上的导航层**（标签栏、工具栏、悬浮按钮、轻提示），
/// 内容本身坐在系统分组背景上，用不透明卡片承载。
/// 早期版本把玻璃铺满内容卡片，结果底下没东西可折射，整页发灰发糊。
///
/// 所有 iOS 26 的 Liquid Glass 系统 API 都只在这一个文件里出现，
/// 页面代码一律走下面这些语义化修饰符。
extension View {

    /// 内容卡片：分组列表里的那种白底圆角块，不是玻璃。
    func contentCard(cornerRadius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }

    /// 胶囊玻璃：悬浮在内容之上的筛选 chip、分段控件。
    func glassPill(tint: Color? = nil, interactive: Bool = true) -> some View {
        glassEffect(GlassStyle.pill(tint: tint, interactive: interactive), in: Capsule())
    }

    /// 圆形玻璃：右下角悬浮扫描 / 添加按钮。
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
    static func pill(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.22)) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// 一组会互相融合的玻璃元素。放在同一个容器里，
/// 出现 / 消失 / 移动时系统会做液态形变而不是各自淡入淡出。
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
            .background(tint, in: Capsule())
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// 次级操作按钮：淡色底 + 彩种色文字。
struct SecondaryGlassButton: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(tint.opacity(0.12), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 分区标题。
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

/// 设置页那种圆角方形彩色图标，和系统「设置」保持一致的观感。
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 29

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}
