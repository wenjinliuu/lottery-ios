import SwiftUI

/// 自绘的底部抽屉。
///
/// 为什么不用系统的 `.sheet`：
///
/// 系统 sheet 在弹出时会把**呈现方**一起做动画 —— 缩小、压暗、加圆角。
/// 扫描抽屉是半透明玻璃，背面那一层看得清清楚楚，于是每次点扫描，
/// 首页/票夹/设置都跟着抖一下。这个行为 SwiftUI 没有开关可关：
/// `presentationBackground`、`presentationBackgroundInteraction` 管的都不是它。
///
/// 所以这里干脆不走系统呈现：抽屉只是根视图上的一层 overlay，
/// 遮罩淡入、面板上滑，**底下那棵视图树一帧都不会重画**。
///
/// 代价是拖拽、高度切换这些要自己写 —— 都在这个文件里，见下。
enum DrawerHeight {
    case medium
    case large

    /// 屏幕可用高度里占多少。
    func points(in available: CGFloat) -> CGFloat {
        switch self {
        case .medium: available * 0.58
        case .large: available * 0.96
        }
    }
}

/// 关掉当前抽屉。放在环境里，抽屉内容不必层层传闭包。
///
/// 名字和用法都对齐 `@Environment(\.dismiss)`，这样抽屉里的页面
/// 只要换一行 `@Environment` 声明，原来的 `dismiss()` 调用一句都不用改。
struct DrawerDismissAction {
    let handler: () -> Void
    func callAsFunction() { handler() }
}

/// 让抽屉里的页面自己把抽屉撑高（比如扫完进复核页要整屏）。
struct DrawerExpandAction {
    let handler: (DrawerHeight) -> Void
    func callAsFunction(_ height: DrawerHeight) { handler(height) }
}

private struct DrawerDismissKey: EnvironmentKey {
    static let defaultValue = DrawerDismissAction {}
}

private struct DrawerExpandKey: EnvironmentKey {
    static let defaultValue = DrawerExpandAction { _ in }
}

extension EnvironmentValues {
    var drawerDismiss: DrawerDismissAction {
        get { self[DrawerDismissKey.self] }
        set { self[DrawerDismissKey.self] = newValue }
    }

    var drawerExpand: DrawerExpandAction {
        get { self[DrawerExpandKey.self] }
        set { self[DrawerExpandKey.self] = newValue }
    }
}

/// 抽屉这一层。挂在根视图的 overlay 上，由一个可选值驱动，用法同 `.sheet(item:)`。
struct DrawerLayer<Item: Identifiable & Equatable, Content: View>: View {
    @Binding var item: Item?
    /// 每一张抽屉一上来该有多高。
    ///
    /// 一律从半屏起步、再让内容自己撑大是不行的：录入页一打开就需要整屏，
    /// 那样会先闪一下半屏再长高。所以开哪一张、多高，开之前就定好。
    var initialHeight: (Item) -> DrawerHeight = { _ in .medium }
    /// 抽屉**真正关完之后**才回调。抽屉之间接力要等这一刻，
    /// 在关闭动画开始的同一帧去开下一张会被吞掉。
    var onDismissed: () -> Void = {}
    @ViewBuilder var content: (Item) -> Content

    /// 正在画的那一张。它比 `item` 多活一段 —— 关闭动画要跑完。
    @State private var rendered: Item?
    /// 面板是不是已经升到位。它和 `rendered` **刻意分成两帧**，原因见 body。
    @State private var shown = false
    @State private var height: DrawerHeight = .medium
    /// 手指当前拖出来的位移。不参与隐式动画，要跟手。
    @State private var drag: CGFloat = 0

    private static var rise: Animation { .spring(duration: 0.42, bounce: 0.12) }

