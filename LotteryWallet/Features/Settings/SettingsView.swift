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
    @State private var isICloudRestoreConfirmPresented = false

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
                    Toggle(isOn: Binding(get: { settings.iCloudBackupEnabled },
                                         set: { toggleICloud($0) })) {
                        row("icloud.fill", .cyan, "iCloud 备份")
                    }

                    if settings.iCloudBackupEnabled {
                        LabeledContent {
                            Text(settings.lastICloudBackupAt.map { DateText.friendly(DateText.day($0)) } ?? "尚未备份")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } label: {
                            row("clock.arrow.circlepath", .gray, "上次备份")
                        }

                        Button { backupToICloud(announce: true) } label: {
                            row("arrow.up.to.line", .blue, "立即备份")
                        }

                        Button { isICloudRestoreConfirmPresented = true } label: {
                            row("arrow.down.to.line", .green, "从 iCloud 恢复")
                        }

                        NavigationLink {
                            BackupManagerView()
                        } label: {
                            row("folder.fill", .indigo, "管理备份")
                        }
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("打开后，每次退到后台时会把一份备份写进你自己的 iCloud 云盘（「文件」App 里的「对个号」文件夹）。备份只存在你的 iCloud 账户里，开发者无法访问。关掉开关不会删除已经备份的文件。")
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
            .confirmationDialog("从 iCloud 恢复？", isPresented: $isICloudRestoreConfirmPresented,
                                titleVisibility: .visible) {
                Button("恢复") { restoreFromICloud() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会把 iCloud 上那份备份里的记录合并进来。已有的同一条记录会被备份里的版本覆盖，本机多出来的记录不会被删掉。")
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

    // MARK: - iCloud

    /// 打开开关时先确认 iCloud 真的能用，再立刻备份一次。
    ///
    /// 不先探一下的话，用户没登录 iCloud 也能把开关拨开，然后一直以为自己
    /// 有备份 —— 直到换手机那天才发现什么都没有。
    private func toggleICloud(_ isOn: Bool) {
        guard isOn else {
            settings.iCloudBackupEnabled = false
            return
        }
        Task {
            // 这一串会阻塞（首次还会重试等容器就绪），不能放主线程。
            let failure = await Task.detached { ICloudBackupService.availability() }.value
            if let failure {
                // 说清是哪一种不可用 —— 「没登录」和「容器还没就绪」
                // 给用户的下一步动作完全不同。
                showToast(failure.localizedDescription, symbol: "icloud.slash", feedback: .error)
                return
            }
            settings.iCloudBackupEnabled = true
            backupToICloud(announce: true)
        }
    }

    /// 写一份到 iCloud。退到后台时也会调这个（见 `RootView`），那种情况不弹提示。
    private func backupToICloud(announce: Bool) {
        let service = BackupService(context: context)
        guard let data = try? service.exportData(records: records) else {
            if announce { showToast("生成备份失败", symbol: "exclamationmark.triangle", feedback: .error) }
            return
        }
        Task {
            do {
                try await Task.detached { try ICloudBackupService.write(data) }.value
                settings.lastICloudBackupAt = Date()
                if announce { showToast("已备份到 iCloud", symbol: "icloud.and.arrow.up", feedback: .success) }
            } catch {
                if announce {
                    showToast(error.localizedDescription, symbol: "icloud.slash", feedback: .error)
                }
            }
        }
    }

    /// 从 iCloud 恢复。走的是和「导入备份」完全相同的那条路，只是数据来源不同。
    private func restoreFromICloud() {
        Task {
            isBusy = true
            busyLabel = "正在从 iCloud 读取…"
            defer { isBusy = false }
            do {
                let data = try await Task.detached { try ICloudBackupService.read() }.value
                busyLabel = "正在导入记录…"
                let outcome = try BackupService(context: context).importData(data)
                await Task.yield()

                busyLabel = "正在核对开奖…"
                await drawStore.loadAllHistories()
                let service = RecordService(context: context, drawStore: drawStore)
                let checked = try? service.checkAll()
                if let checked, checked.won > 0 { celebrate() }
                showToast("已恢复 \(outcome.inserted + outcome.updated) 条记录",
                          symbol: "icloud.and.arrow.down", feedback: .success)
            } catch {
                showToast(error.localizedDescription, symbol: "icloud.slash", feedback: .error)
            }
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
