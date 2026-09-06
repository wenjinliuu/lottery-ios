import SwiftUI
import SwiftData

/// 票夹：每次购买是一张电子票，按购买时间倒序。
struct WalletView: View {
    var onOpenEntry: () -> Void
    var onOpenScan: () -> Void

    @Environment(DrawStore.self) private var drawStore
    @Environment(\.modelContext) private var context
    @Environment(\.showToast) private var showToast
    @Environment(\.celebrate) private var celebrate
    @Query(sort: \TicketRecord.createdAt, order: .reverse) private var records: [TicketRecord]

    @State private var filter: WalletFilter = .all
    @State private var expandedBatches: Set<String> = []
    @State private var isChecking = false
    /// 渲染快照。记录变化时算一次，之后渲染完全不碰 SwiftData 对象。
    @State private var cards: [TicketCard] = []
    @State private var counts: [WalletFilter: Int] = [:]
    /// 筛选结果也存下来。放在 body 里当计算属性的话，每帧都要把全部电子票过一遍。
    @State private var visibleCards: [TicketCard] = []

    /// 首屏只画这么多张。一张电子票是一整块带号码球的卡片，
    /// 几十上百张一次性铺开，进票夹那一下明显要卡。
    static let previewLimit = 10

    private var previewCards: [TicketCard] {
        Array(visibleCards.prefix(Self.previewLimit))
    }

