import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// 扫描纸质彩票：拍照或选图 → 本机 Vision 识别 → 逐张复核 → 导入票夹。
///
/// 入口是个半屏抽屉，认出票之后自动长到整屏 —— 只是选张照片而已，
/// 没必要一上来就把整个屏幕占满。
struct TicketScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DrawStore.self) private var drawStore
    @Environment(\.showToast) private var showToast
    @Environment(\.celebrate) private var celebrate

    @State private var stage: Stage = .intro
    @State private var detent: PresentationDetent = .medium
    @State private var isCameraPresented = false
    @State private var photoItem: PhotosPickerItem?
    @State private var preview: UIImage?
    @State private var isPhotoZoomPresented = false
    @State private var rawText = ""
    @State private var tickets: [ScannedTicket] = []
    @State private var globalWarnings: [String] = []
    @State private var errorText: String?
    /// 正在改期号 / 改号码的那张票。
    @State private var issuePickerTarget: IssuePickerTarget?
    @State private var zoneEditorTarget: ZoneEditorTarget?

    enum Stage {
        case intro, scanning, review
    }

    /// 一个 ForEach 里挂很多个 `.sheet` 是 SwiftUI 的经典坑（只有最后一个生效），
    /// 所以期号选择器和号码编辑器都提到根视图上，用 item 驱动。
    struct IssuePickerTarget: Identifiable {
        let ticketID: ScannedTicket.ID
        var id: ScannedTicket.ID { ticketID }
    }

    /// 要改哪一块号码。
    ///
    /// 单式票一张可以有好几注（票面上的 A/B/C 行），所以必须带上是**第几注**；
    /// 只带号码区的话，改完只会落到第一注上，其余几注的修正静默丢掉。
    struct ZoneEditorTarget: Identifiable {
        let ticketID: ScannedTicket.ID
        /// 单式票：第几注。复式/胆拖为 nil。
        var lineIndex: Int?
        /// 复式/胆拖：哪个号码区。单式为 nil（一次改一整注）。
        var key: SectionKey?
        var id: String { "\(ticketID)-\(lineIndex.map(String.init) ?? "-")-\(key?.rawValue ?? "-")" }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .intro: intro
                case .scanning: scanning
                case .review: review
                }
            }
            .background(Palette.canvas)
            .navigationTitle(stage == .review ? "核对识别结果" : "扫描彩票")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if stage == .review {
                    ToolbarItem(placement: .primaryAction) {
                        Button("重扫") { reset() }
                    }
                }
            }
            .alert("操作没有完成", isPresented: .init(
                get: { errorText != nil && stage == .review },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        // 抽屉：入口半屏，进复核自动长到整屏
        .presentationDetents(stage == .review ? [.large] : [.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker { image in
                preview = image
                Task { await run(image) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isPhotoZoomPresented) {
            if let preview {
                PhotoZoomView(image: preview)
            }
        }
        .sheet(item: $zoneEditorTarget) { target in
            zoneEditor(target)
        }
        .sheet(item: $issuePickerTarget) { target in
            issuePicker(target)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    errorText = "这张图片读不出来"
                    return
                }
                preview = image
                await run(image)
            }
        }
        .task { await drawStore.loadYearCalendars() }
    }

    // MARK: - 入口

    private var intro: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 6) {
                Text("把整张彩票放进取景框")
                    .font(.headline)
                Text("识别全部在这台设备上完成，照片不上传也不保存。支持双色球和大乐透的单式、复式、胆拖票，一张照片里放几张也能分开认。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Palette.warning)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button("拍摄彩票") { isCameraPresented = true }
                    .buttonStyle(ProminentGlassButton(tint: .accentColor))
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("从相册选择", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .foregroundStyle(Color.accentColor)
                .glassPill(tint: .accentColor)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }

    private var scanning: some View {
        VStack(spacing: 18) {
            Spacer()
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Palette.separator))
            }
            ProgressView()
            Text("正在本机识别号码…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - 复核

    @ViewBuilder
    private var review: some View {
        if tickets.isEmpty {
            ContentUnavailableView("没有识别到彩票", systemImage: "doc.questionmark",
                                   description: Text("请把整张票放进画面，避开反光和折痕，然后重试。"))
                .safeAreaInset(edge: .bottom) {
                    Button("重新扫描") { reset() }
                        .buttonStyle(ProminentGlassButton(tint: .accentColor))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    photoCard
                    ForEach(globalWarnings, id: \.self) { warning in
                        warningRow(warning)
                    }
                    ForEach($tickets) { $ticket in
                        ticketCard($ticket)
                    }
                    rawTextCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .safeAreaInset(edge: .bottom) { importBar }
        }
    }

    /// 原图。识别对不对，最终还是要人拿眼睛跟票面比一遍，
    /// 所以原图必须一直在手边，而且要能放大看清那几行小字。
    @ViewBuilder
    private var photoCard: some View {
        if let preview {
            Button {
                isPhotoZoomPresented = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 150)
                        .clipped()
                    Label("放大核对", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(9)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Palette.separator))
            }
            .buttonStyle(.plain)
        }
    }

    private func warningRow(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(Palette.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard(cornerRadius: 16, padding: 12)
    }

    // MARK: - 单张票

    private func ticketCard(_ ticket: Binding<ScannedTicket>) -> some View {
        let value = ticket.wrappedValue
        let game = value.game
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(game.label)
                    .font(.headline)
                    .foregroundStyle(game.accent.accentColor)
                Text(value.play.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(game.onTint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(game.tint, in: Capsule())
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        tickets.removeAll { $0.id == value.id }
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删掉这张票")
            }

            TicketDivider(tint: game.tint).padding(.vertical, 10)

            numbersEditor(value)

            TicketDivider(tint: game.tint).padding(.vertical, 10)

            issueRow(value)
            optionRows(ticket)

            ForEach(value.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(Palette.warning)
                    .padding(.top, 8)
            }

            HStack {
                Text("\(value.count) 注 × \(value.multiple) 倍\(value.periods > 1 ? " × \(value.periods) 期" : "")")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(MoneyText.format(value.totalCost))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(game.accent.accentColor)
            }
            .padding(.top, 10)
        }
        .contentCard()
    }

    /// 号码。**每一颗球都可以点** —— 点开就是录入页那套选号盘，
    /// 识别错一个号不用整张重扫。
    private func numbersEditor(_ ticket: ScannedTicket) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            switch ticket.play {
            case .single:
                ForEach(Array(ticket.lines.enumerated()), id: \.offset) { index, numbers in
                    Button {
                        zoneEditorTarget = ZoneEditorTarget(ticketID: ticket.id, lineIndex: index)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .leading)
                                .padding(.top, 3)
                            TicketNumbersSnapshotView(game: ticket.game, numbers: numbers.values, size: 26)
                            Spacer(minLength: 0)
                            Image(systemName: "square.and.pencil")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            case .system, .dantuo:
                ForEach(zoneRows(ticket), id: \.label) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.label)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .leading)
                            .padding(.top, 3)
                        if row.values.isEmpty {
                            Text("—").font(.caption).foregroundStyle(.tertiary).padding(.top, 3)
                        } else {
                            BallRowView(values: row.values, color: row.color, size: 26) { _ in
                                zoneEditorTarget = ZoneEditorTarget(ticketID: ticket.id, key: row.key)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Text(ticket.play == .single ? "点一注可以改这一注的号码" : "点号码球可以改这一区")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private struct ZoneRow {
        let key: SectionKey
        let label: String
        let color: BallColor
        let values: [Int]
    }

    /// 复式 / 胆拖按票面的排版分行：红胆 / 红拖 / 蓝复、前区胆 / 前区拖 / 后区胆 / 后区拖。
    private func zoneRows(_ ticket: ScannedTicket) -> [ZoneRow] {
        var rows: [ZoneRow] = []
        for section in ticket.game.sections {
            let selection = ticket.selections[section.key] ?? SectionSelection()
            let base: String
            switch (ticket.game, section.key) {
            case (.ssq, .red): base = "红"
            case (.ssq, .blue): base = "蓝"
            case (.dlt, .front): base = "前区"
            case (.dlt, .back): base = "后区"
            default: base = section.label
            }
            if ticket.play == .dantuo, section.count > 1 {
                rows.append(ZoneRow(key: section.key, label: base + "胆", color: section.color, values: selection.dan))
                rows.append(ZoneRow(key: section.key, label: base + "拖", color: section.color, values: selection.tuo))
            } else {
                let suffix = ticket.game == .ssq ? (selection.selected.count > section.count ? "复" : "单") : ""
                rows.append(ZoneRow(key: section.key, label: base + suffix,
                                    color: section.color, values: selection.selected))
            }
        }
        return rows
    }

    /// 期号。绑的是票面印的那一期，点开从整年开奖日历里挑，
    /// 识别错了也能顺手改对。
    private func issueRow(_ ticket: ScannedTicket) -> some View {
        Button {
            issuePickerTarget = IssuePickerTarget(ticketID: ticket.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .foregroundStyle(ticket.game.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ticket.issue.isEmpty ? "选择期号" : "第 \(ticket.issue) 期")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ticket.issue.isEmpty ? Palette.warning : .primary)
                    Text(issueSubtitle(ticket))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func issuePicker(_ target: IssuePickerTarget) -> some View {
        if let index = tickets.firstIndex(where: { $0.id == target.ticketID }) {
            IssuePickerSheet(game: tickets[index].game, current: tickets[index].issue) { issue in
                guard let index = tickets.firstIndex(where: { $0.id == target.ticketID }) else { return }
                tickets[index].issue = issue.issue
                tickets[index].drawDate = issue.drawDate
            }
        }
    }

    private func issueSubtitle(_ ticket: ScannedTicket) -> String {
        if ticket.periods > 1 {
            let issues = drawStore.issuesFollowing(game: ticket.game, from: ticket.issue, count: ticket.periods)
            if issues.count == ticket.periods, let last = issues.last {
                return "连打 \(ticket.periods) 期，到第 \(last.issue) 期 · 导入时拆成 \(ticket.periods) 张票"
            }
            return "连打 \(ticket.periods) 期 · 后续期号还没从日历里找到"
        }
        if !ticket.drawDate.isEmpty { return "\(DateText.monthDay(ticket.drawDate)) 开奖" }
        return "点按从开奖日历里选"
    }

    @ViewBuilder
    private func optionRows(_ ticket: Binding<ScannedTicket>) -> some View {
        let game = ticket.wrappedValue.game
        VStack(spacing: 4) {
            Stepper("倍数 \(ticket.wrappedValue.multiple)", value: ticket.multiple, in: 1...99)
                .font(.subheadline)
            if game == .dlt {
                Toggle("追加投注（3 元一注）", isOn: ticket.addOn)
                    .font(.subheadline)
                Stepper("连打 \(ticket.wrappedValue.periods) 期", value: ticket.periods, in: 1...20)
                    .font(.subheadline)
            }
        }
        .padding(.top, 6)
        .tint(game.tint)
    }

    private var rawTextCard: some View {
        DisclosureGroup("查看识别原文") {
            Text(rawText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
        .contentCard(cornerRadius: 18)
    }

    // MARK: - 号码编辑

    @ViewBuilder
    private func zoneEditor(_ target: ZoneEditorTarget) -> some View {
        if let index = tickets.firstIndex(where: { $0.id == target.ticketID }) {
            if let lineIndex = target.lineIndex {
                ScanLineEditor(ticket: $tickets[index], lineIndex: lineIndex)
            } else if let key = target.key {
                ScanZoneEditor(ticket: $tickets[index], key: key)
            }
        }
    }

    // MARK: - 底栏

    private var importBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Text("共 \(importCount) 张票 · \(totalLines) 注")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(MoneyText.format(tickets.reduce(0) { $0 + $1.totalCost }))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16)

            Button("加入票夹") { importAll() }
                .buttonStyle(ProminentGlassButton(tint: .accentColor))
                .disabled(!canImport)
                .padding(.horizontal, 16)
        }
        .padding(.bottom, 14)
        .background(.bar)
    }

    /// 追加多期的票导入后是好几张，这里按拆开之后的张数报。
    private var importCount: Int { tickets.reduce(0) { $0 + $1.periods } }
    private var totalLines: Int { tickets.reduce(0) { $0 + $1.count * $1.periods } }
    private var canImport: Bool {
        !tickets.isEmpty && tickets.allSatisfy { $0.count > 0 && !$0.issue.isEmpty }
    }

    // MARK: - 动作

    private func run(_ image: UIImage) async {
        stage = .scanning
        errorText = nil
        do {
            var scanned = try await TicketVisionScanner.scan(image)
            // 单价对不上时把追加标志纠正过来，再把提示重算一遍。
            // 纠正本身必须说出来 —— 单注价格从 2 元变成 3 元是记账口径的变化，
            // 悄悄改掉的话用户看到金额对不上也不知道是哪一步动的。
            for index in scanned.tickets.indices {
                let note = TicketTextParser.reconcileAddOn(&scanned.tickets[index])
                scanned.tickets[index].warnings =
                    (note.map { [$0] } ?? []) + TicketTextParser.validate(scanned.tickets[index])
            }
            rawText = scanned.rawText
            tickets = scanned.tickets
            globalWarnings = scanned.warnings
            stage = .review
            detent = .large
        } catch {
            errorText = error.localizedDescription
            stage = .intro
        }
    }

    private func reset() {
        stage = .intro
        detent = .medium
        preview = nil
        photoItem = nil
        tickets = []
        globalWarnings = []
        rawText = ""
        errorText = nil
    }

    /// 导入。
    ///
    /// 追加多期的票在这里**拆开**：票面上是一张，但它其实是同一组号码连打 N 期，
    /// 每期各自开奖、各自中奖。合成一张记录的话，后面 N-1 期的开奖结果永远对不上。
    /// 拆开之后每张绑一期，金额自然就是票面合计的 1/N。
    private func importAll() {
        let service = RecordService(context: context, drawStore: drawStore)
        var saved = 0
        do {
            for ticket in tickets {
                for target in targets(for: ticket) {
                    let built = ticket.expandedLines.map { numbers -> Ticket in
                        var item = Ticket(numbers: numbers,
                                          playMode: ticket.game == .dlt ? (ticket.addOn ? "add" : "normal") : "",
                                          entryLabel: EntryKind.scan.label)
                        item.addOn = ticket.addOn
                        return item
                    }
                    guard !built.isEmpty else { continue }
                    try service.save(tickets: built,
                                     game: ticket.game,
                                     entryKind: .scan,
                                     price: ticket.unitPrice,
                                     multiple: ticket.multiple,
                                     target: target,
                                     source: "ticket_scan")
                    saved += built.count
                }
            }
            let checked = try? service.checkAll()
            showToast("已导入 \(saved) 注", symbol: "checkmark.seal.fill")
            if let checked, checked.won > 0 { celebrate() }
            dismiss()
        } catch {
            errorText = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 这张票要绑的期次。连打 N 期就返回 N 个。
    private func targets(for ticket: ScannedTicket) -> [DrawTarget] {
        let issues = drawStore.issuesFollowing(game: ticket.game, from: ticket.issue, count: ticket.periods)
        if issues.count == ticket.periods, !issues.isEmpty {
            return issues.map { $0.target(source: "ticket_scan") }
        }
        // 日历里没查到（期号识别错了，或者那一年的日历还没生成）——
        // 至少把票面上印的这一期原样记下来，不要把整张票丢掉。
        var fallback = DrawTarget()
        fallback.expect = ticket.issue
        fallback.openDate = ticket.drawDate
        fallback.status = .review
        fallback.source = "ticket_scan"
        fallback.isAvailable = true
        return [fallback]
    }
}

// MARK: - 号码区编辑

/// 改复式 / 胆拖的一个号码区。直接复用录入页那套选号盘，不另造一套。
private struct ScanZoneEditor: View {
    @Binding var ticket: ScannedTicket
    let key: SectionKey

    @Environment(\.dismiss) private var dismiss
    @Environment(\.showToast) private var showToast
    @State private var selection = SectionSelection()
    @State private var danPicking = true

    private var section: GameSection? { ticket.game.sections.first { $0.key == key } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let section {
                    VStack(alignment: .leading, spacing: 14) {
                        if ticket.play == .dantuo, section.count > 1 {
                            Picker("选号类型", selection: $danPicking) {
                                Text("选胆码").tag(true)
                                Text("选拖码").tag(false)
                            }
                            .pickerStyle(.segmented)
                        }
                        NumberPadSection(section: section,
                                         selection: $selection,
                                         required: section.count,
                                         mode: ticket.play.entryMode,
                                         danPicking: danPicking,
                                         onReject: { showToast($0, symbol: "hand.raised") })
                    }
                    .contentCard()
                    .padding(.horizontal, 16)
                }
            }
            .background(Palette.canvas)
            .navigationTitle("修改\(section?.label ?? "号码")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        ticket.selections[key] = selection
                        dismiss()
                    }
                }
            }
            .onAppear { selection = ticket.selections[key] ?? SectionSelection() }
        }
    }
}

/// 改单式票里的一注。一注跨两个号码区（红+蓝、前区+后区），一起改完再落回。
private struct ScanLineEditor: View {
    @Binding var ticket: ScannedTicket
    let lineIndex: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.showToast) private var showToast
    @State private var selections: [SectionKey: SectionSelection] = [:]

    private var isComplete: Bool {
        ticket.game.sections.allSatisfy {
            (selections[$0.key]?.selected.count ?? 0) == $0.count
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ticket.game.sections) { section in
                        NumberPadSection(section: section,
                                         selection: binding(for: section.key),
                                         required: section.count,
                                         mode: .manual,
                                         danPicking: false,
                                         onReject: { showToast($0, symbol: "hand.raised") })
                    }
                }
                .contentCard()
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Palette.canvas)
            .navigationTitle("修改第 \(lineIndex + 1) 注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        guard ticket.lines.indices.contains(lineIndex) else { return dismiss() }
                        for section in ticket.game.sections {
                            ticket.lines[lineIndex][section.key] =
                                (selections[section.key]?.selected ?? []).sorted()
                        }
                        dismiss()
                    }
                    .disabled(!isComplete)
                }
            }
            .onAppear {
                guard ticket.lines.indices.contains(lineIndex) else { return }
                let numbers = ticket.lines[lineIndex]
                selections = Dictionary(uniqueKeysWithValues: ticket.game.sections.map {
                    ($0.key, SectionSelection(selected: numbers[$0.key]))
                })
            }
        }
    }

    private func binding(for key: SectionKey) -> Binding<SectionSelection> {
        Binding(get: { selections[key] ?? SectionSelection() },
                set: { selections[key] = $0 })
    }
}

// MARK: - 原图放大

/// 原图全屏查看，可捏合放大。核对小字全靠它。
private struct PhotoZoomView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var committed: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale = min(max(committed * $0, 1), 8) }
                        .onEnded { _ in
                            committed = scale
                            if scale <= 1 { offset = .zero; committedOffset = .zero }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = CGSize(width: committedOffset.width + value.translation.width,
                                            height: committedOffset.height + value.translation.height)
                        }
                        .onEnded { _ in committedOffset = offset }
                )
                // 双击在原始大小和 3 倍之间切换，比反复捏合快得多
                .onTapGesture(count: 2) {
                    withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                        if scale > 1 {
                            scale = 1; committed = 1; offset = .zero; committedOffset = .zero
                        } else {
                            scale = 3; committed = 3
                        }
                    }
                }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .padding(16)
        }
        .statusBarHidden()
    }
}

/// 系统相机。彩票是静态平面物体，用 UIImagePickerController 足够，
/// 也省掉一整套 AVCapture 会话管理。
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onFinish: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}
