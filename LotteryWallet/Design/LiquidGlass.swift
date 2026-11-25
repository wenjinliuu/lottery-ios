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

    /// 内容卡片：纯净白底悬浮卡片 + 克制细描边 + 极轻中性纸影；可选附带极淡微染。
    func contentCard(cornerRadius: CGFloat = 22, padding: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(ContentCardModifier(cornerRadius: cornerRadius, padding: padding, game: nil, tint: tint))
    }

    /// 彩种内容卡片：按人眼明度校准的极淡彩种微染与描边，与票夹、首页开奖卡保持统一清透度。
    func contentCard(cornerRadius: CGFloat = 22, padding: CGFloat = 16, game: GameKey) -> some View {
        modifier(ContentCardModifier(cornerRadius: cornerRadius, padding: padding, game: game, tint: nil))
    }

    /// 系统表单配色：极浅瓷白分组底 + 纯白行块，避免闷灰感。
    ///
    /// 挂在 Form 上；行背景要单独给，见 `cardRows()`。
    func canvasForm() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Palette.groupedCanvas)
    }

    /// 表单里一组行的底色。挂在包住所有 Section 的 Group 上，逐行生效。
    func cardRows() -> some View {
        listRowBackground(Palette.card)
    }

    /// 底部悬浮液态玻璃操作面板（扫描复核底栏、手动录入底栏共用）。
    func floatingGlassPanel(cornerRadius: CGFloat = 28) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .glassEffect(.regular, in: shape)
            .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 4)
    }

    /// A single clear glass ring samples the moving canvas below its edge.
    func ballGlassFrame(cornerRadius: CGFloat, width: CGFloat) -> some View {
        let outline = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // A solid glass shape has only one reflective edge. Reveal its perimeter
        // so the balls show through the softer rim and stay crisp in the center.
        return glassEffect(.clear, in: outline)
            .mask(outline.strokeBorder(lineWidth: width).opacity(0.68))
    }

    /// 拖动图表时浮在曲线上的当日金额。
    func glassChartReadout() -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: 15))
    }

    /// 胶囊玻璃：悬浮在内容之上的筛选条、控制按钮与轻提示。
    func glassPill(tint: Color? = nil, interactive: Bool = true) -> some View {
        glassEffect(GlassStyle.pill(tint: tint, interactive: interactive), in: Capsule())
    }

    /// 清透液态玻璃胶囊：采用高通透 `.clear` 玻璃材质 + 细高光棱边与柔和悬浮影，
    /// 避免在浅色纯白画布上发灰发闷，让底部导航栏与悬浮筛选条保持真正通透的折射质感。
    func clearGlassPill(tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(ClearGlassContainerModifier(shape: Capsule(), tint: tint, interactive: interactive))
    }

    /// 饱满着色液态玻璃胶囊：用于主强调或选中态交互按钮。
    func glassProminentPill(tint: Color, interactive: Bool = true) -> some View {
        glassEffect(GlassStyle.prominent(tint: tint, interactive: interactive), in: Capsule())
    }

    /// 圆形玻璃：独立悬浮扫描按钮、翻年箭头等圆形控件。
    func glassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        glassEffect(GlassStyle.pill(tint: tint, interactive: interactive), in: Circle())
    }

    /// 清透圆形液态玻璃：与 `clearGlassPill` 成对使用，保持底栏左侧胶囊与右侧扫描按钮同一套通透材质。
    func clearGlassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(ClearGlassContainerModifier(shape: Circle(), tint: tint, interactive: interactive))
    }

    /// 让相邻的玻璃元素在动画中融合（形变、聚拢、分离）。
    func glassMorph(id: some Hashable, in namespace: Namespace.ID) -> some View {
        glassEffectID(id, in: namespace)
    }
}

private struct ContentCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat
    let game: GameKey?
    let tint: Color?

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let washColor: Color? = if let game {
            game.paperTint(for: colorScheme)
        } else if let tint {
            tint.opacity(colorScheme == .dark ? 0.07 : 0.022)
        } else {
            nil
        }
        let borderColor: Color = if let game {
            game.paperBorder(for: colorScheme)
        } else if let tint {
            tint.opacity(colorScheme == .dark ? 0.26 : 0.18)
        } else {
            Palette.cardBorder
        }
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(Palette.card)
                    if let washColor {
                        shape.fill(
                            LinearGradient(
                                stops: [
                                    .init(color: washColor, location: 0.0),
                                    .init(color: washColor.opacity(0.35), location: 0.38),
                                    .init(color: .clear, location: 0.72)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                }
                .clipShape(shape)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.038),
                        radius: 8, x: 0, y: 2)
            }
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: 1)
            }
    }
}

