import SwiftUI
import SwiftData

/// 票夹：每次购买是一张电子票，按购买时间倒序。
struct WalletView: View {
    var onOpenEntry: () -> Void
    var onOpenScan: () -> Void

    @Environment(DrawStore.self) private var drawStore
    @Environment(\.modelContext) private var context
    @Environment(\.showToast) private var showToast
    @Query(sort: \TicketRecord.createdAt, order: .reverse) private var records: [TicketRecord]

    @State private var filter: WalletFilter = .all
    @State private var expandedBatches: Set<String> = []
    @State private var isChecking = false

    private var batches: [TicketBatch] {
        TicketBatch.group(records)
    }

    private var visibleBatches: [TicketBatch] {
        batches.filter { filter.matches($0.status) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 13) {
                    filterBar
                    if visibleBatches.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleBatches) { batch in
                            WalletTicketCard(
                                batch: batch,
                                isExpanded: expandedBatches.contains(batch.id),
                                onToggle: { toggle(batch) },
                                onDelete: { delete(batch) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .background { Palette.canvas(Color.accentColor) }
            .scrollEdgeEffectStyle(.soft, for: .top)
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
                }
            }
            .overlay(alignment: .bottomTrailing) { floatingButtons }
            .refreshable {
                await drawStore.refresh()
                await recheck(silent: true)
            }
        }
    }

    // MARK: - 筛选

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(WalletFilter.allCases) { item in
                        let count = batches.filter { item.matches($0.status) }.count
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { filter = item }
                        } label: {
                            Text("\(item.label) \(count)")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(filter == item ? .white : Color.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .background {
                            if filter == item {
                                Capsule().fill(Color.accentColor.gradientFill)
                            }
                        }
                        .glassPill(tint: filter == item ? Color.accentColor : nil)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollClipDisabled()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("票夹是空的", systemImage: "wallet.bifold")
        } description: {
            Text("扫描纸质彩票，或手动录入已经购买的号码")
        } actions: {
            Button("添加彩票", action: onOpenEntry)
                .buttonStyle(SecondaryGlassButton(tint: .accentColor))
        }
        .padding(.top, 60)
    }

    private var floatingButtons: some View {
        HStack(spacing: 12) {
            Button(action: onOpenScan) {
                Image(systemName: "camera.viewfinder")
                    .font(.title3.weight(.semibold))
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .glassCircle(tint: .accentColor)

            Button(action: onOpenEntry) {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: 58, height: 58)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.accentColor.gradientFill, in: Circle())
            .shadow(color: Color.accentColor.opacity(0.4), radius: 14, y: 6)
        }
        .padding(.trailing, 18)
        .padding(.bottom, 24)
    }

    // MARK: - 动作

    private func toggle(_ batch: TicketBatch) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            if expandedBatches.contains(batch.id) {
                expandedBatches.remove(batch.id)
            } else {
                expandedBatches.insert(batch.id)
            }
        }
    }

    private func delete(_ batch: TicketBatch) {
        let service = RecordService(context: context, drawStore: drawStore)
        do {
            try service.delete(batchId: batch.id)
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
        guard let outcome = try? service.checkAll() else {
            if !silent { showToast("核对失败", symbol: "exclamationmark.triangle") }
            return
        }
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
