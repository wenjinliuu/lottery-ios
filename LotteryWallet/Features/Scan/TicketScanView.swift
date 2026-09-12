import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// 扫描纸质彩票：拍照或选图 → 本机 Vision 识别 → 逐张复核 → 导入票夹。
///
/// 入口是个半屏抽屉，认出票之后自动长到整屏 —— 只是选张照片而已，
/// 没必要一上来就把整个屏幕占满。
struct TicketScanView: View {
    /// 「手动录入」的出口。扫描抽屉是添加彩票的**唯一**入口，
    /// 手动录入是它里面的一个分支。
    var onManualEntry: (() -> Void)?

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
    /// 矫正之后的正片。复核页顶上贴的就是它 —— 用户要核对的是「机器看到的」，
    /// 不是他自己拍的那张歪的。
    @State private var croppedPreview: UIImage?
    @State private var isPhotoZoomPresented = false
    @State private var zoomedImage: UIImage?
    @State private var rawText = ""
    @State private var tickets: [ScannedTicket] = []
    /// 每张票裁切矫正后的正片。复核、改号、补注时都要贴出来给人对照。
    @State private var ticketImages: [ScannedTicket.ID: UIImage] = [:]

    @State private var globalWarnings: [String] = []
    @State private var errorText: String?
    /// 正在改期号 / 改号码的那张票。
    @State private var issuePickerTarget: IssuePickerTarget?
    @State private var zoneEditorTarget: ZoneEditorTarget?

