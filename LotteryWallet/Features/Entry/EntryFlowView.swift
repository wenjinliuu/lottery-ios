import SwiftUI
import SwiftData

/// 添加彩票：手选 / 复式 / 胆拖三种录入方式共用一个工作台。
///
/// 底部永远有一张**整票预览**。这是这一版最重要的改动：
/// 早期版本选完一组号只能直接存成一张一注的票，用户看不到"我这张票长什么样"，
/// 也没法像在彩票站那样把好几注打在同一张票上。现在手选可以攒候选注，
/// 复式和胆拖则按真实票面的排版（红单/红复、前区胆/前区拖…）画出来。
/// 扫描认不出来的时候，带着票面照片转到手动录入。
///
/// 没有这条路的话，机器认不出的票就是**死路一条** —— 用户手里明明有票，
/// 却既不能扫进来也不能对着照片敲进去。照片跟着一起过来，
/// 用户不用在两个页面之间来回切。
struct EntryReference {
    var image: UIImage
    /// 认出了彩种就先替用户选上。彩种往往认得出来（票头那几个大字），
    /// 认不出的只是号码。
    var game: GameKey? = nil
    /// 用户在扫描复核页改过的票面类型。
    ///
    /// 改票面类型是**不能就地转换**的：单式的每一注是独立的号码，复式是一个区
    /// 多选几个号再展开，胆拖还要分出胆码 —— 三者的号码结构根本不是一回事，
    /// 硬转出来的号码必然和用户手里那张票对不上。所以扫描页改了票型就直接
    /// 带着照片转到这里重录，这个字段只负责让录入页**一进来就落在那一种**上。
    var shape: TicketShape? = nil
    /// 扫描已经认出来的期次。改票面类型只是重录号码，期号没有理由让人再选一遍。
    var issue: CalendarIssue? = nil
}