    var body: some View {
        // **整层忽略安全区**，面板因此贴着屏幕物理底边。
        //
        // 原来面板底边停在安全区底部，靠背景多画一截去盖 Home 指示条那一带 ——
        // 内容到安全区就结束了，下面那一截只剩背景色，看着就是一条灰带。
        // 忽略安全区之后，Home 指示条那一条归内容自己所有（由 bottomInset 垫出来），
        // 整块面板从上到下是同一个底，没有接缝可露。
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let available = proxy.size.height - insets.top - insets.bottom
            let hidden = available + insets.bottom + 140
            ZStack(alignment: .bottom) {
                if let rendered {
                    dimmer.opacity(shown ? 0.32 : 0)
                    panel(for: rendered, available: available, bottomInset: insets.bottom)
                        .offset(y: shown ? drag : hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 只有「升起/落下」和「换高度」带动画。`drag` 不在这里 —— 它要跟手。
            .animation(Self.rise, value: shown)
            .animation(Self.rise, value: height)
        }
        .ignoresSafeArea()
        .onChange(of: item) { _, new in
            if let new {
                // **先把内容建好，下一帧再升起来。**
                //
                // 抽屉里是一整个 NavigationStack，第一次构建要花掉十几毫秒。
                // 如果构建和动画挤在同一帧，这笔开销正好砸在动画的第一帧上 ——
                // 手上的感觉就是"起步一顿"。系统的相册选择器之所以顺，
                // 是因为它整个在另一个进程里，构建根本不占我们这一帧。
                //
                // 拆成两帧之后：这一帧把面板建好、摆在屏幕外（不可见，卡也看不出来），
                // 下一帧只剩纯粹的位移动画。
                height = initialHeight(new)
                drag = 0
                shown = false
                rendered = new
                DispatchQueue.main.async { shown = true }
            } else if rendered != nil {
                shown = false
                // 落完再拆内容、再交棒。下一张抽屉要等这一张真的退场，
                // 在同一帧里开会被吞掉。
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.45))
                    guard item == nil else { return }
                    rendered = nil
                    onDismissed()
                }
            }
        }
    }

    private var dimmer: some View {
        Color.black
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .accessibilityLabel("关闭")
            .accessibilityAddTraits(.isButton)
    }

    private func panel(for value: Item, available: CGFloat, bottomInset: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26,
                                           style: .continuous)
        return VStack(spacing: 0) {
            grabber()
            content(value)
                .environment(\.drawerDismiss, DrawerDismissAction { close() })
                .environment(\.drawerExpand, DrawerExpandAction { height = $0 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height.points(in: available))
        // Home 指示条那一条：让内容整体上移，空出来的地方仍然是面板自己的底色。
        // 这样从抓手到屏幕最底下是连续的一块，没有色差。
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity)
        .background(shape.fill(Palette.canvas))
        .clipShape(shape)
        // **这里不能挂 .shadow。**
        //
        // 给一块正在做位移动画的大视图加阴影，等于让它每一帧都离屏重绘一次
        // 22pt 的模糊 —— 这是升起时掉帧最大的一笔开销。
        // 何况背后已经压了一层遮罩，面板和背景本来就分得清，阴影是白付的成本。
        // 顶边那道细线足够交代"这是一块浮起来的东西"。
        .overlay(alignment: .top) {
            shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        }
    }

    /// 抓手。
    ///
    /// 拖拽手势**只挂在这一条**，不挂整块面板 —— 挂整块的话，
    /// 内容里的 ScrollView 就抢不到滑动手势了，复核页会变得没法滚。
    private func grabber() -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.primary.opacity(0.22))
                .frame(width: 38, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let dy = value.translation.height
                    // 往上拖给阻尼，别让它能被拽出屏幕顶
                    drag = dy > 0 ? dy : dy * 0.22
                }
                .onEnded { value in
                    let dy = value.translation.height
                    let flick = value.predictedEndTranslation.height
                    if dy > 120 || flick > 340 {
                        close()
                        return
                    }
                    if dy < -50 || flick < -220 { height = .large }
                    withAnimation(Self.rise) { drag = 0 }
                }
        )
        .accessibilityHidden(true)
    }

    private func close() {
        drag = 0
        // 只改 item，升起/落下的动画统一由 onChange 处理，
        // 免得两处各写一份、对不齐。
        item = nil
    }
}
