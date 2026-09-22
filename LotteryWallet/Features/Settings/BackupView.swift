import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

/// 备份与恢复。**这是备份唯一的入口。**
///
/// 之前这件事散在设置页的六个地方：导出备份、导入备份、iCloud 备份开关、
/// 上次备份、立即备份、从 iCloud 恢复，外加一个「管理备份」子页。
/// 同一件事六个入口、三种语义，用户根本说不清自己的数据在哪儿、
/// 哪一次点击会覆盖什么。
///
/// 现在只有一句话：**备份是一份带时间戳的快照，它躺在 iCloud 或者本机。**
/// 列表里每一份都标着来源和时间；点一下恢复，划一下删除，长按分享出去。
/// 外面来的文件走「从文件导入」，进来之后和其它备份没有任何区别。
struct BackupView: View {
    @Environment(\.modelContext) private var context
    @Environment(DrawStore.self) private var drawStore
    @Environment(AppSettings.self) private var settings
    @Environment(BackupCenter.self) private var center
    @Environment(StoreHealth.self) private var storeHealth
    @Environment(ToastCenter.self) private var showToast
    @Environment(CelebrationCenter.self) private var celebrate
    @Query private var records: [TicketRecord]

    @State private var isBusy = false
    @State private var busyLabel = ""
    @State private var restoreTarget: BackupItem?
    @State private var deleteTarget: BackupItem?
    @State private var isImporting = false
    @State private var isExporting = false
    /// 导出用的文件。**点「导出」时才生成**，而不是每次 body 求值都序列化
    /// 一遍全部记录 —— 几百条记录编码一次不便宜，而导出是很少点的操作。
    @State private var exportDocument: BackupDocument?
    @State private var isClearConfirmPresented = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            if !storeHealth.isHealthy { storeWarning }

            Section {
                Toggle(isOn: $settings.autoBackupEnabled) {
                    row("clock.arrow.circlepath", .blue, "自动备份")
                }
                Toggle(isOn: Binding(get: { settings.iCloudBackupEnabled },
                                     set: { toggleICloud($0) })) {
                    row("icloud.fill", .cyan, "存到 iCloud")
                }
            } header: {
                Text("自动")
            } footer: {
                Text(autoFooter)
            }

            Section {
                Button { createSnapshot() } label: {
                    row("plus.circle.fill", .green, "立即备份")
                }
                .disabled(isBusy || records.isEmpty)

                // 「导出」和「立即备份」不是一回事，两个都得有。
                //
                // 立即备份写进 App 自己管的那个列表（iCloud 或沙盒），
                // 归 App 管、也归 App 删；导出是**把文件交出去** ——
                // 存到「文件」、发给自己、丢进网盘，从此和 App 无关。
                // 换手机、卸载重装、想留个长期存档，靠的是后者。
                Button { startExport() } label: {
                    row("square.and.arrow.up.fill", .indigo, "导出数据…")
                }
                .disabled(isBusy || records.isEmpty)

                Button { isImporting = true } label: {
                    row("square.and.arrow.down.fill", .orange, "从文件导入…")
                }
                .disabled(isBusy)
            } footer: {
                Text(records.isEmpty
                     ? "现在没有记录可以备份。"
                     : "现在有 \(records.count) 条记录。手动备份永远不会被自动清理。导出的文件由你自己保管，和这里的备份列表互不影响，任何时候都能用「从文件导入」读回来。")
            }

            Section {
                if center.isLoading && center.items.isEmpty {
                    HStack {
                        ProgressView()
                        Text("正在读取…").foregroundStyle(.secondary)
                    }
                } else if center.items.isEmpty {
                    Text("还没有任何备份")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(center.items) { item in
                        backupRow(item)
                    }
                }
            } header: {
                Text("全部备份")
            } footer: {
                Text(listFooter)
            }

            // 清空全部记录放在这一页，紧挨着备份列表。
            //
            // 它是**备份的反面**：唯一一个会让数据永久消失的按钮。放在设置页
            // 的列表里，用户点它的时候看不到自己有没有备份；放在这儿，
            // 上面那几行就是他的后路，点之前一眼看得见。
            Section {
                Button(role: .destructive) {
                    isClearConfirmPresented = true
                } label: {
                    row("trash.fill", .red, "清空全部记录")
                }
                .disabled(isBusy || records.isEmpty)
            } footer: {
                Text(records.isEmpty
                     ? "现在没有记录。"
                     : "会把这台设备上的 \(records.count) 条记录全部删除。上面列出的备份不受影响，清空之后仍然可以从它们恢复。")
            }

