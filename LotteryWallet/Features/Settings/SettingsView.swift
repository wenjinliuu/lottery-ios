import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DrawStore.self) private var drawStore
    @Environment(\.modelContext) private var context
    @Environment(\.showToast) private var showToast
    @Query private var records: [TicketRecord]

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: BackupDocument?
    @State private var isClearConfirmPresented = false
    @State private var isRefreshing = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("核对") {
                    Toggle(isOn: $settings.autoCheck) {
                        Label("开奖后自动核对", systemImage: "checkmark.circle")
                    }
                    Text("开启后，每次打开应用并拿到新开奖数据时自动核对待开奖的票据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("外观") {
                    Picker(selection: $settings.appearance) {
                        ForEach(AppSettings.Appearance.allCases) { item in
                            Label(item.label, systemImage: item.symbol).tag(item)
                        }
                    } label: {
                        Label("主题", systemImage: "paintbrush")
                    }
                }

                Section {
                    LabeledContent {
                        Text(drawStore.latestUpdatedAt.isEmpty ? "暂无" : DateText.friendly(drawStore.latestUpdatedAt))
                            .font(.caption)
                    } label: {
                        Label("开奖数据", systemImage: "arrow.down.circle")
                    }

                    LabeledContent {
                        Text(drawStore.calendar == nil ? "未获取" : "正常")
                            .font(.caption)
                            .foregroundStyle(drawStore.calendar == nil ? .orange : .secondary)
                    } label: {
                        Label("开奖日历", systemImage: "calendar")
                    }

                    LabeledContent {
                        Text("\(drawStore.loadedHistoryGames.count)/\(GameKey.ordered.count) 个彩种")
                            .font(.caption)
                    } label: {
                        Label("往期缓存", systemImage: "externaldrive")
                    }

                    Button {
                        Task {
                            isRefreshing = true
                            await drawStore.refresh()
                            await drawStore.loadAllHistories()
                            isRefreshing = false
                            showToast("数据状态已更新")
                        }
                    } label: {
                        HStack {
                            Label("刷新开奖数据", systemImage: "arrow.clockwise")
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
                    } label: {
                        Label("本机记录", systemImage: "tray.full")
                    }

                    Button {
                        export()
                    } label: {
                        Label("导出备份", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        isImporting = true
                    } label: {
                        Label("导入备份", systemImage: "square.and.arrow.down")
                    }

                    Button(role: .destructive) {
                        isClearConfirmPresented = true
                    } label: {
                        Label("清空全部记录", systemImage: "trash")
                    }
                } header: {
                    Text("数据备份")
                } footer: {
                    Text(backupFooter)
                }

                Section {
                    LabeledContent("版本", value: "\(AppInfo.version) (\(AppInfo.build))")
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于与免责声明", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("设置")
            .scrollEdgeEffectStyle(.soft, for: .top)
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: BackupService.suggestedFileName()
            ) { result in
                switch result {
                case .success:
                    settings.lastBackupAt = Date()
                    showToast("备份已保存", symbol: "square.and.arrow.up")
                case .failure:
                    showToast("导出取消或失败", symbol: "exclamationmark.triangle")
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

    private func export() {
        let service = BackupService(context: context)
        guard let data = try? service.exportData(records: records) else {
            showToast("生成备份失败", symbol: "exclamationmark.triangle")
            return
        }
        exportDocument = BackupDocument(data: data)
        isExporting = true
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            showToast("导入取消", symbol: "xmark.circle")
            return
        }
        let needsRelease = url.startAccessingSecurityScopedResource()
        defer { if needsRelease { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let service = BackupService(context: context)
            let outcome = try service.importData(data, existing: records)
            // 导入后立刻按本地开奖数据重新核对一遍
            _ = try? RecordService(context: context, drawStore: drawStore).checkAll()
            showToast("已导入 \(outcome.inserted + outcome.updated) 条记录", symbol: "square.and.arrow.down")
        } catch {
            showToast(error.localizedDescription, symbol: "exclamationmark.triangle")
        }
    }

    private func clearAll() {
        do {
            try RecordService(context: context, drawStore: drawStore).deleteAll()
            showToast("已清空全部记录", symbol: "trash")
        } catch {
            showToast("清空失败", symbol: "exclamationmark.triangle")
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("彩票夹")
                    .font(.largeTitle.weight(.bold))
                Text("本地优先的彩票记录与核对工具。所有票据只保存在这台设备上，不上传服务器，也没有账号体系。")
                Divider()
                Text("免责声明")
                    .font(.headline)
                Text("本应用仅用于记录和辅助核对已经购买的彩票，不销售、不代购、不提供兑奖服务。开奖结果以官方渠道公布为准。如需购买，请通过当地合法、正规的线下彩票销售渠道，并理性参与、量力而行。")
                Text("开奖数据")
                    .font(.headline)
                Text("开奖号码与开奖日历读取自公开数据仓库 lottery-data-repo，应用只做只读访问。彩票照片的号码识别全部在本机完成，照片不会离开设备，也不会被保存。")
            }
            .font(.subheadline)
            .padding(20)
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
