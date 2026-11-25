import SwiftUI
import SwiftData
import UIKit

/// 三个主页面（首页、票夹、设置）+ 系统官方液态玻璃标签栏。
///
/// 直接采用 SwiftUI 原生 `TabView` 与分离式扫描按钮（iOS 27 用 `.prominent`，iOS 26 用 `.search`），
/// 完整保留官方液态玻璃跳动水滴透镜、官方选中态与系统贴底间距；`.tint(.primary)` 让选中态
/// 与扫描按钮保持中性黑/白主色，不带蓝色主题色。
struct RootView: View {
    @Environment(DrawStore.self) private var drawStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(BackupCenter.self) private var backupCenter
    @Environment(StoreHealth.self) private var storeHealth

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
    @State private var startupChecksComplete = false
    @State private var queuedSheet: RootSheet?
    /// 从扫描页转到手动录入时带过去的票面照片。
    ///
    /// 不塞进 `RootSheet` 里是因为那是个 `String` 原始值的枚举，
    /// 它同时充当 sheet 的 id —— 挂上一张图会把 id 搞脏。
    @State private var entryReference: EntryReference?
    @State private var toastCenter = ToastCenter()
    @State private var celebration = CelebrationCenter()
    /// 点开扫描抽屉那一刻的屏幕快照，见 `ScreenBackdrop`。
    @State private var backdrop: UIView?

    private var scanTabRole: TabRole {
        if #available(iOS 27.0, *) {
            return .prominent
        } else {
            return .search
        }
    }

    private var tabSelection: Binding<MainTab> {
        Binding(
            get: { selection },
            set: { newValue in
                guard newValue == .scan else {
                    selection = newValue
                    return
                }
                guard activeSheet == nil else { return }
                backdrop = ScreenBackdrop.capture()
                activeSheet = .scan
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("首页", systemImage: "house", value: MainTab.home) {
                HomeView()
            }

            Tab("票夹", systemImage: "wallet.bifold", value: MainTab.wallet) {
                WalletView(isActive: selection == .wallet)
            }
            .badge(unseenCount)

            Tab("设置", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView()
            }

            Tab("扫描", systemImage: "camera.viewfinder", value: MainTab.scan, role: scanTabRole) {
                if let backdrop {
                    ScreenBackdropView(snapshot: backdrop)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                } else {
                    Palette.canvas.ignoresSafeArea()
                }
            }
            .accessibilityLabel("扫描票据")
        }
        .tint(.primary)
        .onChange(of: scenePhase) { _, phase in
            guard !DemoData.isEnabled else { return }
            if phase == .background { autoBackup() }
            if phase == .active { Task { await DrawPushCenter.shared.refreshOnLaunch() } }
        }
        .sheet(item: $activeSheet, onDismiss: {
            guard let next = queuedSheet else {
                backdrop = nil
                entryReference = nil
                return
            }
            queuedSheet = nil
            activeSheet = next
        }) { sheet in
            switch sheet {
            case .scan:
                TicketScanView(onManualEntry: { reference in
                    entryReference = reference
                    queuedSheet = .entry
                })
            case .entry:
                EntryFlowView(reference: entryReference)
            }
        }
        .environment(toastCenter)
        .environment(celebration)
        .overlay(alignment: .top) {
            if !storeHealth.isHealthy {
                StoreWarningBanner()
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
        }
        .overlay {
            CelebrationView(trigger: celebration.trigger)
        }
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                if let toast = toastCenter.current {
                    ToastBanner(message: toast)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast.id) {
                            do {
                                try await Task.sleep(for: .seconds(2.6))
                            } catch {
                                return
                            }
                            toastCenter.current = nil
                        }
                }
            }
            .animation(.spring(duration: 0.36, bounce: 0.18), value: toastCenter.current?.id)
        }
        .sensoryFeedback(trigger: toastCenter.current?.id) { _, _ in toastCenter.current?.feedback }
        .onChange(of: drawStore.resultsRevision) { _, _ in
            guard startupChecksComplete, settings.autoCheck, !drawStore.checkingWallet else { return }
            let service = RecordService(context: context, drawStore: drawStore)
            if let outcome = try? service.checkAll(), outcome.won > 0 { celebration() }
        }
        .task {
            TintDimming.disable()
            async let pushRegistration: Void = DrawPushCenter.shared.refreshOnLaunch()
            await drawStore.bootstrap()
            await runStartupChecks()
            startupChecksComplete = true
            await pushRegistration
        }
    }

    /// 冷启动拿到开奖数据后：先按官方日历校正预测期号，再自动核对。
    ///
    /// 这一步必须发生在首帧之后。早期版本在 `.task` 里同步跑完全部核对，
    /// 记录一多首帧就画不出来，被系统看门狗当成无响应 —— 表现就是"打不开"。
    /// 静默写一份备份到 iCloud。开关关着时根本不会走到这里。
    /// 退到后台时自动备份。
    ///
    /// 具体写哪儿、写不写、留几份，全由 `BackupCenter` 决定 —— 这里只负责
    /// 把「这一轮操作做完了」这个时机告诉它。iCloud 用不了时它会落到本机，
    /// 不会像上一版那样整个静默失效。
    private func autoBackup() {
        let descriptor = FetchDescriptor<TicketRecord>()
        guard let all = try? context.fetch(descriptor) else { return }
        Task {
            await backupCenter.autoBackup(records: all,
                                          context: context,
                                          preferring: settings.iCloudBackupEnabled ? .iCloud : .local)
            if backupCenter.items.first != nil { settings.lastBackupAt = Date() }
        }
    }

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
        // bootstrap 只带来每个彩种的最新一期。盯着更早期号的票还核对不了，
        // 这时候才去补那几个彩种的最近 30 期 —— 通常一两个，不是八个。
        await drawStore.ensureRecentDraws(for: service.gamesAwaitingDraws())
        await Task.yield()
        // 冷启动自动核对出中奖，也应该看到烟花 —— 这正是用户最想被告知的一刻
        if let outcome = try? service.checkAll(), outcome.won > 0 {
            celebration()
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
    /// 标签栏右侧独立扫描按钮，不对应实际页面。
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
///
/// 写成 `@Observable` 的引用类型而不是塞进 `EnvironmentKey` 的闭包：
/// 闭包不可比较，每次重建都会让所有读它的页面跟着失效。引用类型注入一次
/// 身份就固定了，页面只在 `current` 真的变了的时候才重算。
///
/// `callAsFunction` 让调用点写法和以前一模一样：`showToast("已保存")`。
@MainActor
@Observable
final class ToastCenter {
    /// 当前显示的那一条。nil 表示没有提示。
    var current: ToastMessage?

    func callAsFunction(_ text: String,
                        symbol: String = "checkmark.circle.fill",
                        feedback: SensoryFeedback? = nil) {
        current = ToastMessage(text: text, symbol: symbol, feedback: feedback)
    }
}

// MARK: - 庆祝

/// 放一次中奖烟花。和 `ToastCenter` 同一套理由，同一套用法：`celebrate()`。
@MainActor
@Observable
final class CelebrationCenter {
    /// 每加一次放一轮烟花。`CelebrationView` 盯的就是它。
    private(set) var trigger = 0

    func callAsFunction() { trigger += 1 }
}


/// 数据库不健康时顶部那条常驻警告。
struct StoreWarningBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("数据库打不开，当前是临时模式")
                    .font(.footnote.weight(.semibold))
                Text("现在录入或导入的内容关掉应用就会消失。详情见「设置 → 备份与恢复」。")
                    .font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.warning, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}