            // 诊断**不藏**。上一版把它放在一个只有 iCloud 开关打开才出现的
            // 子页里，于是恰恰在开关打不开的时候，用来查原因的东西也不见了。
            Section {
                Text(diagnostic)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = diagnostic
                    showToast("已复制诊断信息", symbol: "doc.on.doc", feedback: .success)
                } label: {
                    Label("复制诊断信息", systemImage: "doc.on.doc")
                }
            } header: {
                Text("诊断")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isBusy)
        .overlay { if isBusy { busyOverlay } }
        .task { await center.reload() }
        .refreshable { await center.reload() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { handleFileImport($0) }
        .fileExporter(isPresented: $isExporting,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: BackupNaming.name(for: .manual)) { result in
            switch result {
            case .success:
                showToast("已导出", symbol: "square.and.arrow.up", feedback: .success)
            case .failure(let error):
                // 用户自己取消不算失败，`fileExporter` 会给一个 cancelled 错误。
                if (error as NSError).code != NSUserCancelledError {
                    showToast(error.localizedDescription, symbol: "exclamationmark.triangle", feedback: .error)
                }
            }
            exportDocument = nil
        }
        .confirmationDialog("从这份备份恢复？", isPresented: .init(
            get: { restoreTarget != nil },
            set: { if !$0 { restoreTarget = nil } }
        ), titleVisibility: .visible, presenting: restoreTarget) { item in
            Button("恢复") { restore(item) }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text("会把这份备份里的记录合并进来：同一条记录以备份为准，本机多出来的不会被删掉。\n\n恢复前会先把当前状态存成一份「恢复前快照」，后悔了可以退回去。\n\n备份时间：\(DateText.stamp(item.modifiedAt))")
        }
        .confirmationDialog("清空全部记录？", isPresented: $isClearConfirmPresented,
                            titleVisibility: .visible) {
            Button("清空", role: .destructive) { clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(records.count) 条记录会被永久删除，无法撤销。建议先在上面「立即备份」存一份。")
        }
        .confirmationDialog("删除这份备份？", isPresented: .init(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible, presenting: deleteTarget) { item in
            Button("删除", role: .destructive) { delete(item) }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text("会从\(item.location.label)永久删除这个文件，无法恢复。本机的记录不受影响。")
        }
    }

    // MARK: - 片段

    private var storeWarning: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("数据库打不开，现在是临时模式")
                        .font(.subheadline.weight(.semibold))
                    Text("现在录入或导入的内容关掉应用就会消失。请先把下面的诊断信息发给开发者，不要在这个状态下继续录入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warning)
            }
        }
    }

    private func backupRow(_ item: BackupItem) -> some View {
        Button {
            restoreTarget = item
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.kind.symbol)
                    .font(.footnote)
                    .foregroundStyle(item.kind == .manual ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DateText.stamp(item.modifiedAt))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(subtitle(item))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: item.location.symbol)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteTarget = item } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            if let url = center.fileURL(for: item) {
                ShareLink(item: url) { Label("分享这份备份", systemImage: "square.and.arrow.up") }
            }
        }
        .accessibilityLabel("\(item.kind.label)，\(subtitle(item))，点按可恢复")
    }

    private func subtitle(_ item: BackupItem) -> String {
        [item.kind.label,
         item.location.label,
         ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)]
            .joined(separator: " · ")
    }

    private var autoFooter: String {
        var text = settings.autoBackupEnabled
            ? "每次退到后台、且记录有过变化时自动存一份，**只保留最新的一份**，新的覆盖旧的。想长期留着某一份，用「立即备份」或「导出数据」——那两种永远不会被自动清理。"
            : "关掉之后不再自动备份。手动备份和导出不受影响。"
        text += settings.iCloudBackupEnabled
            ? "\n\n备份优先写进你自己的 iCloud 云盘（「文件」App 里的「对个号」文件夹）；iCloud 用不了时自动落到本机，不会因此漏掉一次备份。"
            : "\n\n备份只存在这台设备上，不会离开手机。打开上面那个开关才会同时放一份到你自己的 iCloud。"
        if let issue = center.cloudIssue, settings.iCloudBackupEnabled {
            text += "\n\niCloud 现在用不了：\(issue)"
        }
        return text
    }

    private var listFooter: String {
        var text = "点一下恢复，向左滑删除，长按可以分享出去。"
        if center.items.contains(where: { $0.kind == .safety }) {
            text += "\n「恢复前快照」是每次恢复之前自动存的当前状态，保留最近 \(BackupPolicy.safetyKeep) 份。"
        }
        return text
    }

    private var diagnostic: String {
        storeHealth.summary(recordCount: records.count)
            + "\n\n" + ICloudBackupService.diagnosticSummary()
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView()
                Text(busyLabel).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// 和设置页同一种行：彩色圆角图标 + 文字。两处长得不一样会很突兀。
    private func row(_ symbol: String, _ tint: Color, _ title: String) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, tint: tint)
            Text(title).foregroundStyle(.primary)
        }
    }

    // MARK: - 动作

    /// 打开 iCloud 开关前先探一下真的能用，不能用就说清卡在哪一环。
    ///
    /// 不探的话，用户没登录 iCloud 也能把开关拨开，然后一直以为自己的备份
    /// 在云上 —— 直到换手机那天才发现什么都没有。
    private func toggleICloud(_ isOn: Bool) {
        guard isOn else {
            settings.iCloudBackupEnabled = false
            return
        }
        Task {
            // 这一串会阻塞（首次还会等容器就绪），不能放主线程。
            let failure = await Task.detached { ICloudBackupService.availability() }.value
            if let failure {
                showToast(failure.localizedDescription, symbol: "icloud.slash", feedback: .error)
                await center.reload()
                return
            }
            settings.iCloudBackupEnabled = true
            await center.reload()
        }
    }

    /// 把当前全部记录导成一个 JSON 文件交给用户。
    ///
    /// 用的是**和备份完全同一份数据**（`BackupService.exportData`），
    /// 所以导出去的文件可以原样从「从文件导入」读回来。两套格式是绝对
    /// 不能有的事 —— 用户手里那个文件，将来必须还认得。
    private func startExport() {
        guard let data = try? BackupService(context: context).exportData(records: records) else {
            showToast("生成导出文件失败", symbol: "exclamationmark.triangle", feedback: .error)
            return
        }
        exportDocument = BackupDocument(data: data)
        isExporting = true
    }

    private func createSnapshot() {
        guard let data = try? BackupService(context: context).exportData(records: records) else {
            showToast("生成备份失败", symbol: "exclamationmark.triangle", feedback: .error)
            return
        }
        Task {
            isBusy = true
            busyLabel = "正在写入…"
            defer { isBusy = false }
            do {
                let location = try await center.create(
                    kind: .manual,
                    data: data,
                    preferring: settings.iCloudBackupEnabled ? .iCloud : .local)
                settings.lastBackupAt = Date()
                showToast("已备份到\(location.label)", symbol: "checkmark.seal.fill", feedback: .success)
            } catch {
                showToast(error.localizedDescription, symbol: "exclamationmark.triangle", feedback: .error)
            }
        }
    }

    /// 清空全部记录。**不自动备份** —— 用户点的是「清空」，
    /// 替他决定先存一份是越权；上面那一行文案已经把后路说清楚了。
    private func clearAll() {
        do {
            try RecordService(context: context, drawStore: drawStore).deleteAll()
            showToast("已清空全部记录", symbol: "trash", feedback: .success)
        } catch {
            showToast("清空失败", symbol: "exclamationmark.triangle", feedback: .error)
        }
    }

    private func delete(_ item: BackupItem) {
        Task {
            do {
                try await center.delete(item)
                showToast("已删除", symbol: "trash", feedback: .success)
            } catch {
                showToast(error.localizedDescription, symbol: "exclamationmark.triangle", feedback: .error)
            }
        }
    }

    private func restore(_ item: BackupItem) {
        Task {
            isBusy = true
            busyLabel = "正在读取备份…"
            defer { isBusy = false }
            do {
                let outcome = try await center.restore(item, records: records, context: context)
                await finishImport(outcome)
            } catch {
                showToast(error.localizedDescription, symbol: "exclamationmark.triangle", feedback: .error)
            }
        }
    }

    /// 外面来的 JSON。进来之后和任何一份备份没有区别，走的是同一条恢复路径。
    private func handleFileImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            showToast("导入取消", symbol: "xmark.circle")
            return
        }
        Task {
            isBusy = true
            busyLabel = "正在导入…"
            defer { isBusy = false }

            let needsRelease = url.startAccessingSecurityScopedResource()
            defer { if needsRelease { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                // 外来文件也要先留一份「恢复前快照」—— 它和恢复一样会覆盖。
                if !records.isEmpty,
                   let current = try? BackupService(context: context).exportData(records: records) {
                    _ = try? await center.create(kind: .safety, data: current, preferring: .local)
                }
                let outcome = try BackupService(context: context).importData(data)
                await finishImport(outcome)
            } catch {
                showToast(error.localizedDescription, symbol: "exclamationmark.triangle", feedback: .error)
            }
        }
    }

    /// 导入落库之后的收尾：核对 + 提示。两条路径共用，语义不能有第二套。
    private func finishImport(_ outcome: (inserted: Int, updated: Int)) async {
        busyLabel = "正在核对开奖…"
        await Task.yield()
        let service = RecordService(context: context, drawStore: drawStore)
        // 恢复进来的老票绑的是几个月甚至几年前的期号，按需补那几年，
        // 再补一次还差的彩种最近 30 期。两步都只取真正要用的 ——
        // 不再像上一版那样把八个彩种一次拉满。
        await drawStore.loadArchives(service.archivesNeedingMatchRepair())
        await drawStore.ensureRecentDraws(for: service.gamesAwaitingDraws())
        _ = try? service.reconcileInferredTargets()
        let checked = try? service.checkAll()
        await center.reload()
        showToast("已恢复 \(outcome.inserted + outcome.updated) 条记录",
                  symbol: "checkmark.seal.fill", feedback: .success)
        if let checked, checked.won > 0 { celebrate() }
    }
}
