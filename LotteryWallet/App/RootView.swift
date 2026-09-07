import SwiftUI
import SwiftData

/// 三个主页面：首页、票夹、设置。
/// 标签栏用系统原生的液态玻璃，向下滚动时自动收起。
struct RootView: View {
    @Environment(DrawStore.self) private var drawStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    @State private var selection: MainTab = .home
    @State private var isEntryPresented = false
    @State private var isScanPresented = false
    @State private var toast: ToastMessage?
    @State private var celebrationTrigger = 0
    @State private var isActionMenuExpanded = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("首页", systemImage: "chart.line.uptrend.xyaxis", value: MainTab.home) {
                HomeView()
            }

            Tab("票夹", systemImage: "wallet.bifold", value: MainTab.wallet) {
                WalletView()
            }

            // 加号是标签栏里的**一个标签**，不是浮在旁边的东西。
            //
            // 上一版把它做成右下角一颗独立的玻璃圆，结果它和三个标签不在
            // 一个层级上：菜单展开时那层遮罩会吞掉第一次点击，想回首页得点两下。
            // 现在它就是第三个标签，和首页票夹设置在同一块玻璃、同一行。
            // 它不承载页面 —— 选中的那一刻就把选择还回去，只把菜单弹起来。
            Tab("添加", systemImage: "plus.circle.fill", value: MainTab.add) {
                Color.clear
            }

            Tab("设置", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView()
            }
        }
        .onChange(of: selection) { previous, current in
            if current == .add {
                selection = previous == .add ? .home : previous
                isActionMenuExpanded.toggle()
            } else {
                // 点任何一个真页面：立刻切过去，菜单同时收起
                isActionMenuExpanded = false
            }
        }
        // 标签栏常驻。滚动时收进左下角那个胶囊虽然是系统能力，
        // 但三个标签本来就一直要用，收起来只是让人多点一次。
        //
        // 「扫描 / 录入」跟着标签栏走，不再由首页和票夹各挂一份悬浮胶囊：
        // 它是全局动作，两个页面各放一枚既重复又压内容。
        // 遮罩只盖内容区，**不盖标签栏**。盖住的话点首页要点两下：
        // 第一下被遮罩吃掉用来收菜单，第二下才切页面。
        .overlay(alignment: .top) {
            if isActionMenuExpanded {
                Color.black.opacity(0.001)
                    .ignoresSafeArea(edges: .top)
                    .onTapGesture { isActionMenuExpanded = false }
                    .padding(.bottom, 72)
            }
        }
        .overlay(alignment: .bottom) {
            ActionMenu(isExpanded: $isActionMenuExpanded,
                       onScan: { isScanPresented = true },
                       onAdd: { isEntryPresented = true })
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $isEntryPresented) {
            EntryFlowView()
        }
        // 扫描入口是个半屏抽屉，认出票之后自己长到整屏（见 TicketScanView 里的
        // presentationDetents）。选张照片而已，不必一上来就占满整个屏幕。
        .sheet(isPresented: $isScanPresented) {
            TicketScanView()
        }
        // 这里**不能**用 withAnimation 包住状态变更。
        // withAnimation 开的是一个全局事务，整棵视图树在这一帧里的所有变化
        // 都会被卷进同一段动画 —— 表现就是弹个提示，底下的整票预览卡片
        // 跟着闪一下。动画只该属于提示条自己，所以挂在它的 overlay 上。
        .environment(\.showToast, ShowToastAction { message in
            toast = message
        })
        .environment(\.celebrate, CelebrateAction { celebrationTrigger += 1 })
        .overlay {
            // 烟花压在所有内容之上、弹窗之下。只有中奖这种罕见时刻才会触发。
            CelebrationView(trigger: celebrationTrigger)
        }
        .overlay(alignment: .bottom) {
            // 动画只作用在这一小棵子树上：把 `.animation(value:)` 挂在容器上，
            // 提示条的进出照样有动画，而底下的票面预览、方格图不会被卷进来重画。
            ZStack(alignment: .bottom) {
                if let toast {
                    ToastBanner(message: toast)
                        // 悬浮标签栏大约 50pt 高，96 是为了压在它上面留一段空隙。
                        // 左右也要留边，长文案（比如导入失败的系统报错）不能顶到屏幕边缘。
                        .padding(.horizontal, 20)
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast.id) {
                            try? await Task.sleep(for: .seconds(2.6))
                            self.toast = nil
                        }
                }
            }
            .animation(.spring(duration: 0.36, bounce: 0.18), value: toast?.id)
        }
        // 震动由提示自己声明，见 `ToastMessage.feedback`。
        // 原来一律 `.success`：点号码球被拒时，选号盘那边已经震过一次，
        // 提示又补一记重的，慢半拍到手上，像是点了两下。
        .sensoryFeedback(trigger: toast?.id) { _, _ in toast?.feedback }
        .task {
            await drawStore.bootstrap()
            await runStartupChecks()
        }
    }

    /// 冷启动拿到开奖数据后：先按官方日历校正预测期号，再自动核对。
    ///
    /// 这一步必须发生在首帧之后。早期版本在 `.task` 里同步跑完全部核对，
    /// 记录一多首帧就画不出来，被系统看门狗当成无响应 —— 表现就是"打不开"。
    private func runStartupChecks() async {
        guard settings.autoCheck else { return }
        // 让出一次主线程，确保界面已经画出来
        await Task.yield()
        let service = RecordService(context: context, drawStore: drawStore)
        _ = try? service.reconcileInferredTargets()
        await Task.yield()
        // 导入恢复的老票没有命中标记，补标记之前得先把那几年的开奖号取回来
        await drawStore.loadArchives(service.archivesNeedingMatchRepair())
        await Task.yield()
        // 冷启动自动核对出中奖，也应该看到烟花 —— 这正是用户最想被告知的一刻
        if let outcome = try? service.checkAll(), outcome.won > 0 {
            celebrationTrigger += 1
        }
    }
}