struct EntryFlowView: View {
    /// 从扫描页转过来时带的票面照片。手动从标签栏进来就是 nil。
    var reference: EntryReference? = nil
    /// 存进票夹之后通知调用方。扫描页靠它把已经处理掉的那张票从复核列表里摘掉。
    var onSaved: (() -> Void)? = nil
    /// 要修改的那张票。为空就是新录一张。
    ///
    /// 修改和新录共用这个工作台 —— 界面、校验、复式展开规则不该有第二套。
    /// 差别只有两处：进来时把已有内容填回去，保存时走 `replace` 而不是 `save`。
    var draft: EntryDraft? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DrawStore.self) private var drawStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.showToast) private var showToast

    @State private var game: GameKey = .ssq
    @State private var mode: EntryMode = .manual
    @State private var playMode: String = GameKey.ssq.defaultPlayMode
    @State private var selections: [SectionKey: SectionSelection] = [:]
    /// 胆拖模式下先选胆码 —— 票面上也是胆在前、拖在后。
    @State private var danPicking = true
    /// 手选攒下来的候选注，最后一起打成同一张票。
    @State private var candidates: [NumberSet] = []
    /// 攒过候选之后，用户又动过选号盘没有。
    ///
    /// 数字型玩法（3D、排列3/5、七星彩）的滚轮**永远显示着一注完整的号**，
    /// 0 0 0 也是合法的一注。所以「当前选号凑齐了没有」这个条件在那些彩种上
    /// 恒为真：每点一次「加入候选」，滚轮复位成 000，这个 000 又会被当成
    /// 一注跟着存进去 —— 用户平白多买一注、多付两块钱。
    @State private var hasPendingEdit = false
    @State private var multiple = 1
    @State private var isResponsibleAlertPresented = false
    @State private var isIssuePickerPresented = false
    @State private var saveError: String?
    /// 用户手动指定的期次。为空表示跟随"现在能买的那一期"。
    @State private var pickedIssue: CalendarIssue?
    /// `onAppear` 会在每次视图重新出现时触发（比如退到后台再回来）。
    /// 早期版本无条件调 `resetForGame`，用户选了一半的号码会被清空。
    @State private var hasPrepared = false
    /// 票面照片放大看。对着照片敲号码时要能看清那几位小字。
    @State private var isReferenceZoomed = false

    private var target: DrawTarget {
        pickedIssue?.target(source: "manual_pick") ?? drawStore.nextDrawTarget(for: game)
    }

    /// 当前这一组选号是否已经凑齐一注（手选用）。
    private var pendingLine: NumberSet? {
        guard mode == .manual else { return nil }
        var numbers = NumberSet()
        for section in game.sections {
            let selected = selections[section.key]?.selected ?? []
            guard selected.count == game.pickCount(for: section, playMode: playMode) else { return nil }
            numbers[section.key] = section.isPositional ? selected : selected.sorted()
        }
        return numbers
    }

    /// 保存时真正要写进票夹的号码。
    private var lines: [NumberSet] {
        guard mode == .manual else { return [] }
        guard let pendingLine else { return candidates }
        // 还没点"加入候选"就直接保存的那一注不能丢掉 —— 大多数人只买一注，
        // 让他们为了一注去点一次"加入候选"是多余的一步。
        // 但攒过候选之后就必须是用户**又动过号码**才算数，理由见 `hasPendingEdit`。
        guard candidates.isEmpty || hasPendingEdit else { return candidates }
        guard !candidates.contains(pendingLine) else { return candidates }
        return candidates + [pendingLine]
    }

    private var tickets: [Ticket] {
        switch mode {
        case .manual:
            return lines.map { numbers in
                var ticket = Ticket(numbers: numbers, playMode: playMode, entryLabel: mode.label)
                if game == .k8 { ticket.playCount = numbers[.nums].count }
                ticket.addOn = isAddOn
                return ticket
            }
        case .system, .dantuo:
            return TicketBuilder.expand(game: game, selections: selections, mode: mode,
                                        playMode: playMode, addOn: isAddOn) ?? []
        }
    }

    private var combinationCount: Int {
        mode == .manual
            ? lines.count
            : TicketBuilder.combinationCount(game: game, selections: selections, mode: mode, playMode: playMode)
    }

    private var isAddOn: Bool { game == .dlt && playMode == "add" }
    /// 追加是 3 元一注，见 `GameKey.unitPrice(addOn:)`。
    private var unitPrice: Double { game.unitPrice(addOn: isAddOn) }
    private var totalCost: Double { Double(combinationCount) * unitPrice * Double(multiple) }
    private var isOverLimit: Bool { combinationCount > TicketBuilder.maxCombinations }
    private var canSave: Bool { combinationCount > 0 && !isOverLimit && target.isAvailable }

    /// 从扫描页改票面类型转过来时的说明。
    ///
    /// 没有这一句的话，用户点一下「复式票」，屏幕上换出来一个空的选号盘 ——
    /// 他既不知道自己为什么到了这里，也不知道该干什么。这一句要回答的就是
    /// 这两个问题：为什么换页面，以及现在要做什么。
    @ViewBuilder
    private var handoffNotice: some View {
        if let shape = reference?.shape {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(game.accent.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已切换为\(shape.label)")
                        .font(.caption.weight(.semibold))
                    Text("\(shape.label)和原来的号码结构不一样，没法直接换算。期号已经带过来了，对照下面的票面把号码重录一遍就行。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(game.tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    /// 票面照片。只在从扫描页转过来时才有。
    ///
    /// 它是**对照用**的，不是主角；真要看清小字有「放大」。
    /// 给太高的话选号盘会被挤出屏幕，而那才是这一页要干的事 ——
    /// 所以只在「改票面类型转过来」这条路上给得高一些（150pt）：
    /// 那条路上用户是**照着这张照片一个号一个号敲**的，看不清就干不了活。
    @ViewBuilder
    private var referenceCard: some View {
        if let image = reference?.image {
            Button {
                isReferenceZoomed = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: reference?.shape == nil ? 110 : 150)
                    Label("放大", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.separator))
            }
            .buttonStyle(.plain)
        }
    }

    private var preview: TicketPreview {
        mode == .manual
            ? TicketPreviewBuilder.make(game: game, lines: lines)
            : TicketPreviewBuilder.make(game: game, mode: mode, playMode: playMode, selections: selections)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    handoffNotice
                    referenceCard
                    gamePicker
                    if showsPlayModePicker { playModePicker }
                    if EntryMode.modes(for: game).count > 1 { modePicker }
                    targetCard
                    pickerPanel
                    previewSection
                    multipleRow
                }
                // 换玩法就是换"一注选几个号"，已选的号码必须一起清掉，
                // 否则选十的 10 个号会被当成选五的票留在那里。
                //
                // **大乐透除外。** 它的「追加」只改单注价格（2 元 → 3 元），
                // 号码个数和取值范围一个都不变。跟着清空的话，用户选好七个号
                // 再想起来这张票是追加的，一打开开关号码全没了。
                .onChange(of: playMode) { _, _ in
                    guard game != .dlt else { return }
                    resetSelections(clearCandidates: true)
                }
                .padding(.horizontal, 16)
                // safeAreaInset 已经按底栏高度把内容顶上去了，
                // 这里再垫 130 就是一大片滚不完的空白。
                .padding(.bottom, 20)
            }
            .background(Palette.canvas)
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .navigationTitle(draft == nil ? "添加彩票" : "修改彩票")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { saveBar }
            .fullScreenCover(isPresented: $isReferenceZoomed) {
                if let image = reference?.image { PhotoZoomView(image: image) }
            }
            .sheet(isPresented: $isIssuePickerPresented) {
                IssuePickerSheet(game: game, current: target.expect) { issue in
                    pickedIssue = issue
                }
            }
            .alert("理性购彩", isPresented: $isResponsibleAlertPresented) {
                Button("我已了解", action: { settings.responsibleAcknowledged = true; save() })
                Button("取消", role: .cancel) {}
            } message: {
                Text("本应用仅用于记录和核对你已持有的实体彩票，不销售、不代购、不提供兑奖服务。请理性参与，量力而行。")
            }
            .alert("无法保存", isPresented: .init(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .task {
                guard !hasPrepared else { return }
                hasPrepared = true
                // 扫描页认出了彩种就先替用户选上 —— 认不出的往往只是号码，
                // 票头那几个大字一般都认得出来。
                if let draft { seed(from: draft) }
                if let detected = reference?.game { game = detected }
                if draft == nil { resetForGame(game) }
                // 从扫描页改票面类型转过来的，直接落在用户选的那一种上。
                // `resetForGame` 会把 mode 打回 .manual、把 pickedIssue 清空，
                // 所以这两样都必须放在它后面。
                if let shape = reference?.shape,
                   let target = EntryMode.modes(for: game).first(where: { $0.shape == shape }) {
                    mode = target
                }
                if let issue = reference?.issue { pickedIssue = issue }
                await drawStore.loadYearCalendars()
            }
        }
        // 录入一上来就要整屏：选号盘加整票预览，半屏根本摆不下。
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.canvas)
        .presentationCornerRadius(28)
    }

    // MARK: - 彩种

    private var gamePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "彩种")
            VStack(spacing: 8) {
                ForEach(Array(GameKey.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        ForEach(row) { item in
                            gameChip(item)
                        }
                    }
                }
            }
        }
        .contentCard()
    }

    private func gameChip(_ item: GameKey) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                game = item
                resetForGame(item)
            }
        } label: {
            Text(item.label)
                .font(.footnote.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // 彩种色打底就必须配 onTint：黄、琥珀两个彩种压白字只有 2:1，
                // 深色模式下所有彩种色都会换成浅端，白字同样读不清。
                .foregroundStyle(game == item ? item.onTint : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background {
                    if game == item {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(item.tint)
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(item.accent.solidStroke, lineWidth: 1))
                            .shadow(color: item.tint.opacity(0.32), radius: 7, y: 3)
                    } else {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(game == item ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - 玩法 / 录入方式

    /// 大乐透的「普通 / 追加」不在这儿选。
    ///
    /// 它和别的玩法不是一回事：快乐8 的「选几」、3D 的「组三/组六」决定
    /// 一注选几个号、按哪张奖级表核对，是**录号之前**就得定下来的事；
    /// 追加只是票面上多打了一行、单注贵一块钱，号码一个都不变。
    /// 把它和倍数放在一起（都是"抄票面上印的数字"），语义才对得上。
    private var showsPlayModePicker: Bool {
        !game.playModes.isEmpty && game != .dlt
    }

    private var playModePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "票面玩法")
            if game.playModes.count > 4 {
                playModeGrid
            } else {
                Picker("票面玩法", selection: $playMode) {
                    ForEach(game.playModes) { item in
                        Text(item.label).tag(item.key)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .contentCard()
    }

    /// 快乐8 的「选一」到「选十」，两行五列铺开。
    ///
    /// 原来是一条横滑芯片条，两个毛病：十个选项只看得见前四五个，默认的
    /// 「选十」在最右边，打开页面看到的是「选一」被选中的错觉；而且为了让
    /// 芯片在滑动时不被裁掉用了 `scrollClipDisabled()`，芯片会**画到卡片
    /// 外面去**，压在相邻的卡片上。
    ///
    /// 十个等价的平级选项本来就该一次全看见。固定两行五列之后没有滚动、
    /// 没有溢出，当前选中一直亮着，和其他彩种的分段控件也是同一个观感。
    private var playModeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                  spacing: 8) {
            ForEach(game.playModes) { item in
                let isOn = playMode == item.key
                Button {
                    playMode = item.key
                } label: {
                    Text(item.label)
                        .font(.footnote.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(isOn ? game.onTint : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(isOn ? AnyShapeStyle(game.tint) : AnyShapeStyle(Color.primary.opacity(0.06)),
                                    in: Capsule())
                        .overlay(Capsule().strokeBorder(isOn ? game.accent.solidStroke : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: playMode)
    }

    private var modePicker: some View {
        Picker("票面类型", selection: $mode.animation(.spring(response: 0.3, dampingFraction: 0.85))) {
            ForEach(EntryMode.modes(for: game)) { item in
                Text(item.label).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: mode) { _, _ in
            danPicking = true
            resetSelections(clearCandidates: true)
        }
    }

    // MARK: - 绑定期次

    /// 绑定期次卡片。整张卡可点，点开是整年开奖日历。
    ///
    /// 「无法绑定期次」这个死状态基本上不会再出现了：`nextDrawTarget` 现在
    /// 优先走整年日历，过了当期停售时间就自动落到下一期。
    private var targetCard: some View {
        Button {
            isIssuePickerPresented = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: target.isAvailable ? "calendar.badge.clock" : "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(target.isAvailable ? game.tint : Palette.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.isAvailable ? "绑定第 \(target.expect) 期" : "暂时无法绑定期次")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(target.isAvailable ? targetSubtitle : target.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if pickedIssue != nil {
                    Button("跟随最新") {
                        pickedIssue = nil
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(game.accent.accentColor)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentCard()
        .accessibilityHint("点按可以从整年开奖日历里改绑其他期次")
    }

    /// 期次卡副标题。
    ///
    /// 只说开奖时刻，不说销售状态 —— 这一页在帮用户确认"手里这张票属于哪一期"，
    /// 不是在告诉他"现在还能买哪一期"。`buyEndTime` 仍然留在 `DrawTarget` 里，
    /// 自动落到下一期的推断还要用它（见 `DrawStore.calendarTarget`）。
    private var targetSubtitle: String {
        var text = "\(DateText.friendly(target.openTime)) 开奖"
        if pickedIssue != nil { text += " · 手动指定" }
        return text
    }

    // MARK: - 选号

    private var pickerPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mode == .dantuo {
                // 顺序跟着票面走：胆码在前，拖码在后。
                Picker("选号类型", selection: $danPicking) {
                    Text("选胆码").tag(true)
                    Text("选拖码").tag(false)
                }
                .pickerStyle(.segmented)
            }

            ForEach(game.sections) { section in
                NumberPadSection(
                    section: section,
                    selection: binding(for: section.key),
                    required: requiredCount(for: section),
                    mode: mode,
                    danPicking: danPicking,
                    onReject: { showToast($0, symbol: "hand.raised", feedback: .warning) }
                )
            }

            HStack(spacing: 10) {
                Button("随机填充", systemImage: "wand.and.stars") { fillRandomSelection() }
                    .buttonStyle(SecondaryGlassButton(tint: game.tint))
                if mode == .manual {
                    Button("加入", systemImage: "plus.circle") { addCandidate() }
                        .buttonStyle(SecondaryGlassButton(tint: game.tint))
                        .disabled(pendingLine == nil)
                }
                Spacer(minLength: 8)
                Button("清空", systemImage: "eraser") {
                    withAnimation { resetSelections(clearCandidates: false) }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .contentCard()
    }

    /// 这个号码区实际要选几个号。快乐8 由玩法决定，见 `GameKey.pickCount`。
    private func requiredCount(for section: GameSection) -> Int {
        game.pickCount(for: section, playMode: playMode)
    }

    private func binding(for key: SectionKey) -> Binding<SectionSelection> {
        Binding(
            get: { selections[key] ?? SectionSelection() },
            set: {
                selections[key] = $0
                hasPendingEdit = true
            }
        )
    }

    // MARK: - 整票预览

    @ViewBuilder
    private var previewSection: some View {
        if !preview.isEmpty {
            TicketPreviewCard(game: game,
                              preview: preview,
                              count: combinationCount,
                              cost: totalCost,
                              multiple: multiple,
                              // 末尾那条可能是还没加入候选的当前选号，它不在
                              // `candidates` 里，给它一个减号只会点了没反应
                              removableCount: mode == .manual ? candidates.count : 0,
                              onRemoveLine: mode == .manual ? removeCandidate : nil)
        } else {
            Text(mode == .manual
                 ? "选够号码后会在这里显示整张票的样子，可以一次攒好几注。"
                 : "选够号码后会在这里按票面的排版显示整张票。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentCard()
        }
    }

    // MARK: - 票面倍数 / 追加

    /// 票面上印着的倍数和「追加」。
    ///
    /// 这两样是同一类东西 —— 都是照着用户手里那张纸抄下来的数字，
    /// 而不是在这儿决定要买多少。放在一张卡片里，标题都带「票面」两个字。
    private var multipleRow: some View {
        VStack(spacing: 0) {
            HStack {
                Text("票面倍数")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Stepper(value: $multiple, in: 1...99) {
                    Text("\(multiple) 倍")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(game.tint)
                }
                .fixedSize()
            }

            if game == .dlt {
                Divider().padding(.vertical, 12)
                Toggle(isOn: addOnBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("票面追加")
                            .font(.subheadline.weight(.semibold))
                        Text("票面印有「追加」时打开，单注 3 元")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(game.tint)
            }
        }
        .contentCard()
    }

    /// 大乐透的追加就是 `playMode == "add"`，底层字段一个没动。
    private var addOnBinding: Binding<Bool> {
        Binding(get: { playMode == "add" },
                set: { playMode = $0 ? "add" : "normal" })
    }

    // MARK: - 底栏

    private var saveBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .bottom) {
                Text(isOverLimit
                     ? "组合超过 \(TicketBuilder.maxCombinations) 注上限"
                     : "票面共 \(combinationCount) 注")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOverLimit ? Palette.warning : .primary)
                Spacer(minLength: 8)
                // 这个金额是**那张纸上印着的合计**，不是在这儿要付的钱。
                // 不标一行字的话，一个跟着选号实时变的 ¥ 数字看着就像结账页。
                VStack(alignment: .trailing, spacing: 1) {
                    Text("票面金额")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(MoneyText.format(totalCost))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(game.tint)
                }
                .fixedSize()
            }
            .padding(.horizontal, 16)

            // 就摆在保存按钮上方 —— 这一刻正是最需要说清
            // 「本应用不卖票、你录的是你已经买到手的票」的时刻。
            DisclaimerNote(text: Disclaimer.entry)
                .padding(.horizontal, 16)

            Button(draft == nil ? "加入票夹" : "保存修改") {
                // 修改已有的票不再弹理性购彩 —— 那句提醒是针对「新增一张票」
                // 这个动作的，改个号码再弹一次只是噪声。
                if draft != nil || settings.responsibleAcknowledged {
                    save()
                } else {
                    isResponsibleAlertPresented = true
                }
            }
            // 禁用态的淡化交给按钮样式统一处理，不再各页面自己叠 opacity
            .buttonStyle(ProminentGlassButton(tint: game.tint, foreground: game.onTint, stroke: game.accent.solidStroke))
            .disabled(!canSave)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 14)
        .background(.bar)
    }

    // MARK: - 修改已有的票

    /// 把一张已存在的票填回工作台。
    ///
    /// 顺序有讲究：`game` 必须最先定，`mode` 和 `playMode` 依赖它，
    /// 而且**绝不能再调 `resetForGame`** —— 那会把刚填进去的全清掉。
    private func seed(from draft: EntryDraft) {
        game = draft.game
        playMode = draft.playMode
        multiple = draft.multiple
        if let target = EntryMode.modes(for: draft.game).first(where: { $0.shape == draft.shape }) {
            mode = target
        }
        switch draft.shape {
        case .single:
            candidates = draft.lines
            // 单式票的号码全在候选里，选号盘留空等用户加新的一注。
            // 数字型玩法的滚轮仍要有初值，否则底栏会显示「票面共 0 注」。
            resetSelections(for: draft.game, clearCandidates: false)
        case .system, .dantuo:
            selections = draft.selections
            danPicking = true
        }
        // 期号照原样绑回去，用户没改就不该变。
        pickedIssue = drawStore.issuesFollowing(game: draft.game, from: draft.expect, count: 1).first
    }

    // MARK: - 动作

    private func resetForGame(_ item: GameKey) {
        playMode = item.defaultPlayMode
        danPicking = true
        multiple = 1
        pickedIssue = nil
        if !EntryMode.modes(for: item).contains(mode) { mode = .manual }
        resetSelections(for: item, clearCandidates: true)
    }

    /// 清空选号。
    ///
    /// 数字型玩法（3D、排列3/5、七星彩前六位）用的是滚轮，滚轮**永远显示着一个值**。
    /// 如果 selections 是空的，界面上明明写着 0 0 0，底栏却是"共 0 注"、保存按钮是灰的。
    /// 所以位选号一开始就按滚轮当前显示的值填好。
    private func resetSelections(for item: GameKey? = nil, clearCandidates: Bool) {
        let target = item ?? game
        var next: [SectionKey: SectionSelection] = [:]
        for section in target.sections where section.isPositional {
            let need = target.pickCount(for: section, playMode: playMode)
            next[section.key] = SectionSelection(
                selected: Array(repeating: section.range.lowerBound, count: need)
            )
        }
        selections = next
        hasPendingEdit = false
        if clearCandidates { candidates = [] }
    }

    private func addCandidate() {
        guard let pendingLine else { return }
        guard !candidates.contains(pendingLine) else {
            showToast("这一注已经在候选里了", symbol: "exclamationmark.circle", feedback: .warning)
            return
        }
        guard candidates.count < TicketBuilder.maxCombinations else {
            showToast("一张票最多 \(TicketBuilder.maxCombinations) 注", symbol: "hand.raised", feedback: .warning)
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            candidates.append(pendingLine)
            // 加入之后把选号盘清空，好接着选下一注。数字型的滚轮照旧填回初值。
            resetSelections(clearCandidates: false)
        }
        showToast("已加入第 \(candidates.count) 注", symbol: "plus.circle.fill")
    }

    private func removeCandidate(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        candidates.remove(at: index)
    }

    private func fillRandomSelection() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            var next: [SectionKey: SectionSelection] = [:]
            for section in game.sections {
                let need = requiredCount(for: section)
                if section.isPositional {
                    next[section.key] = SectionSelection(
                        selected: TicketBuilder.randomDigits(game: game, count: need,
                                                             range: section.range, playMode: playMode)
                    )
                    continue
                }
                // 复式默认多选两个，胆拖默认一胆，给用户一个起点
                let extra = mode == .system ? 2 : 0
                let count = min(need + extra, section.range.count)
                var selection = SectionSelection(selected: TicketBuilder.pickUnique(count: count, from: section.range).sorted())
                if mode == .dantuo, need > 1 {
                    selection.selected = TicketBuilder.pickUnique(count: min(need + 2, section.range.count), from: section.range).sorted()
                    selection.dan = Array(selection.selected.prefix(1))
                }
                next[section.key] = selection
            }
            selections = next
            hasPendingEdit = true
        }
    }

    private func save() {
        guard target.isAvailable else {
            saveError = target.message
            return
        }
        let built = tickets
        guard !built.isEmpty else {
            saveError = "号码还没选完"
            return
        }
        guard built.count <= TicketBuilder.maxCombinations else {
            saveError = "组合超过 \(TicketBuilder.maxCombinations) 注上限，请减少选号"
            return
        }
        let service = RecordService(context: context, drawStore: drawStore)
        do {
            if let draft {
                // batchId 和 createdAt 原样留住：改一张票不该让它在票夹里跳位置，
                // 也不该改变它在统计里的归属日期。
                try service.replace(batchId: draft.batchId,
                                    tickets: built,
                                    game: game,
                                    entryKind: mode.kind,
                                    price: unitPrice,
                                    multiple: multiple,
                                    target: target,
                                    source: draft.source,
                                    createdAt: draft.createdAt)
                // 改完立刻按当前开奖数据重核一遍，否则票面变了、
                // 中奖标记还停在改之前那一版。
                _ = try? service.checkAll()
                showToast("已保存修改", symbol: "checkmark.seal.fill", feedback: .success)
            } else {
                try service.save(tickets: built,
                                 game: game,
                                 entryKind: mode.kind,
                                 price: unitPrice,
                                 multiple: multiple,
                                 target: target,
                                 source: mode.rawValue)
                showToast("已保存 \(built.count) 注", symbol: "checkmark.seal.fill", feedback: .success)
            }
            onSaved?()
            dismiss()
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }
}
