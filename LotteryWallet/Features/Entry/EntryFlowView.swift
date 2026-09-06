import SwiftUI
import SwiftData

/// 添加彩票：随机 / 普通 / 复式 / 胆拖 四种录入方式共用一个工作台。
struct EntryFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(DrawStore.self) private var drawStore
    @Environment(AppSettings.self) private var settings
    @Environment(\.showToast) private var showToast

    @State private var game: GameKey = .ssq
    @State private var mode: EntryMode = .random
    @State private var playMode: String = GameKey.ssq.defaultPlayMode
    @State private var selections: [SectionKey: SectionSelection] = [:]
    @State private var danPicking = false
    @State private var randomTickets: [Ticket] = []
    @State private var randomCount = 1
    @State private var multiple = 1
    @State private var isResponsibleAlertPresented = false
    @State private var saveError: String?
    /// `onAppear` 会在每次视图重新出现时触发（比如退到后台再回来）。
    /// 早期版本无条件调 `resetForGame`，用户选了一半的号码会被清空。
    @State private var hasPrepared = false

    private var target: DrawTarget { drawStore.nextDrawTarget(for: game) }

    private var tickets: [Ticket] {
        switch mode {
        case .random:
            return randomTickets
        case .manual, .system, .dantuo:
            return TicketBuilder.expand(game: game, selections: selections, mode: mode,
                                        playMode: playMode, addOn: isAddOn) ?? []
        }
    }

    private var combinationCount: Int {
        mode == .random ? randomTickets.count
            : TicketBuilder.combinationCount(game: game, selections: selections, mode: mode, playMode: playMode)
    }

    private var isAddOn: Bool { game == .dlt && playMode == "add" }
    private var totalCost: Double { Double(combinationCount) * game.unitPrice * Double(multiple) }
    private var isOverLimit: Bool { combinationCount > TicketBuilder.maxCombinations }
    private var canSave: Bool { combinationCount > 0 && !isOverLimit && target.isAvailable }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    gamePicker
                    if !game.playModes.isEmpty { playModePicker }
                    modePicker
                    targetCard
                    if mode == .random { randomPanel } else { pickerPanel }
                    multipleRow
                }
                // 快乐8 换玩法就是换"选几个号"，已选的号码必须一起清掉，
                // 否则选十的 10 个号会被当成选五的票留在那里。
                .onChange(of: playMode) { _, _ in
                    if mode == .random { regenerate() } else { resetSelections() }
                }
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
            .onAppear {
                guard !hasPrepared else { return }
                hasPrepared = true
                resetForGame(game)
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
        .onChange(of: mode) { _, newValue in
            danPicking = false
            if newValue == .random { regenerate() } else { resetSelections() }
        }
    }

    // MARK: - 绑定期次

    private var targetCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: target.isAvailable ? "calendar.badge.clock" : "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(target.isAvailable ? game.tint : Palette.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(target.isAvailable ? "绑定第 \(target.expect) 期" : "暂时无法绑定期次")
                    .font(.subheadline.weight(.semibold))
                Text(target.isAvailable
                     ? "\(DateText.friendly(target.openTime)) 开奖 · \(target.status.label)"
                     : target.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                Task { await drawStore.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("刷新开奖期次")
        }
        .contentCard()
    }

    // MARK: - 随机

    private var randomPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "机选号码")
                Spacer(minLength: 8)
                Button("重新随机", systemImage: "shuffle") { regenerate() }
                    .buttonStyle(SecondaryGlassButton(tint: game.tint))
                    .fixedSize()
            }

            if game.supportsMultiTicketCount {
                Picker("注数", selection: $randomCount) {
                    ForEach([1, 5, 10], id: \.self) { Text("\($0) 注").tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: randomCount) { _, _ in regenerate() }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(randomTickets.enumerated()), id: \.offset) { index, ticket in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        TicketNumbersView(game: game, ticket: ticket, size: 30)
                    }
                }
            }
        }
        .contentCard()
    }

    // MARK: - 手动选号

    private var pickerPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mode == .dantuo {
                Picker("选号类型", selection: $danPicking) {
                    Text("选拖码").tag(false)
                    Text("选胆码").tag(true)
                }
                .pickerStyle(.segmented)
            }

            ForEach(game.sections) { section in
                NumberPadSection(
                    section: section,
                    selection: binding(for: section.key),
                    required: requiredCount(for: section),
                    mode: mode,
                    danPicking: danPicking
                )
            }

            HStack {
                Button("随机填充", systemImage: "wand.and.stars") { fillRandomSelection() }
                    .buttonStyle(SecondaryGlassButton(tint: game.tint))
                Spacer(minLength: 8)
                Button("清空", systemImage: "eraser") {
                    withAnimation { resetSelections() }
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
            set: { selections[key] = $0 }
        )
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
            .buttonStyle(ProminentGlassButton(tint: game.tint, foreground: game.onTint))
            .disabled(!canSave)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 14)
        .background(.bar)
    }

    // MARK: - 动作

    private func resetForGame(_ item: GameKey) {
        playMode = item.defaultPlayMode
        danPicking = false
        multiple = 1
        randomCount = 1
        if !EntryMode.modes(for: item).contains(mode) { mode = .random }
        resetSelections(for: item)
        if mode == .random { regenerate() }
    }

    /// 清空选号。
    ///
    /// 数字型玩法（3D、排列3/5、七星彩前六位）用的是滚轮，滚轮**永远显示着一个值**。
    /// 如果 selections 是空的，界面上明明写着 0 0 0，底栏却是"共 0 注"、保存按钮是灰的。
    /// 所以位选号一开始就按滚轮当前显示的值填好。
    private func resetSelections(for item: GameKey? = nil) {
        let target = item ?? game
        var next: [SectionKey: SectionSelection] = [:]
        for section in target.sections where section.isPositional {
            let need = target.pickCount(for: section, playMode: playMode)
            next[section.key] = SectionSelection(
                selected: Array(repeating: section.range.lowerBound, count: need)
            )
        }
        selections = next
    }

    private func regenerate() {
        randomTickets = TicketBuilder.randomTickets(game: game, count: randomCount, playMode: playMode)
    }

    private func fillRandomSelection() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            var next: [SectionKey: SectionSelection] = [:]
            for section in game.sections {
                let need = requiredCount(for: section)
                if section.isPositional {
                    // 按位取值，必须允许重复：pickUnique 永远给不出 5-5-3 这种号，
                    // 3D 的豹子、对子用"随机填充"一辈子也随不出来。
                    next[section.key] = SectionSelection(
                        selected: (0..<need).map { _ in Int.random(in: section.range) }
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
                             price: game.unitPrice,
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