enum MainTab: Hashable {
    case home, wallet, add, settings
}

// MARK: - 轻提示

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var symbol: String = "checkmark.circle.fill"
    /// 这条提示要不要自己震一下。
    ///
    /// 默认**不震**。大多数提示是跟在一个已经震过的动作后面的
    /// （点了号码球、加入候选），提示再震一次就是同一次操作响两下，
    /// 而且第二下还慢半拍 —— 手上的感觉是「多余的一记」。
    /// 只有本身没有别的反馈的动作（点不动、保存成功）才在这里配震动。
    var feedback: SensoryFeedback?
}

struct ToastBanner: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.symbol)
            Text(message.text)
                .font(.subheadline.weight(.medium))
        }
        .multilineTextAlignment(.leading)
        .lineLimit(3)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassPill(interactive: false)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }
}

/// 让任意子视图弹提示，不必层层传闭包。
struct ShowToastAction {
    let handler: (ToastMessage) -> Void

    func callAsFunction(_ text: String,
                        symbol: String = "checkmark.circle.fill",
                        feedback: SensoryFeedback? = nil) {
        handler(ToastMessage(text: text, symbol: symbol, feedback: feedback))
    }
}

private struct ShowToastKey: EnvironmentKey {
    static let defaultValue = ShowToastAction { _ in }
}

extension EnvironmentValues {
    var showToast: ShowToastAction {
        get { self[ShowToastKey.self] }
        set { self[ShowToastKey.self] = newValue }
    }
}

// MARK: - 庆祝

/// 放一次中奖烟花。和 `showToast` 一样挂在环境里，页面不必层层传闭包。
struct CelebrateAction {
    let handler: () -> Void
    func callAsFunction() { handler() }
}

private struct CelebrateKey: EnvironmentKey {
    static let defaultValue = CelebrateAction {}
}

extension EnvironmentValues {
    var celebrate: CelebrateAction {
        get { self[CelebrateKey.self] }
        set { self[CelebrateKey.self] = newValue }
    }
}
