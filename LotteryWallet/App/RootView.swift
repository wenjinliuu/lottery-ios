import SwiftUI
import SwiftData

/// 三个主页面：首页、票夹、设置。
/// 标签栏用系统原生的液态玻璃，向下滚动时自动收起。
struct RootView: View {
    @Environment(DrawStore.self) private var drawStore
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
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(2.6))
                        withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
                    }
            }
        }
        .task {
            await drawStore.bootstrap()
            await runStartupChecks()
        }
    }

    /// 冷启动拿到开奖数据后：先按官方日历校正预测期号，再自动核对。
    private func runStartupChecks() async {
        let service = RecordService(context: context, drawStore: drawStore)
        try? service.reconcileInferredTargets()
        try? service.checkAll()
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassPill(interactive: false)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
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
