import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DrawStore.self) private var drawStore
    @Environment(\.modelContext) private var context
    @Environment(\.showToast) private var showToast
    @Environment(\.celebrate) private var celebrate
    @Query private var records: [TicketRecord]

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: BackupDocument?
    @State private var isClearConfirmPresented = false
    @State private var isRefreshing = false
    @State private var isBusy = false
    @State private var busyLabel = ""

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

                Section {
                    LabeledContent {
                        Text("\(records.count) 条")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        row("tray.full.fill", .orange, "本机记录")
                    }

                    Button { export() } label: {
                        row("square.and.arrow.up.fill", .blue, "导出备份")
                    }

                    Button { isImporting = true } label: {
                        row("square.and.arrow.down.fill", .green, "导入备份")
                    }

                    Button(role: .destructive) {
                        isClearConfirmPresented = true
                    } label: {
                        row("trash.fill", .red, "清空全部记录", tint: .red)
                    }
                } header: {
                    Text("数据备份")
                } footer: {
                    Text(backupFooter)
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
            .navigationTitle("设置")
            .disabled(isBusy)
            .overlay { if isBusy { busyOverlay } }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: BackupService.suggestedFileName()
            ) { result in
                switch result {
                case .success:
                    settings.lastBackupAt = Date()
                    showToast("备份已保存", symbol: "square.and.arrow.up", feedback: .success)
                case .failure:
                    showToast("导出取消或失败", symbol: "exclamationmark.triangle", feedback: .error)
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .confirmationDialog("清空全部记录？", isPresented: $isClearConfirmPresented, titleVisibility: .visible) {
                Button("清空", role: .destructive) { clearAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("\(records.count) 条记录会被永久删除。建议先导出备份。")
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

    private var busyOverlay: some View {
        ZStack {
            // 12% 的黑在深色模式下几乎看不出来，用材质两种模式都能压住底下的内容
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(busyLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(busyLabel)
    }

    private var backupFooter: String {
        guard let days = settings.daysSinceBackup else {
            return "记录只保存在本机。换设备前请先导出备份。"
        }
        if days >= 7 {
            return "上次备份是 \(days) 天前，建议重新导出一次。"
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

    private func export() {
        let service = BackupService(context: context)
        guard let data = try? service.exportData(records: records) else {
            showToast("生成备份失败", symbol: "exclamationmark.triangle", feedback: .error)
            return
        }
        exportDocument = BackupDocument(data: data)
        isExporting = true
    }

    /// 导入分两步：先落库，再核对。
    /// 两步都可能很慢，中间让出主线程刷新一次界面，别让用户看到假死。
    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            showToast("导入取消", symbol: "xmark.circle")
            return
        }
        Task {
            isBusy = true
            busyLabel = "正在导入记录…"
            defer { isBusy = false }

            let needsRelease = url.startAccessingSecurityScopedResource()
            defer { if needsRelease { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                let outcome = try BackupService(context: context).importData(data)
                await Task.yield()

                busyLabel = "正在核对开奖…"
                await drawStore.loadAllHistories()
                let service = RecordService(context: context, drawStore: drawStore)
                _ = try? service.reconcileInferredTargets()
                let checked = try? service.checkAll()

                showToast("已导入 \(outcome.inserted + outcome.updated) 条记录", symbol: "square.and.arrow.down", feedback: .success)
                // 导入一份旧备份常常一次核出好几注中奖，值得放一次烟花
                if let checked, checked.won > 0 { celebrate() }
            } catch {
                showToast(error.localizedDescription, symbol: "exclamationmark.triangle", feedback: .error)
            }
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

/// 导出用的文件包装。
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
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
                Text("本地优先的彩票记录与核对工具。所有票据只保存在这台设备上，不上传服务器，也没有账号体系。")
                Divider()
                Text("免责声明")
                    .font(.headline)
                Text("本应用仅用于记录和辅助核对已经购买的彩票，不销售、不代购、不提供兑奖服务。开奖结果以官方渠道公布为准。如需购买，请通过当地合法、正规的线下彩票销售渠道，并理性参与、量力而行。")
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
