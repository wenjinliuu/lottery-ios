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
            : TicketBuilder.combinationCount(game: game, selections: selections, mode: mode)
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
                .padding(.horizontal, 16)
                .padding(.bottom, 130)
            }
            .background { Palette.canvas(game.tint) }
            .scrollEdgeEffectStyle(.soft, for: .top)
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
            .onAppear { resetForGame(game) }
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
        .padding(16)
        .glassCard(tint: game.tint)
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
                .foregroundStyle(game == item ? .white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background {
                    if game == item {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(item.gradient)
                            .shadow(color: item.tint.opacity(0.32), radius: 7, y: 3)
                    } else {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 玩法 / 录入方式

    private var playModePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "玩法")
            Picker("玩法", selection: $playMode) {
                ForEach(game.playModes) { item in
                    Text(item.label).tag(item.key)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .glassCard(tint: game.tint)
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
            if newValue == .random { regenerate() } else { selections = [:] }
        }
    }

    // MARK: - 绑定期次

    private var targetCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: target.isAvailable ? "calendar.badge.clock" : "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(target.isAvailable ? game.tint : .orange)
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
        }
        .padding(16)
        .glassCard(tint: game.tint)
    }

    // MARK: - 随机

    private var randomPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "机选号码")
                Spacer()
                Button("重新随机", systemImage: "shuffle") { regenerate() }
                    .buttonStyle(SecondaryGlassButton(tint: game.tint))
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
                        ScrollView(.horizontal, showsIndicators: false) {
                            TicketNumbersView(game: game, ticket: ticket, size: 30)
                        }
                        .scrollClipDisabled()
                    }
                }
            }
        }
        .padding(16)
        .glassCard(tint: game.tint)
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
                    mode: mode,
                    danPicking: danPicking
                )
            }

            HStack {
                Button("随机填充", systemImage: "wand.and.stars") { fillRandomSelection() }
                    .buttonStyle(SecondaryGlassButton(tint: game.tint))
                Spacer()
                Button("清空", systemImage: "eraser") {
                    withAnimation { selections = [:] }
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCard(tint: game.tint)
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
        .padding(16)
        .glassCard(tint: game.tint)
    }

    // MARK: - 底栏

    private var saveBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text(isOverLimit
                     ? "组合超过 \(TicketBuilder.maxCombinations) 注上限"
                     : "共 \(combinationCount) 注")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOverLimit ? .orange : .primary)
                Spacer()
                Text(MoneyText.format(totalCost))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(game.tint)
            }
            Button("确认已购买并加入票夹") {
                if settings.responsibleAcknowledged {
                    save()
                } else {
                    isResponsibleAlertPresented = true
                }
            }
            .buttonStyle(ProminentGlassButton(tint: game.tint))
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - 动作

    private func resetForGame(_ item: GameKey) {
        playMode = item.defaultPlayMode
        selections = [:]
        danPicking = false
        multiple = 1
        randomCount = 1
        if !EntryMode.modes(for: item).contains(mode) { mode = .random }
        if mode == .random { regenerate() }
    }

    private func regenerate() {
        randomTickets = TicketBuilder.randomTickets(game: game, count: randomCount, playMode: playMode)
    }

    private func fillRandomSelection() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            var next: [SectionKey: SectionSelection] = [:]
            for section in game.sections {
                // 复式默认多选两个，胆拖默认一胆，给用户一个起点
                let extra = mode == .system ? 2 : 0
                let count = min(section.count + extra, section.range.count)
                var selection = SectionSelection(selected: TicketBuilder.pickUnique(count: count, from: section.range).sorted())
                if mode == .dantuo, section.count > 1, let first = selection.selected.first {
                    selection.selected = TicketBuilder.pickUnique(count: min(section.count + 2, section.range.count), from: section.range).sorted()
                    selection.dan = [selection.selected.first ?? first]
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
