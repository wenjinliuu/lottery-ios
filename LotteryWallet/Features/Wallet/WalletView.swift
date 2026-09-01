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
    /// 分组结果和各状态计数只在记录变化时算一次，不放进 body。
    @State private var batches: [TicketBatch] = []
    @State private var counts: [WalletFilter: Int] = [:]

    private var visibleBatches: [TicketBatch] {
        filter == .all ? batches : batches.filter { filter.matches($0.status) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
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
                }
            }
            .overlay(alignment: .bottomTrailing) { floatingButtons }
            .refreshable {
                await drawStore.refresh()
                await recheck(silent: true)
            }
            .task(id: RecordsToken(records)) { rebuild() }
        }
    }

    private func rebuild() {
        let grouped = TicketBatch.group(records)
        batches = grouped
        var tally: [WalletFilter: Int] = [:]
        for item in WalletFilter.allCases {
            tally[item] = item == .all ? grouped.count : grouped.reduce(0) { $0 + (item.matches($1.status) ? 1 : 0) }
        }
        counts = tally
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
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.card),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
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
        .padding(.top, 50)
    }

    private var floatingButtons: some View {
        HStack(spacing: 12) {
            Button(action: onOpenScan) {
                Image(systemName: "camera.viewfinder")
                    .font(.title3.weight(.semibold))
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .glassCircle()

            Button(action: onOpenEntry) {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Circle())
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .padding(.trailing, 18)
        .padding(.bottom, 22)
    }

    // MARK: - 动作

    private func toggle(_ batch: TicketBatch) {
        withAnimation(.easeOut(duration: 0.22)) {
            if expandedBatches.contains(batch.id) {
                expandedBatches.remove(batch.id)
            } else {
                expandedBatches.insert(batch.id)
            }
        }
    }

    private func delete(_ batch: TicketBatch) {
        do {
            try RecordService(context: context, drawStore: drawStore).delete(batchId: batch.id)
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
