import SwiftUI
import SwiftData
import UIKit

/// 三个主页面：首页、票夹、设置。
/// 标签栏用系统原生的液态玻璃，向下滚动时自动收起。
struct RootView: View {
    @Environment(DrawStore.self) private var drawStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    /// 票夹角标要的数字：出了结果、用户还没看过的票有几张。
    ///
    /// 只查未读那几条，不是把全表拉进根视图 —— 这个查询平时是空的，
    /// 只有开奖核对落地的那一刻才会变，不会让根视图跟着记录数量抖。
    @Query(filter: #Predicate<TicketRecord> { $0.resultSeenAt == nil && $0.statusRaw != "pending" })
    private var unseenRecords: [TicketRecord]

    /// 角标按**张**算，不是按注 —— 票夹里一张票就是一张卡片。
    private var unseenCount: Int { Set(unseenRecords.map(\.batchId)).count }

    @State private var selection: MainTab = .home
    /// 当前开着的抽屉，以及关掉它之后要接着开的那张。
    @State private var activeSheet: RootSheet?
    @State private var queuedSheet: RootSheet?
    @State private var toast: ToastMessage?
    @State private var celebrationTrigger = 0
    /// 点开抽屉那一刻的屏幕快照，见 `ScreenBackdrop`。
    @State private var backdrop: UIView?

    /// 点「扫描」时不切页面，只开抽屉。
    ///
    /// 注意这里**拦不住**选中态：`role: .search` 的标签一点下去，系统当场就把
    /// 那一页切上来了，绑定里怎么写都退不回去（试过同步写、异步写两版）。
    /// 所以那一页的内容是一张点击前的屏幕快照 —— 见 `ScreenBackdrop` 和下面
    /// 扫描那个 Tab 的注释。这里只负责把抽屉打开。
    private var tabSelection: Binding<MainTab> {
        Binding(
            get: { selection },
            set: { newValue in
                guard newValue == .scan else {
                    selection = newValue
                    return
                }
                guard activeSheet == nil else { return }
                // 先截图，再开抽屉 —— 顺序不能反。
                // 这一刻屏幕上还是用户刚才看的那一页，晚一步系统就切过去了。
                backdrop = ScreenBackdrop.capture()
                activeSheet = .scan
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("首页", systemImage: "chart.line.uptrend.xyaxis", value: MainTab.home) {
                HomeView()
            }

            Tab("票夹", systemImage: "wallet.bifold", value: MainTab.wallet) {
                WalletView()
            }
            // 有新结果就在标签上挂个数字。用户不进票夹也知道昨晚开奖核对完了没有，
            // 这才是「打开就想知道有没有核对」的正解。
            .badge(unseenCount)

            Tab("设置", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView()
            }

            // 扫描借用 `.search` 这个角色的**版式**。
            //
            // 系统只对这个角色做「把三个普通标签的玻璃收窄靠左、再把这一个
            // 单独拎到右边」的排布，也就是 Apple Music 底部那个样子。
            // 手工摆一颗悬浮圆做不到：系统标签栏的位置和宽度 SwiftUI 不暴露，
            // 圆只能靠猜，而且没法让那条胶囊自己让开位置。
            //
            // 标题和图标是可以自己给的 —— 上一版没传，才显示成放大镜。
            //
            // 它不承载页面：选中的那一刻在 `tabSelection` 里就被拦下来了，
            // 所以既不会切页面，也不会弹出搜索框。
            Tab("扫描", systemImage: "camera.viewfinder", value: MainTab.scan, role: .search) {
                // 抽屉开着的时候，这一页**是真的会显示出来的**（拦不住，见
                // `tabSelection` 的注释）。所以它必须长得和点击前那一页一样 ——
                // 摆的就是点击那一刻截下来的屏幕。
                //
                // 抽屉关掉之后系统会把选中态退回首页，快照也就跟着清掉了。
                if let backdrop {
                    ScreenBackdropView(snapshot: backdrop)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                } else {
                    Palette.canvas.ignoresSafeArea()
                }
            }
            // 这个位置在系统眼里仍然是「标签」，读屏会念成标签而不是按钮。
            // 用无障碍标签把它的实际作用说清楚。
            .accessibilityLabel("扫描彩票")
        }

        // **抽屉用回系统 sheet。**
        //
        // 一开始报的「点扫描时背景闪一下」，我误判成了 sheet 的呈现动画，
        // 于是把它换成自绘的 overlay —— 结果换来一连串新毛病：没有动画、
        // 底部灰带、拖拽时整棵内容树每帧重建（手感是抽搐 + 内容闪烁）。
        //
        // 真凶其实是标签栏：`role: .search` 的那一页会被真的切上来、
        // 过一会儿才退回去。那一闪从来不是 sheet 干的。挡住它的是
        // `ScreenBackdrop` 的快照，和用什么方式呈现抽屉无关。
        //
        // 认清这一点之后就没有理由自己造轮子了：拖拽、吸附、回弹、
        // 跟手的高度切换，系统这套是渲染服务级别的，而自绘版本每一帧
        // 都要让 SwiftUI 重新过一遍整个扫描页 —— 差距不是调参能补上的。
        .sheet(item: $activeSheet, onDismiss: {
            guard let next = queuedSheet else {
                // 抽屉全关完了，快照没用了 —— 留着会在下次点开时
                // 先闪一张上一回的旧画面。
                backdrop = nil
                return
            }
            queuedSheet = nil
            activeSheet = next
        }) { sheet in
            switch sheet {
            case .scan:
                TicketScanView(onManualEntry: { queuedSheet = .entry })
            case .entry:
                EntryFlowView()
            }
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
                            // 不能用 `try?` 把取消吞掉：2.6 秒内弹第二条提示时，
                            // 第一条的任务被取消后会照样往下跑 `toast = nil`，
                            // 把刚弹出来的第二条清掉。和 CelebrationView 是同一个坑。
                            do {
                                try await Task.sleep(for: .seconds(2.6))
                            } catch {
                                return
                            }
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
            // 弹抽屉时不要把背后染灰 —— 那套行为在这里恢复得不跟手，
            // 设置页「外观」那一行的图标甚至根本恢复不回来。见 TintDimming。
            TintDimming.disable()
            await drawStore.bootstrap()
            await runStartupChecks()
        }
    }

    /// 冷启动拿到开奖数据后：先按官方日历校正预测期号，再自动核对。
    ///
    /// 这一步必须发生在首帧之后。早期版本在 `.task` 里同步跑完全部核对，
    /// 记录一多首帧就画不出来，被系统看门狗当成无响应 —— 表现就是"打不开"。
    private func runStartupChecks() async {
        // 回填要在自动核对**之前**跑，而且和 autoCheck 开关无关：
        // 它修的是「已读状态是后加的」这件事，跟用不用自动核对没有关系。
        // 顺序反了的话，这次刚核对出来的新结果会被一起标成已看过。
        await Task.yield()
        if !settings.seenBackfilled {
            RecordService(context: context, drawStore: drawStore).backfillSeenForExistingRecords()
            settings.seenBackfilled = true
        }
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

/// 根视图上唯一那个 sheet 出口能开的两张抽屉。
enum RootSheet: String, Identifiable {
    case scan, entry
    var id: String { rawValue }
}

enum MainTab: Hashable {
    case home, wallet, settings
    /// 只是标签栏右边那颗独立按钮，不对应任何页面。
    case scan
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
