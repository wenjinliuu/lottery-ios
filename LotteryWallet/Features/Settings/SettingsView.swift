import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DrawStore.self) private var drawStore
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var showToast
    @Query private var records: [TicketRecord]

    @State private var isClearConfirmPresented = false
    @State private var isRefreshing = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $settings.autoCheck) {
                        row("checkmark.circle.fill", .green, "开奖后自动核对")
                    }
                } footer: {
                    Text("每次打开应用并拿到新开奖数据时，自动核对待开奖的票据。")
                }

                Section {
                    Picker(selection: $settings.appearance) {
                        ForEach(AppSettings.Appearance.allCases) { item in
                            Label(item.label, systemImage: item.symbol).tag(item)
                        }
                    } label: {
                        row("circle.lefthalf.filled", .indigo, "外观")
                    }
                }

                Section {
                    LabeledContent {
                        Text(drawStore.latestUpdatedAt.isEmpty ? "暂无" : DateText.friendly(drawStore.latestUpdatedAt))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        row("arrow.down.circle.fill", .blue, "开奖数据")
                    }

                    LabeledContent {
                        Text(drawStore.calendar == nil ? "未获取" : "正常")
                            .font(.footnote)
                            .foregroundStyle(drawStore.calendar == nil ? Palette.warning : Color.secondary)
                    } label: {
                        row("calendar", .red, "开奖日历")
                    }

                    LabeledContent {
                        Text("\(drawStore.loadedHistoryGames.count)/\(GameKey.ordered.count)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        row("externaldrive.fill", .gray, "往期缓存")
                    }

                    Button {
                        refreshData()
                    } label: {
                        HStack {
                            row("arrow.clockwise", .teal, "刷新开奖数据")
                            Spacer()
                            if isRefreshing { ProgressView() }
                        }
                    }
                    .disabled(isRefreshing)
                } header: {
                    Text("数据状态")
                } footer: {
                    Text("开奖数据来自公开仓库 lottery-data-repo，应用只读取、不上传任何内容。")
                }

                // 备份**只有一个入口**。
                //
                // 之前这件事散在六个地方（导出、导入、iCloud 开关、上次备份、
                // 立即备份、从 iCloud 恢复），语义还各不相同。用户说不清自己
                // 的数据在哪儿，我们自己排查时也要在三处各看一遍。
                // 现在全部收进「备份与恢复」，见 `BackupView`。
                Section {
                    LabeledContent {
                        Text("\(records.count) 条")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        row("tray.full.fill", .orange, "本机记录")
                    }

                    NavigationLink {
                        BackupView()
                    } label: {
                        row("externaldrive.fill.badge.icloud", .blue, "备份与恢复")
                    }

                    Button(role: .destructive) {
                        isClearConfirmPresented = true
                    } label: {
                        row("trash.fill", .red, "清空全部记录", tint: .red)
                    }
                } header: {
                    Text("数据")
                } footer: {
                    Text(backupFooter)
                }

                Section {
                    Toggle(isOn: $settings.debugVision) {
                        row("ruler.fill", .teal, "识别调试图")
                    }
                } header: {
                    Text("扫描识别")
                } footer: {
                    Text("打开后，扫描的复核页会多出一张标注图：绿线是票面上找到的基准（号码区上下那两条虚线），蓝框是配准后的号码区，粉格是每一个号码格子。号码认错时截这张图，就能看出是基准找歪了还是格子划错了。平时不用打开。")
                }

                Section {
                    NavigationLink {
                        PrizeTableView()
                    } label: {
                        row("tablecells", .indigo, "奖级对照表")
                    }
                } header: {
                    Text("彩种资料")
                } footer: {
                    Text("各彩种的中奖条件与单注奖金，整理自官方公布的游戏规则，仅供参考。")
                }

                Section {
                    LabeledContent {
                        Text("\(AppInfo.version) (\(AppInfo.build))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        row("app.badge.fill", .purple, "版本")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        row("info.circle.fill", .gray, "关于与免责声明")
                    }
                }
            }
            // 导航栏不要自己糊底色，交给系统的 scroll edge effect。
            // 理由见 `HomeView` 里同一处那段注释。
            .navigationTitle("设置")
            .confirmationDialog("清空全部记录？", isPresented: $isClearConfirmPresented, titleVisibility: .visible) {
                Button("清空", role: .destructive) { clearAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("\(records.count) 条记录会被永久删除。建议先去「备份与恢复」存一份。")
            }
        }
    }

    /// 系统「设置」那种彩色圆角图标 + 文字。
    private func row(_ symbol: String, _ color: Color, _ title: String, tint: Color = .primary) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, tint: color)
            Text(title).foregroundStyle(tint)
        }
    }

    private var backupFooter: String {
        guard let days = settings.daysSinceBackup else {
            return "记录保存在这台设备上。进「备份与恢复」存一份，换设备时才带得走。"
        }
        if days >= 7 {
            return "上次备份是 \(days) 天前，建议再存一份。"
        }
        return "上次备份：\(days) 天前。"
    }

    // MARK: - 动作

    private func refreshData() {
        Task {
            isRefreshing = true
            await drawStore.refresh()
            await drawStore.loadAllHistories()
            isRefreshing = false
            showToast("数据状态已更新")
        }
    }

    private func clearAll() {
        do {
            try RecordService(context: context, drawStore: drawStore).deleteAll()
            showToast("已清空全部记录", symbol: "trash", feedback: .success)
        } catch {
            showToast("清空失败", symbol: "exclamationmark.triangle", feedback: .error)
        }
    }
}

struct AboutView: View {
    static let privacyURL = URL(string: "https://wenjinliuu.github.io/lottery-ios/")!
    static let supportURL = URL(string: "https://wenjinliuu.github.io/lottery-ios/support.html")!

    private func linkRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 20)
            Text(title)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("对个号")
                    .font(.largeTitle.weight(.bold))
                Text("本地优先的实体彩票票据记录与核对工具。所有票据只保存在这台设备上，不上传服务器，也没有账号体系。")
                Divider()
                Text("免责声明")
                    .font(.headline)
                Text("本应用仅用于记录和核对您已持有的实体彩票，不销售、不代购、不提供兑奖服务。开奖结果以官方渠道公布为准。购彩请通过当地合法、正规的线下彩票销售渠道，并理性参与、量力而行。")
                Text("开奖数据")
                    .font(.headline)
                Text("开奖号码与开奖日历读取自公开数据仓库 lottery-data-repo，应用只做只读访问。彩票照片的号码识别全部在本机完成，照片不会离开设备，也不会被保存。")

                Divider()
                // 隐私政策要能在 App 内点得到 —— 这是审核明确看的一项，
                // 只写在 App Store 商店页上是不够的。技术支持同理。
                Text("更多")
                    .font(.headline)
                Link(destination: AboutView.privacyURL) {
                    linkRow("隐私政策", systemImage: "hand.raised")
                }
                Link(destination: AboutView.supportURL) {
                    linkRow("技术支持与常见问题", systemImage: "questionmark.circle")
                }
                Text("以上两个链接会在浏览器中打开，页面为纯静态内容，不会收集任何信息。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(20)
        }
        .background(Palette.canvas)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