    private var overflowCount: Int {
        Swift.max(visibleCards.count - Self.previewLimit, 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    filterBar
                    if visibleCards.isEmpty {
                        emptyState
                    } else {
                        ForEach(previewCards) { item in
                            ticketCard(item)
                        }
                        if overflowCount > 0 { moreButton }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 120)
            }
            .background(Palette.canvas)
            .navigationTitle("票夹")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await recheck() }
                    } label: {
                        if isChecking {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        }
                    }
                    .disabled(isChecking)
                    .accessibilityLabel("重新核对全部票据")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                FloatingActionButtons(onScan: onOpenScan, onAdd: onOpenEntry)
            }
            .refreshable {
                await drawStore.refresh()
                await recheck(silent: true)
            }
            .task(id: RecordsToken(records)) { rebuild() }
            .onChange(of: filter) { _, _ in applyFilter() }
        }
    }

    private func ticketCard(_ item: TicketCard) -> some View {
        WalletTicketCard(
            card: item,
            isExpanded: expandedBatches.contains(item.id),
            onToggle: { toggle(item.id) },
            onDelete: { delete(item) },
            onCelebrate: { celebrate() },
            draw: drawStore.draw(for: item.game, expect: item.expect)
        )
    }

    /// 首屏之外的票走一个单独的完整列表页，而不是在首页无限往下堆。
    private var moreButton: some View {
        NavigationLink {
            WalletAllTicketsView(
                cards: visibleCards,
                title: filter == .all ? "全部电子票" : filter.label,
                expandedBatches: $expandedBatches,
                onDelete: delete,
                onCelebrate: { celebrate() }
            )
        } label: {
            HStack(spacing: 6) {
                Text("查看全部 \(visibleCards.count) 张")
                    .font(.subheadline.weight(.semibold))
                Text("还有 \(overflowCount) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func rebuild() {
        let snapshot = TicketCard.snapshot(records)
        cards = snapshot
        var tally: [WalletFilter: Int] = [:]
        for item in WalletFilter.allCases {
            tally[item] = item == .all ? snapshot.count : snapshot.reduce(0) { $0 + (item.matches($1.status) ? 1 : 0) }
        }
        counts = tally
        applyFilter()
    }

    private func applyFilter() {
        visibleCards = filter == .all ? cards : cards.filter { filter.matches($0.status) }
    }

    // MARK: - 筛选

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WalletFilter.allCases) { item in
                    let isOn = filter == item
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { filter = item }
                    } label: {
                        Text("\(item.label) \(counts[item] ?? 0)")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(chipForeground(item, isOn: isOn))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(chipBackground(item, isOn: isOn), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    /// 「待核对」是唯一一个需要用户动手的状态，给它黄色提示色，
    /// 其余筛选沿用强调色。
    private func chipForeground(_ item: WalletFilter, isOn: Bool) -> Color {
        if item == .pending {
            return isOn ? Palette.onAccent : Palette.warning
        }
        // 深色模式下 AccentColor 是浅蓝，白字压上去只有 1.9:1
        return isOn ? Palette.onAccent : Color.primary
    }

    private func chipBackground(_ item: WalletFilter, isOn: Bool) -> AnyShapeStyle {
        if item == .pending {
            return isOn ? AnyShapeStyle(Palette.warning) : AnyShapeStyle(Palette.warning.opacity(0.15))
        }
        return isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.card)
    }

    /// 空状态要分清是「一张票都没有」还是「筛选之后没有」。
    /// 原来两种情况都说"票夹是空的 / 添加彩票"，用户会以为记录丢了。
    @ViewBuilder
    private var emptyState: some View {
        if cards.isEmpty {
            ContentUnavailableView {
                Label("票夹是空的", systemImage: "wallet.bifold")
            } description: {
                Text("扫描纸质彩票，或手动录入已经购买的号码")
            } actions: {
                Button("添加彩票", action: onOpenEntry)
                    .buttonStyle(SecondaryGlassButton(tint: .accentColor))
            }
            .padding(.top, 50)
        } else {
            ContentUnavailableView {
                Label("没有\(filter.label)的票", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("这里只显示\(filter.label)的电子票，切回「全部」可以看到其余 \(cards.count) 张。")
            } actions: {
                Button("查看全部") {
                    withAnimation(.easeOut(duration: 0.18)) { filter = .all }
                }
                .buttonStyle(SecondaryGlassButton(tint: .accentColor))
            }
            .padding(.top, 40)
        }
    }

    // MARK: - 动作

    private func toggle(_ id: String) {
        withAnimation(.spring(duration: 0.28, bounce: 0)) {
            if expandedBatches.contains(id) {
                expandedBatches.remove(id)
            } else {
                expandedBatches.insert(id)
            }
        }
    }

    private func delete(_ item: TicketCard) {
        do {
            try RecordService(context: context, drawStore: drawStore).delete(batchId: item.id)
            showToast("已删除这张票", symbol: "trash")
        } catch {
            showToast("删除失败", symbol: "exclamationmark.triangle")
        }
    }

    private func recheck(silent: Bool = false) async {
        isChecking = true
        defer { isChecking = false }
        await drawStore.loadAllHistories()
        let service = RecordService(context: context, drawStore: drawStore)
        guard let outcome = try? service.checkAll(records) else {
            if !silent { showToast("核对失败", symbol: "exclamationmark.triangle") }
            return
        }
        // 中奖是这个 App 里最值得庆祝的一刻，静默刷新也要放烟花
        if outcome.won > 0 { celebrate() }
        guard !silent else { return }
        if outcome.checked == 0 {
            showToast("暂无可核对的新开奖")
        } else if outcome.won > 0 {
            showToast("核对 \(outcome.checked) 注 · 中奖 \(outcome.won) 注", symbol: "trophy.fill")
        } else {
            showToast("已核对 \(outcome.checked) 注")
        }
    }
}

/// 完整电子票列表。票夹首屏只放前 10 张，其余在这里翻。
struct WalletAllTicketsView: View {
    let cards: [TicketCard]
    let title: String
    @Binding var expandedBatches: Set<String>
    let onDelete: (TicketCard) -> Void
    var onCelebrate: (() -> Void)?

    @Environment(DrawStore.self) private var drawStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(cards) { item in
                    WalletTicketCard(
                        card: item,
                        isExpanded: expandedBatches.contains(item.id),
                        onToggle: {
                            withAnimation(.spring(duration: 0.28, bounce: 0)) {
                                if expandedBatches.contains(item.id) {
                                    expandedBatches.remove(item.id)
                                } else {
                                    expandedBatches.insert(item.id)
                                }
                            }
                        },
                        onDelete: { onDelete(item) },
                        onCelebrate: onCelebrate,
                        draw: drawStore.draw(for: item.game, expect: item.expect)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .background(Palette.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 票夹筛选。
enum WalletFilter: String, CaseIterable, Identifiable {
    case all, pending, won, lost

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "全部"
        case .pending: "待核对"
        case .won: "已中奖"
        case .lost: "未中奖"
        }
    }

    func matches(_ status: RecordStatus) -> Bool {
        switch self {
        case .all: true
        case .pending: status == .pending
        case .won: status == .won || status == .prizeFloat
        case .lost: status == .lost
        }
    }
}