    enum Stage {
        case intro, crop, scanning, review
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
                case .crop: cropStep
                case .scanning: scanning
                case .review: review
                }
            }
            // **必须和抽屉面板同一个底色。**
            //
            // 这里原来是 `.clear`（当年抽屉是半透明玻璃时的写法）。改成自绘
            // 抽屉之后，透明就会露出 NavigationStack 默认的 systemBackground（白），
            // 而面板铺的是 canvas（浅灰）—— 上下各拼出一条灰带，就是"背景不统一"。
            .background(Palette.canvas)
            // 导航栏也别自己糊一层材质，否则顶部又是一条色差
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .navigationTitle(stage == .review ? "核对识别结果" : "扫描彩票")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(stage == .crop ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if stage == .review {
                    ToolbarItem(placement: .primaryAction) {
                        // 重新裁一次比重拍一张常见得多 —— 号码没认全往往是框歪了
                        Button("重新裁切") { stage = .crop }
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
        // 入口半屏，一旦开始处理图片就长到整屏。
        // 高度只在这一处按阶段决定 —— 各处再单独去改就会漏掉分支
        // （老代码里 reset 之后就没缩回去）。
        .presentationDetents(stage == .intro ? [.medium, .large] : [.large],
                             selection: $detent)
        .presentationDragIndicator(.visible)
        // 不透明底色，和页面同色。半透明材质会让背面那一层透上来，
        // 抽屉上下就会出现和内容对不上的色带。
        .presentationBackground(Palette.canvas)
        .presentationCornerRadius(28)
        .onChange(of: stage) { _, value in
            detent = value == .intro ? .medium : .large
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker { image in
                preview = image
                stage = .crop
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isPhotoZoomPresented) {
            if let image = zoomedImage ?? croppedPreview ?? preview {
                PhotoZoomView(image: image)
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
                stage = .crop
            }
        }
        .task { await drawStore.loadYearCalendars() }
    }

    // MARK: - 入口

    /// 入口。
    ///
    /// 用 ScrollView 兜底：半屏抽屉的高度是固定的，而这一页有图标、两段说明、
    /// 三个按钮，还可能多一条错误提示 —— 小屏上会顶出去，被裁掉的正好是
    /// 最底下那个「手动录入」。
    private var intro: some View {
        ScrollView {
            introContent
                .frame(minHeight: 420)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var introContent: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 6) {
                Text("把整张彩票放进取景框")
                    .font(.headline)
                Text("识别全部在这台设备上完成，照片不上传也不保存。支持双色球和大乐透的单式、复式、胆拖票。\n拍好之后框一下票面，一次认一张。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            // 进入拍照之前先把预期摆正：这东西会认错，你得自己核。
            DisclaimerBanner(text: Disclaimer.scanIntro)
                .padding(.horizontal, 22)

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

                // 手动录入放在这里，而不是让标签栏那颗按钮先弹一个二级菜单。
                // 「扫描」是主路径，「手动」是它的退路 —— 退路就该摆在
                // 主路径旁边，而不是和主路径平起平坐地占一层菜单。
                Button {
                    onManualEntry?()
                    dismiss()
                } label: {
                    Label("手动录入号码", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .foregroundStyle(.secondary)
                .glassPill(interactive: true)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }

    /// 裁切。识别之前必经的一步。
    @ViewBuilder
    private var cropStep: some View {
        if let preview {
            TicketCropView(image: preview) {
                // 「重拍」：回到入口，别把用户困在裁切界面里
                reset()
            } onConfirm: { quad in
                Task { await run(preview, quad: quad) }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    /// 识别中。
    ///
    /// 摆的是**裁切矫正之后**的那张图，铺满整块区域 —— 一来等待时有东西看，
    /// 二来这一眼就能确认「机器拿到的是不是我框的那张」。
    /// 原来图被压在 240pt 高、左右各留一大片白，看着像出错了。
    private var scanning: some View {
        ZStack {
            if let image = croppedPreview ?? preview {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 2)
                    .opacity(0.35)
                    .ignoresSafeArea()
            }
            VStack(spacing: 16) {
                if let image = croppedPreview ?? preview {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Palette.separator))
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                        .padding(.horizontal, 24)
                }
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在本机识别号码…")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassPill(interactive: false)
            }
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 复核

    @ViewBuilder
    private var review: some View {
        if tickets.isEmpty {
            ScrollView {
                VStack(spacing: 16) {
                    photoCard
                    ContentUnavailableView {
                        Label("没有识别出彩票", systemImage: "doc.questionmark")
                    } description: {
                        Text(rawText.isEmpty
                             ? "这张图上一个字都没认出来。多半是太糊或光线太暗，换个角度重拍试试。"
                             : "字认出来了，但没能拼成一张票。看看下面的原文缺了哪一行 —— 多半是框的时候切掉了号码或者期号那一行。")
                    }
                    // 「一个字都没认出来」和「认出字但拼不成票」是完全不同的两件事，
                    // 前者要重拍，后者只要重裁。把原文摆出来才分得清。
                    if !rawText.isEmpty { rawTextCard }
                    DisclaimerNote(text: Disclaimer.card, alignment: .center)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("重新裁切") { stage = .crop }
                        .buttonStyle(SecondaryGlassButton(tint: .accentColor))
                        .fixedSize()
                    Button("重新拍摄") { reset() }
                        .buttonStyle(ProminentGlassButton(tint: .accentColor))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(Palette.separator))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    photoCard
                    // 复核页是保存前的最后一道关口，提示摆在号码**上面**，
                    // 不能放页脚 —— 人是从上往下核对的，看完才提醒就晚了。
                    DisclaimerBanner(text: Disclaimer.review,
                                     icon: "checklist.unchecked")
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
        if let preview = croppedPreview ?? preview {
            Button {
                zoomedImage = croppedPreview ?? preview
                isPhotoZoomPresented = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    // **完整显示，不裁。**
                    // 这一张是"机器拿到的整张票"，用来确认框对没框对 ——
                    // 用 scaledToFill 裁掉边缘，恰恰把最该看的边界切没了。
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        // 它的职责是"确认框对没框对"，一眼扫过即可；
                        // 真要看清小字有「放大核对」。给太高会把下面的识别结果
                        // 挤出屏幕，而那才是这一页的主角。
                        .frame(maxHeight: 170)
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

            if let cropped = ticketImages[value.id] {
                Button {
                    isPhotoZoomPresented = true
                    zoomedImage = cropped
                } label: {
                    Image(uiImage: cropped)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 132)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Palette.separator))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
            }

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
            HStack(spacing: 10) {
                Text(ticket.play == .single ? "点一注可以改这一注的号码" : "点号码球可以改这一区")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                // 少认出一注是很常见的（折痕、反光压住一行）。没有这个入口的话
                // 用户只能整张重扫，而重扫大概率还是认不出那一行。
                if ticket.play == .single {
                    Button {
                        addLine(to: ticket.id)
                    } label: {
                        Label("补一注", systemImage: "plus.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ticket.game.accent.accentColor)
                }
            }
        }
    }

    /// 手工补一注：先塞一注空号码，再直接打开编辑器让人填。
    private func addLine(to id: ScannedTicket.ID) {
        guard let index = tickets.firstIndex(where: { $0.id == id }) else { return }
        tickets[index].lines.append(NumberSet())
        zoneEditorTarget = ZoneEditorTarget(ticketID: id, lineIndex: tickets[index].lines.count - 1)
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
                ScanLineEditor(ticket: $tickets[index],
                               lineIndex: lineIndex,
                               image: ticketImages[target.ticketID])
            } else if let key = target.key {
                ScanZoneEditor(ticket: $tickets[index], key: key,
                               image: ticketImages[target.ticketID])
            }
        }
    }

    // MARK: - 底栏

    /// 底栏。
    ///
    /// 原来是一条 `.bar` 材质 + 一根 Divider —— 那是导航栏的语言，
    /// 压在一屏卡片下面显得又平又硬。现在整条做成一块浮起来的玻璃：
    /// 内容从它下面滑过去看得见，和抽屉本身的层级也对得上。
    private var importBar: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(importCount) 张票 · \(totalLines) 注")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    if let blocker = importBlocker {
                        Text(blocker)
                            .font(.caption2)
                            .foregroundStyle(Palette.warning)
                    }
                }
                Spacer(minLength: 8)
                Text(MoneyText.format(tickets.reduce(0) { $0 + $1.totalCost }))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }

            Button("加入票夹") { importAll() }
                .buttonStyle(ProminentGlassButton(tint: .accentColor))
                .disabled(!canImport)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Palette.separator))
                .shadow(color: .black.opacity(0.10), radius: 16, y: -2)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// 不能导入时说清楚卡在哪一步，别只把按钮变灰。
    private var importBlocker: String? {
        if tickets.isEmpty { return "还没有可导入的票" }
        if tickets.contains(where: { $0.count == 0 }) { return "有票没读出号码，点进去补一下" }
        if tickets.contains(where: { $0.issue.isEmpty }) { return "有票还没选期号" }
        if let ticket = unresolvedPeriods.first {
            return "第 \(ticket.issue) 期往后 \(ticket.periods) 期没在开奖日历里查到，先把期号选对"
        }
        return nil
    }

    /// 追加多期的票导入后是好几张，这里按拆开之后的张数报。
    private var importCount: Int { tickets.reduce(0) { $0 + $1.periods } }
    private var totalLines: Int { tickets.reduce(0) { $0 + $1.count * $1.periods } }
    private var canImport: Bool {
        !tickets.isEmpty
            && tickets.allSatisfy { $0.count > 0 && !$0.issue.isEmpty }
            && unresolvedPeriods.isEmpty
    }

    // MARK: - 动作

    private func run(_ image: UIImage, quad: TicketQuad) async {
        stage = .scanning
        errorText = nil
        // 按用户框的四个角摆正，再把文字基线拉平，最后放大。
        // 第二步（拉平）是关键：透视矫正只保证四个角是正的，
        // 框成梯形或者票本身印歪时，里面的字照样斜着 —— 那正是
        // 「裁得很准却识别错位」的来源。
        let corrected = await TicketImagePreprocessor.prepare(image, quad: quad)
        croppedPreview = corrected
        do {
            var page = try await TicketVisionScanner.scan(corrected)
            // 单价对不上时把追加标志纠正过来，再把提示重算一遍。
            // 纠正本身必须说出来 —— 单注价格从 2 元变成 3 元是记账口径的变化，
            // 悄悄改掉的话用户看到金额对不上也不知道是哪一步动的。
            for index in page.result.tickets.indices {
                let note = TicketTextParser.reconcileAddOn(&page.result.tickets[index])
                page.result.tickets[index].warnings =
                    (note.map { [$0] } ?? []) + TicketTextParser.validate(page.result.tickets[index])
            }
            rawText = page.result.rawText
            tickets = page.result.tickets
            ticketImages = page.images
            globalWarnings = page.result.warnings
            stage = .review
        } catch {
            errorText = error.localizedDescription
            stage = .intro
        }
    }

    private func reset() {
        stage = .intro
        preview = nil
        croppedPreview = nil
        photoItem = nil
        tickets = []
        ticketImages = [:]
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
            showToast("已导入 \(saved) 注", symbol: "checkmark.seal.fill", feedback: .success)
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
        // 只有单期票才允许退回「照票面记一期」。
        //
        // 连打 N 期的票查不到连续期号时**绝不能**退回一期：底栏按 N 期收了钱，
        // 却只落一条记录，账目当场就差了 (N-1)/N。这种情况由 `unresolvedPeriods`
        // 拦在导入之前，这里再兜一道底。
        guard ticket.periods == 1 else { return [] }
        var fallback = DrawTarget()
        fallback.expect = ticket.issue
        fallback.openDate = ticket.drawDate
        fallback.status = .review
        fallback.source = "ticket_scan"
        fallback.isAvailable = true
        return [fallback]
    }

    /// 连打多期但日历里查不到那么多连续期号的票。
    private var unresolvedPeriods: [ScannedTicket] {
        tickets.filter { ticket in
            ticket.periods > 1 &&
            drawStore.issuesFollowing(game: ticket.game, from: ticket.issue,
                                      count: ticket.periods).count != ticket.periods
        }
    }
}

// MARK: - 号码区编辑

/// 改复式 / 胆拖的一个号码区。直接复用录入页那套选号盘，不另造一套。
private struct ScanZoneEditor: View {
    @Binding var ticket: ScannedTicket
    let key: SectionKey
    var image: UIImage?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.showToast) private var showToast
    @State private var selection = SectionSelection()
    @State private var danPicking = true

    private var section: GameSection? { ticket.game.sections.first { $0.key == key } }

    var body: some View {
        NavigationStack {
            // 不再套 ScrollView：号码盘按自己需要的高度贴在下面，
            // 剩下的竖向空间全部让给票面图。原来是图固定 210、底下空一大截。
            VStack(spacing: 12) {
                TicketReferenceImage(image: image, expands: true)
                    .frame(maxHeight: .infinity)
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
                                         onReject: { showToast($0, symbol: "hand.raised", feedback: .warning) })
                    }
                    .contentCard()
                    // 号码盘先拿走它要的高度，图再吃剩下的
                    .layoutPriority(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    /// 这张票裁切矫正后的正片。改号的时候人是拿着票面在核对，
    /// 让他一边翻回上一页看图一边改号是最容易改错的做法。
    var image: UIImage?

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
            VStack(spacing: 12) {
                TicketReferenceImage(image: image, expands: true)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ticket.game.sections) { section in
                        NumberPadSection(section: section,
                                         selection: binding(for: section.key),
                                         required: section.count,
                                         mode: .manual,
                                         danPicking: false,
                                         onReject: { showToast($0, symbol: "hand.raised", feedback: .warning) })
                    }
                }
                .contentCard()
                .layoutPriority(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
            .navigationTitle("修改第 \(lineIndex + 1) 注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        // 「补一注」是先塞一注空号码再打开这个页面的。
                        // 用户点取消就该当没发生过，不能在票上留一注空的。
                        if ticket.lines.indices.contains(lineIndex),
                           ticket.lines[lineIndex].isEmpty {
                            ticket.lines.remove(at: lineIndex)
                        }
                        dismiss()
                    }
                }
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

/// 改号页面顶上的票面参照图。可捏合放大 —— 要核对的就是那几行小字。
private struct TicketReferenceImage: View {
    var image: UIImage?
    /// 是否吃掉版面上剩下的全部高度。
    ///
    /// 改号的时候人是**盯着票面**在改的，图越大越好认。号码盘的高度是定死的
    /// （几行球就是几行），所以正确的分法是：号码盘贴底、按自己需要的高度占位，
    /// 剩下多少全给图 —— 而不是给图一个 210 的死高度、底下空一大片。
    var expands = false
    @State private var isZoomPresented = false

    var body: some View {
        if let image {
            Button { isZoomPresented = true } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: expands ? .infinity : 210)
                    Label("放大", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(8)
                }
                .frame(maxWidth: .infinity)
                .background(Palette.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.separator))
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $isZoomPresented) {
                PhotoZoomView(image: image)
            }
        }
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
            // 点空白处关掉。放大看完一眼就想退出，让人去够右上角那颗小叉太费事。
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
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
                // 单击图片：没放大就直接退出；放大着的先还原，
                // 免得刚放大想看细节，手一抖就把整页关了。
                //
                // 必须写在双击**之后** —— 顺序反过来，单击会把双击吃掉。
                .onTapGesture {
                    guard scale > 1 else {
                        dismiss()
                        return
                    }
                    withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                        scale = 1; committed = 1; offset = .zero; committedOffset = .zero
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
