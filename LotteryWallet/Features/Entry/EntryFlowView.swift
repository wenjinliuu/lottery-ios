import SwiftUI
import SwiftData

/// 添加彩票：手选 / 复式 / 胆拖三种录入方式共用一个工作台。
///
/// 底部永远有一张**整票预览**。这是这一版最重要的改动：
/// 早期版本选完一组号只能直接存成一张一注的票，用户看不到"我这张票长什么样"，
/// 也没法像在彩票站那样把好几注打在同一张票上。现在手选可以攒候选注，
/// 复式和胆拖则按真实票面的排版（红单/红复、前区胆/前区拖…）画出来。
struct EntryFlowView: View {
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

    private var preview: TicketPreview {
        mode == .manual
            ? TicketPreviewBuilder.make(game: game, lines: lines)
            : TicketPreviewBuilder.make(game: game, mode: mode, playMode: playMode, selections: selections)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    gamePicker
                    if !game.playModes.isEmpty { playModePicker }
                    if EntryMode.modes(for: game).count > 1 { modePicker }
                    targetCard
                    pickerPanel
                    previewSection
                    multipleRow
                }
                // 快乐8 换玩法就是换"选几个号"，已选的号码必须一起清掉，
                // 否则选十的 10 个号会被当成选五的票留在那里。
                .onChange(of: playMode) { _, _ in resetSelections(clearCandidates: true) }
                .padding(.horizontal, 16)
                // safeAreaInset 已经按底栏高度把内容顶上去了，
                // 这里再垫 130 就是一大片滚不完的空白。
                .padding(.bottom, 20)
            }
            .background(Palette.canvas)
            .navigationTitle("添加彩票")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { saveBar }
            .sheet(isPresented: $isIssuePickerPresented) {
                IssuePickerSheet(game: game, current: target.expect) { issue in
                    pickedIssue = issue
                }
            }
            .alert("理性购彩", isPresented: $isResponsibleAlertPresented) {
                Button("我已了解", action: { settings.responsibleAcknowledged = true; save() })
                Button("取消", role: .cancel) {}
            } message: {
                Text("本应用只记录你已经在正规线下渠道购买的彩票，不销售也不代购。请理性参与，量力而行。")
            }
            .alert("无法保存", isPresented: .init(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .task {
                guard !hasPrepared else { return }
                hasPrepared = true
                resetForGame(game)
                await drawStore.loadYearCalendars()
            }
        }
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

    private var playModePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "玩法")
            // 快乐8 有「选一」到「选十」十个玩法。十段分段控件每段只剩不到 30pt，
            // 中文标签会被压成省略号，只能改成菜单。
            if game.playModes.count > 4 {
                Picker("玩法", selection: $playMode) {
                    ForEach(game.playModes) { item in
                        Text(item.label).tag(item.key)
                    }
                }
                .pickerStyle(.menu)
                .tint(game.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("玩法", selection: $playMode) {
                    ForEach(game.playModes) { item in
                        Text(item.label).tag(item.key)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .contentCard()
    }

    private var modePicker: some View {
        Picker("录入方式", selection: $mode.animation(.spring(response: 0.3, dampingFraction: 0.85))) {
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

    private var targetSubtitle: String {
        var text = "\(DateText.friendly(target.openTime)) 开奖"
        if pickedIssue != nil {
            text += " · 手动指定"
        } else if !target.buyEndTime.isEmpty {
            text += " · \(DateText.friendly(target.buyEndTime)) 停售"
        }
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
                    onReject: { showToast($0, symbol: "hand.raised") }
                )
            }

            HStack(spacing: 10) {
                Button("随机填充", systemImage: "wand.and.stars") { fillRandomSelection() }
                    .buttonStyle(SecondaryGlassButton(tint: game.tint))
                if mode == .manual {
                    Button("加入候选", systemImage: "plus.circle") { addCandidate() }
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

    // MARK: - 倍数

    private var multipleRow: some View {
        HStack {
            Text("倍数")
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
        .contentCard()
    }

    // MARK: - 底栏

    private var saveBar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Text(isOverLimit
                     ? "组合超过 \(TicketBuilder.maxCombinations) 注上限"
                     : "共 \(combinationCount) 注")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOverLimit ? Palette.warning : .primary)
                Spacer(minLength: 8)
                Text(MoneyText.format(totalCost))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(game.tint)
            }
            .padding(.horizontal, 16)

            Button("确认已购买并加入票夹") {
                if settings.responsibleAcknowledged {
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
            showToast("这一注已经在候选里了", symbol: "exclamationmark.circle")
            return
        }
        guard candidates.count < TicketBuilder.maxCombinations else {
            showToast("一张票最多 \(TicketBuilder.maxCombinations) 注", symbol: "hand.raised")
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
            try service.save(tickets: built,
                             game: game,
                             entryKind: mode.kind,
                             price: unitPrice,
                             multiple: multiple,
                             target: target,
                             source: mode.rawValue)
            showToast("已保存 \(built.count) 注", symbol: "checkmark.seal.fill")
            dismiss()
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }
}
