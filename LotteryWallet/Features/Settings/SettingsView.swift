import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DrawStore.self) private var drawStore
    @Query private var records: [TicketRecord]

    @State private var isRefreshing = false
    private var push: DrawPushCenter { DrawPushCenter.shared }

    /// 开关的状态以 `DrawPushCenter` 为准：系统授权被拒时它自己会弹回关。
    private var pushBinding: Binding<Bool> {
        Binding(get: { push.isEnabled },
                set: { isOn in Task { if isOn { await push.enable() } else { await push.disable() } } })
    }


    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    settingsSection(footer: "每次打开应用并拿到新开奖数据时，自动核对待开奖的票据。") {
                        Toggle(isOn: $settings.autoCheck) {
                            row("checkmark.circle.fill", .green, "开奖后自动核对")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    settingsSection(footer: "票夹有待开奖的票据时，由手机核对并提醒结果。票据不会上传。") {
                        Toggle(isOn: pushBinding) {
                            HStack(spacing: 8) {
                                row("bell.badge.fill", .red, "开奖通知")
                                Spacer(minLength: 8)
                                if push.status != .off {
                                    Text(push.status.label)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    settingsSection {
                        HStack(spacing: 12) {
                            row("circle.lefthalf.filled", .indigo, "外观")
                            Spacer(minLength: 8)
                            Menu {
                                ForEach(AppSettings.Appearance.allCases) { item in
                                    Button {
                                        settings.appearance = item
                                    } label: {
                                        if settings.appearance == item {
                                            Label(item.label, systemImage: "checkmark")
                                        } else {
                                            Label(item.label, systemImage: item.symbol)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: settings.appearance.symbol)
                                        .font(.caption.weight(.semibold))
                                    Text(settings.appearance.label)
                                        .font(.subheadline.weight(.medium))
                                    Image(systemName: "chevron.up.chevron.down")
                                        .scaledFont(9, weight: .bold)
                                        .foregroundStyle(.secondary)
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .glassPill(interactive: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                    }

                    // 数据只有一组，四行：数据状态、本机记录、刷新开奖数据、备份与恢复。
                    settingsSection(header: "数据", footer: backupFooter) {
                        NavigationLink {
                            DrawDataView()
                        } label: {
                            HStack(spacing: 10) {
                                row("checkmark.seal.fill", .blue, "数据状态")
                                Spacer(minLength: 8)
                                Text(statusSummary)
                                    .font(.footnote)
                                    .foregroundStyle(statusTint)
                                    .multilineTextAlignment(.trailing)
                                chevron
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        rowDivider

                        HStack(spacing: 10) {
                            row("tray.full.fill", .orange, "本机记录")
                            Spacer(minLength: 8)
                            Text("\(records.count) 条")
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)

                        rowDivider

                        Button {
                            refresh()
                        } label: {
                            HStack(spacing: 10) {
                                row("arrow.clockwise.circle.fill", .teal, "刷新开奖数据")
                                Spacer(minLength: 8)
                                if isRefreshing { ProgressView() }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isRefreshing)

                        rowDivider

                        NavigationLink {
                            BackupView()
                        } label: {
                            HStack(spacing: 10) {
                                row("externaldrive.fill.badge.icloud", .blue, "备份与恢复")
                                Spacer(minLength: 8)
                                chevron
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    settingsSection(
                        header: "扫描识别",
                        footer: "打开后，扫描的复核页会多出一张标注图：绿线是票面上找到的基准（号码区上下那两条虚线），蓝框是配准后的号码区，粉格是每一个号码格子。号码认错时截这张图，就能看出是基准找歪了还是格子划错了。平时不用打开。"
                    ) {
                        Toggle(isOn: $settings.debugVision) {
                            row("ruler.fill", .teal, "识别调试图")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    settingsSection {
                        HStack(spacing: 10) {
                            row("app.badge.fill", .purple, "版本")
                            Spacer(minLength: 8)
                            Text("\(AppInfo.version) (\(AppInfo.build))")
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)

                        rowDivider

                        NavigationLink {
                            AboutView()
                        } label: {
                            HStack(spacing: 10) {
                                row("info.circle.fill", .gray, "关于与免责声明")
                                Spacer(minLength: 8)
                                chevron
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 112)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(Palette.canvas)
            .navigationTitle("设置")
            .task { await drawStore.loadStatus() }
        }
    }

    private func settingsSection<Content: View>(header: String? = nil,
                                                footer: String? = nil,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            VStack(spacing: 0) {
                content()
            }
            .contentCard(cornerRadius: 20, padding: 0)
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
            }
        }
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 57)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    /// 设置页那一行的状态文案。
    ///
    /// 取数失败时**不显示失败**，而是继续显示上一次成功读到的那份 ——
    /// 契约就是这么定的。真的一次都没读到才说「暂无执行记录」。
    private var statusSummary: String {
        if let status = drawStore.fetchStatus { return status.summary }
        return drawStore.statusState.isLoading ? "读取中…" : "暂无执行记录"
    }

    /// 只有**执行失败**才标黄。
    ///
    /// 数据没齐（6/8）不标 —— 今天还没开奖的彩种本来就该是 waiting，
    /// 把它画成警告，用户每天都会看到一次假警报。
    private var statusTint: Color {
        drawStore.fetchStatus?.needsAttention == true ? Palette.warning : .secondary
    }

    /// 重新取各彩种的最新一期与开奖日程，并刷新**已经看过的**那些彩种的往期。
    /// 没打开过的彩种不会顺带下载 —— 那正是这次迁移省掉的部分。
    private func refresh() {
        Task {
            isRefreshing = true
            defer { isRefreshing = false }
            await drawStore.refresh()
            await drawStore.refreshLoadedRecents()
            await drawStore.loadStatus(force: true)
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
                Text("本地优先的个人票据记录与核对工具，由个人独立开发，与任何彩票发行或销售机构均无关联。所有票据只保存在这台设备上，不上传服务器，也没有账号体系。")
                Divider()
                Text("免责声明")
                    .font(.headline)
                Text("本应用仅用于记录和核对您手里已有的实体票，不销售、不代购，也不处理任何奖金。应用内的开奖信息和核对结果仅供个人参考，一切以实体票为准。请理性、量力而行。")
                Text("开奖数据")
                    .font(.headline)
                Text("开奖号码与开奖日历整理自公开的开奖信息，仅供核对参考。票据照片的号码识别全部在本机完成，照片不会离开设备，也不会被保存。")

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
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Palette.canvas)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
