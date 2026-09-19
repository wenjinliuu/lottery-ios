import SwiftUI
import SwiftData
import UIKit

/// iCloud 备份管理。
///
/// 原来只有一个开关和一颗「立即备份」，用户看不到云上到底有什么、
/// 也删不掉。这一页把云端那几个文件如实列出来：哪份是自动的、
/// 哪份是自己存的、各自多大多久以前 —— 然后才谈得上「管理」。
///
/// 恢复和删除都走确认，且恢复复用「导入备份」那条路（合并不覆盖），
/// 和本地导入是同一套语义，不另发明一种。
struct BackupManagerView: View {
    @Environment(\.modelContext) private var context
    @Environment(DrawStore.self) private var drawStore
    @Environment(AppSettings.self) private var settings
    @Environment(ToastCenter.self) private var showToast
    @Environment(CelebrationCenter.self) private var celebrate
    @Query private var records: [TicketRecord]

    @State private var files: [ICloudBackupService.BackupFile] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isBusy = false
    @State private var busyLabel = ""
    @State private var restoreTarget: ICloudBackupService.BackupFile?
    @State private var deleteTarget: ICloudBackupService.BackupFile?
    @State private var diagnostic = ""

    var body: some View {
        List {
            Section {
                Button {
                    createSnapshot()
                } label: {
                    Label("新建备份", systemImage: "plus.circle.fill")
                }
                .disabled(isBusy)
            } footer: {
                Text("新建的备份带时间戳，不会覆盖已有的。退到后台时自动写的那一份是固定文件，会反复覆盖。")
            }

            Section {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("正在读取 iCloud…")
                            .foregroundStyle(.secondary)
                    }
                } else if let loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(Palette.warning)
                } else if files.isEmpty {
                    Text("云端还没有备份")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(files) { file in
                        row(file)
                    }
                }
            } header: {
                Text("iCloud 上的备份")
            } footer: {
                if !files.isEmpty {
                    Text("向左滑可以删除。删除只影响 iCloud 上的文件，本机记录不受影响。")
                }
            }

            // iCloud 用不了的时候，这三行说清卡在哪一环。
            //
            // 「权限」缺失 = 安装包的问题，用户怎么试都没用；
            // 「账户」未登录 = 去系统设置登录；
            // 「容器」拿不到但前两项都正常 = iCloud 云盘被关掉了。
            // 上一版把这三种混成一句「正在准备，请稍等」，于是只能一直重试。
            Section {
                Text(diagnostic.isEmpty ? "正在检测…" : diagnostic)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Button {
                    UIPasteboard.general.string = diagnostic
                    showToast("已复制诊断信息", symbol: "doc.on.doc", feedback: .success)
                } label: {
                    Label("复制诊断信息", systemImage: "doc.on.doc")
                }
                .disabled(diagnostic.isEmpty)
            } header: {
                Text("诊断")
            } footer: {
                Text("iCloud 用不了时，把这几行发给开发者最省事。")
            }
        }
        .navigationTitle("管理备份")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isBusy)
        .overlay { if isBusy { busyOverlay } }
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog("从这份备份恢复？", isPresented: .init(
            get: { restoreTarget != nil },
            set: { if !$0 { restoreTarget = nil } }
        ), titleVisibility: .visible, presenting: restoreTarget) { file in
            Button("恢复") { restore(file) }
            Button("取消", role: .cancel) {}
        } message: { file in
            Text("会把这份备份里的记录合并进来。已有的同一条记录会被备份里的版本覆盖，本机多出来的记录不会被删掉。\n\n备份时间：\(DateText.friendly(DateText.day(file.modifiedAt)))")
        }
        .confirmationDialog("删除这份备份？", isPresented: .init(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible, presenting: deleteTarget) { file in
            Button("删除", role: .destructive) { delete(file) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("会从 iCloud 上永久删除这个文件，无法恢复。本机的记录不受影响。")
        }
    }

    // MARK: - 一行

    private func row(_ file: ICloudBackupService.BackupFile) -> some View {
        Button {
            restoreTarget = file
        } label: {
            HStack(spacing: 12) {
                Image(systemName: file.isAuto ? "arrow.triangle.2.circlepath" : "doc.fill")
                    .font(.footnote)
                    .foregroundStyle(file.isAuto ? Color.secondary : Color.accentColor)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.isAuto ? "自动备份" : DateText.friendly(DateText.day(file.modifiedAt)))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(subtitle(file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.down.circle")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteTarget = file } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(file.isAuto ? "自动备份" : "备份")，\(subtitle(file))，点按可恢复")
    }

    private func subtitle(_ file: ICloudBackupService.BackupFile) -> String {
        var parts: [String] = []
        if file.isAuto { parts.append(DateText.friendly(DateText.day(file.modifiedAt))) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
        return parts.joined(separator: " · ")
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

    // MARK: - 动作

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        diagnostic = await Task.detached { ICloudBackupService.diagnosticSummary() }.value
        do {
            files = try await Task.detached { try ICloudBackupService.list() }.value
            loadError = nil
        } catch {
            files = []
            loadError = error.localizedDescription
        }
    }

    private func createSnapshot() {
        guard let data = try? BackupService(context: context).exportData(records: records) else {
            showToast("生成备份失败", symbol: "exclamationmark.triangle", feedback: .error)
            return
        }
        Task {
            isBusy = true
            busyLabel = "正在写入 iCloud…"
            defer { isBusy = false }
            let name = ICloudBackupService.snapshotName()
            do {
                try await Task.detached { try ICloudBackupService.write(data, named: name) }.value
                settings.lastICloudBackupAt = Date()
                showToast("已新建备份", symbol: "icloud.and.arrow.up", feedback: .success)
                await reload()
            } catch {
                showToast(error.localizedDescription, symbol: "icloud.slash", feedback: .error)
            }
        }
    }

    private func delete(_ file: ICloudBackupService.BackupFile) {
        Task {
            do {
                try await Task.detached { try ICloudBackupService.delete(file) }.value
                showToast("已删除", symbol: "trash", feedback: .success)
                await reload()
            } catch {
                showToast(error.localizedDescription, symbol: "icloud.slash", feedback: .error)
            }
        }
    }

    /// 恢复。和「导入备份」「从 iCloud 恢复」走的是同一条路，只是数据来源不同。
    private func restore(_ file: ICloudBackupService.BackupFile) {
        Task {
            isBusy = true
            busyLabel = "正在从 iCloud 读取…"
            defer { isBusy = false }
            do {
                let data = try await Task.detached { try ICloudBackupService.read(file) }.value
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
}
