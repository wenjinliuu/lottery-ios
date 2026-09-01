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

    var body: some View {
        TabView(selection: $selection) {
            Tab("首页", systemImage: "chart.line.uptrend.xyaxis", value: MainTab.home) {
                HomeView(onOpenEntry: { isEntryPresented = true },
                         onOpenScan: { isScanPresented = true })
            }

            Tab("票夹", systemImage: "wallet.bifold", value: MainTab.wallet) {
                WalletView(onOpenEntry: { isEntryPresented = true },
                           onOpenScan: { isScanPresented = true })
            }

            Tab("设置", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $isEntryPresented) {
            EntryFlowView()
        }
        .fullScreenCover(isPresented: $isScanPresented) {
            TicketScanView()
        }
        .environment(\.showToast, ShowToastAction { message in
            withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { toast = message }
        })
        .overlay(alignment: .bottom) {
            if let toast {
                ToastBanner(message: toast)
                    // 悬浮标签栏大约 50pt 高，96 是为了压在它上面留一段空隙。
                    // 左右也要留边，长文案（比如导入失败的系统报错）不能顶到屏幕边缘。
                    .padding(.horizontal, 20)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(2.6))
                        withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
                    }
            }
        }
        // 保存、删除、核对完成这些都只有一个轻提示，没有任何触觉反馈，
        // 手指在屏幕下半部分时经常察觉不到。
        .sensoryFeedback(.success, trigger: toast?.id)
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
        _ = try? service.checkAll()
    }
}

enum MainTab: Hashable {
    case home, wallet, settings
}

// MARK: - 轻提示

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var symbol: String = "checkmark.circle.fill"
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

    func callAsFunction(_ text: String, symbol: String = "checkmark.circle.fill") {
        handler(ToastMessage(text: text, symbol: symbol))
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