private struct ClearGlassContainerModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .glassEffect(GlassStyle.clear(tint: tint, interactive: interactive), in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.white.opacity(0.24), Color.white.opacity(0.08)]
                            : [Color.white.opacity(0.92), Color.black.opacity(0.07)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
                .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.085),
                    radius: 14, x: 0, y: 4)
    }
}

/// 首页顶部的清透彩光雾。用全宽径向柔光自然融入纯白/深色画布，
/// 无矩形裁切接缝，打破系统灰表单的沉闷感，同时完全不干扰前方文字对比度。
struct HomeAmbientBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength: Double = colorScheme == .dark ? 0.14 : 0.09
        ZStack(alignment: .top) {
            Palette.canvas
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack {
                    RadialGradient(
                        colors: [BallColor.blue.light.opacity(strength), .clear],
                        center: UnitPoint(x: 0.14, y: 0.06),
                        startRadius: 10,
                        endRadius: width * 0.78
                    )
                    RadialGradient(
                        colors: [BallColor.red.light.opacity(strength * 0.85), .clear],
                        center: UnitPoint(x: 0.88, y: 0.06),
                        startRadius: 10,
                        endRadius: width * 0.72
                    )
                    RadialGradient(
                        colors: [BallColor.yellow.light.opacity(strength * 0.65), .clear],
                        center: UnitPoint(x: 0.52, y: 0.24),
                        startRadius: 10,
                        endRadius: width * 0.62
                    )
                }
                .frame(width: width, height: 340)
                .mask(
                    LinearGradient(colors: [.black, .black.opacity(0.55), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
            .frame(height: 340)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Glass 配置的集中定义。
enum GlassStyle {
    static func pill(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.20)) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    static func clear(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.clear
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    static func prominent(tint: Color, interactive: Bool) -> Glass {
        var glass = Glass.regular.tint(tint)
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

/// 主操作按钮（"加入票夹"、"拍摄票据"、"识别这张"等）：真正使用 Liquid Glass 着色折射材质。
///
/// `foreground` 必须和 `tint` 成对给：彩种色里黄、琥珀这些浅底压白字只有 2:1，
/// 深色模式下强调色本身就是浅蓝，白字同样读不清。
/// 调用方一律传 `game.onTint` 或 `Palette.onAccent`。
struct ProminentGlassButton: ButtonStyle {
    var tint: Color
    var foreground: Color = Palette.onAccent
    /// 亮色彩种（七乐彩黄、七星彩琥珀）需要一圈描边把按钮边缘勾出来，
    /// 否则白字白边糊在浅色底上。
    var stroke: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, tint: tint, foreground: foreground, stroke: stroke)
    }

    /// ButtonStyle 本身不是 View，读不到 `isEnabled`，只能套一层真正的 View。
    ///
    /// 名字不能叫 `Body`：`ButtonStyle` 有个同名的关联类型，嵌套类型会被
    /// 当成它的见证类型，和 `makeBody` 的不透明返回类型冲突，协议直接不成立。
    struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let foreground: Color
        var stroke: Color = .clear
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .glassProminentPill(tint: tint, interactive: isEnabled)
                .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
                .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1) : 0.42)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: configuration.isPressed)
        }
    }
}

/// 次级操作按钮：交互式液态玻璃胶囊 + 轻彩种着色。
struct SecondaryGlassButton: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, tint: tint)
    }

    /// 同上，不能叫 `Body`。
    struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassPill(tint: tint, interactive: isEnabled)
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.42)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.78), value: configuration.isPressed)
        }
    }
}

/// 图标按钮的按下反馈。
/// Apple 的第一条规则就是「在 pointer-down 的那一刻就给反馈」——
/// 等到抬手才有反应，界面就是死的。
struct PressableIcon: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(duration: 0.22, bounce: 0), value: configuration.isPressed)
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
                    HStack(spacing: 3) {
                        Text(actionLabel)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .glassPill(interactive: true)
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
