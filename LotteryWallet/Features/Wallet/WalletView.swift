import SwiftUI
import SwiftData

/// 票夹：每次购买是一张电子票，按购买时间倒序。
struct WalletView: View {

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

    /// **进页面时冻结下来的顺序**（batchId → 名次）。
    ///
    /// 票夹开着的时候顺序一律按这份来，哪怕期间自动核对把某张票从
    /// 「等开奖」变成了「中奖」。原来是记录一变就整列重排，于是开奖那一刻
    /// 卡片在用户眼皮底下跳走 —— 这是最不该发生的一种位移。
    /// 卡片内容照常更新（状态、金额、命中球、烟花），只是**位置不动**。
    @State private var frozenRank: [String: Int] = [:]
    /// **分区也一起冻结。**
    ///
    /// 只冻名次不冻分区的话，卡片被标成已读之后位置没动、分区却变了，
    /// 于是「新结果」那一段里会混进一张标着历史的卡，分组标题当场错乱。
    @State private var frozenZone: [String: TicketCard.Zone] = [:]
    /// 下一次 rebuild 要不要重新冻结。
    @State private var needsRefreeze = true
    /// 上次重排的时刻，用来判断这次回来算不算「新的一次查看」。
    @State private var lastFreezeAt: Date?
    /// 离开多久以上，回来才重排。
    ///
    /// 从票夹点去设置看一眼再切回来，不该把「新结果」那一区当场清空 ——
    /// 用户根本没来得及看。只有隔了一会儿再回来，或者 App 进过后台，
    /// 才算真正的下一次查看。
    private static let refreezeAfter: TimeInterval = 180
    /// 这次停留期间**滚进过屏幕**的新结果。离开页面时一次性写库。
    ///
    /// 不在滚到的当场写：写库会触发 @Query 刷新、进而重建快照，
    /// 等于一边滚一边让列表在手底下变。
    @State private var seenThisVisit: Set<String> = []

    @Environment(\.scenePhase) private var scenePhase

    /// 首屏一共画这么多张。一张电子票是一整块带号码球的卡片，
    /// 几十上百张一次性铺开，进票夹那一下明显要卡。
    static let previewLimit = 12
    /// 分区配额。一刀切 prefix 的话，新结果一多就把历史全挤出首屏，
    /// 反过来等开奖攒了十几张时，用户连昨晚的结果都看不到。
    static let waitingQuota = 5
    static let freshQuota = 5

    private var previewCards: [TicketCard] {
        guard filter == .all else { return Array(visibleCards.prefix(Self.previewLimit)) }
        var taken: [TicketCard] = []
        var used: [TicketCard.Zone: Int] = [:]
        // 先按配额收新结果和等开奖，剩下的名额留给历史
        for card in visibleCards where zone(of: card) != .history {
            let here = zone(of: card)
            let quota = here == .waiting ? Self.waitingQuota : Self.freshQuota
            guard used[here, default: 0] < quota else { continue }
            used[here, default: 0] += 1
            taken.append(card)
        }
        for card in visibleCards where zone(of: card) == .history {
            guard taken.count < Self.previewLimit else { break }
            taken.append(card)
        }
        // visibleCards 本来就是按分区排好的，所以 taken 的顺序天然是对的
        return taken
    }

    private var overflowCount: Int {
        Swift.max(visibleCards.count - previewCards.count, 0)
    }

    /// 这张卡这次停留期间显示在哪一区。冻结过就按冻结的来。
    private func zone(of card: TicketCard) -> TicketCard.Zone {
        frozenZone[card.id] ?? card.zone
    }

    /// 每一区各有多少张（分区标题上的数字要的是**全部**，不是首屏那几张）。
    private var zoneTotals: [TicketCard.Zone: Int] {
        visibleCards.reduce(into: [:]) { $0[zone(of: $1), default: 0] += 1 }
    }

    /// 首屏要画的东西：卡片，外加分区之间插进去的标题。
    private var previewRows: [WalletRow] {
        guard filter == .all else { return previewCards.map { .card($0) } }
        let totals = zoneTotals
        var rows: [WalletRow] = []
        var current: TicketCard.Zone?
        for card in previewCards {
            let here = zone(of: card)
            if here != current {
                current = here
                rows.append(.header(here, totals[here] ?? 0))
            }
            rows.append(.card(card))
        }
        return rows
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    filterBar
                    if visibleCards.isEmpty {
                        emptyState
                    } else {
                        ForEach(previewRows) { row in
                            switch row {
                            case let .header(zone, total):
                                zoneHeader(zone, total: total)
                            case let .card(item):
                                ticketCard(item)
                                    // 滚进屏幕 = 用户有机会看到了。先记下来，
                                    // 离开页面时才真正写库。
                                    .onAppear {
                                        if item.isNewResult { seenThisVisit.insert(item.id) }
                                    }
                            }
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
            .refreshable {
                // **刷新过程中不能重建列表。**
                //
                // 原来在这里直接调 rebuild()，等于在下拉刷新还没结束时
                // 把 ScrollView 的内容整个换掉 —— 系统那个转圈控件跟着丢了状态，
                // 于是卡在顶上不收，非得手动往上推一把才复位。
                //
                // 现在只置一个标记：真正的重排交给 `.task(id:)`，
                // 等记录变化引发的那次正常重建顺带做掉。
                needsRefreeze = true
                commitSeen()
                await drawStore.refresh()
                // 下拉就是「再核对一遍」，和右上角那颗按钮同一件事，
                // 所以也给同样的结果提示，别让人以为什么都没发生。
                await recheck()
            }
            .task(id: RecordsToken(records)) { rebuild() }
            .onChange(of: filter) { _, _ in applyFilter() }
            // 进票夹时**有条件地**重排：第一次进来、或者离开够久了才重排。
            // 每次切回来都重排的话，去设置看一眼再回来，「新结果」那一区
            // 就当场空了 —— 用户根本没来得及看完。
            .onAppear {
                if let last = lastFreezeAt {
                    needsRefreeze = Date().timeIntervalSince(last) > Self.refreezeAfter
                } else {
                    needsRefreeze = true
                }
                rebuild()
            }
            .onDisappear { commitSeen() }
            .onChange(of: scenePhase) { _, phase in
                // 切到后台也算看完了这一轮，否则用户直接上划退出，已读就丢了
                if phase != .active {
                    commitSeen()
                    return
                }
                // 从后台回来是明确的「重新开始看」，这一次一定重排
                needsRefreeze = true
                rebuild()
            }
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
            // 传**全部**票进去，让那一页自己筛。只把当前筛选结果传进去的话，
            // 那一页顶上再放一排筛选就成了在筛选之后的结果里再筛，
            // 用户切到「已中奖」会发现什么都没有。
            WalletAllTicketsView(
                cards: cards,
                initialFilter: filter,
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
        let natural = TicketCard.orderForWallet(TicketCard.snapshot(records))
        if needsRefreeze {
            frozenRank = Dictionary(uniqueKeysWithValues:
                natural.enumerated().map { ($0.element.id, $0.offset) })
            frozenZone = Dictionary(uniqueKeysWithValues: natural.map { ($0.id, $0.zone) })
            needsRefreeze = false
            lastFreezeAt = Date()
        }
        let snapshot = applyFrozenOrder(natural)
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

    /// 把自然顺序按这次停留冻结下来的名次重排。
    ///
    /// 冻结名单里没有的（这一屏刚录进来的新票）排到最前面 —— 用户刚加完票，
    /// 期待它出现在最上面，而不是按开奖日插到某个中间位置。
    private func applyFrozenOrder(_ natural: [TicketCard]) -> [TicketCard] {
        guard !frozenRank.isEmpty else { return natural }
        return natural.enumerated().sorted { lhs, rhs in
            switch (frozenRank[lhs.element.id], frozenRank[rhs.element.id]) {
            case let (left?, right?): return left < right
            case (nil, _?): return true
            case (_?, nil): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// 把这次停留期间看过的新结果写进库。
    private func commitSeen() {
        guard !seenThisVisit.isEmpty else { return }
        let batch = seenThisVisit
        seenThisVisit = []
        RecordService(context: context, drawStore: drawStore).markResultsSeen(batchIds: batch)
    }

    private func zoneHeader(_ zone: TicketCard.Zone, total: Int) -> some View {
        HStack(spacing: 6) {
            Text(zone.title)
                .font(.subheadline.weight(.semibold))
            Text("\(total)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(zone.title)，共 \(total) 张")
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
                Text("扫描纸质彩票，或手动录入已经购买的号码 —— 右下角那颗加号就是入口")
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
            showToast("已删除这张票", symbol: "trash", feedback: .success)
        } catch {
            showToast("删除失败", symbol: "exclamationmark.triangle", feedback: .error)
        }
    }

    private func recheck(silent: Bool = false) async {
        isChecking = true
        defer { isChecking = false }
        await drawStore.loadAllHistories()
        let service = RecordService(context: context, drawStore: drawStore)
        guard let outcome = try? service.checkAll(records) else {
            if !silent { showToast("核对失败", symbol: "exclamationmark.triangle", feedback: .error) }
            return
        }
        // 中奖是这个 App 里最值得庆祝的一刻，静默刷新也要放烟花
        if outcome.won > 0 { celebrate() }
        guard !silent else { return }
        if outcome.checked == 0 {
            showToast("暂无可核对的新开奖")
        } else if outcome.won > 0 {
            showToast("核对 \(outcome.checked) 注 · 中奖 \(outcome.won) 注", symbol: "trophy.fill", feedback: .success)
        } else {
            showToast("已核对 \(outcome.checked) 注", feedback: .success)
        }
    }
}

/// 首屏列表里的一行：卡片，或者卡片之间的分区标题。
enum WalletRow: Identifiable {
    case header(TicketCard.Zone, Int)
    case card(TicketCard)

    var id: String {
        switch self {
        case let .header(zone, _): "zone-\(zone.rawValue)"
        case let .card(card): card.id
        }
    }
}

/// 完整电子票列表。票夹首屏只放前几张，其余在这里翻。
/// 完整票列表。
///
/// 这一页原来只是把票铺开，**顶上的筛选条没跟过来** —— 首页只放十张，
/// 真正要找一张票的时候恰恰是在这一页，反而没得筛。现在筛选比首页还多一档：
/// 除了状态，还能按彩种筛。
struct WalletAllTicketsView: View {
    let cards: [TicketCard]
    var initialFilter: WalletFilter = .all
    @Binding var expandedBatches: Set<String>
    let onDelete: (TicketCard) -> Void
    var onCelebrate: (() -> Void)?

    @Environment(DrawStore.self) private var drawStore
    @Environment(\.modelContext) private var context
    @State private var status: WalletFilter = .all
    @State private var game: GameKey?
    /// 和首屏一样：滚到过就算看过，离开这一页时统一写库。
    @State private var seenThisVisit: Set<String> = []

    /// 出现过的彩种。没买过的彩种不该占着筛选条。
    private var games: [GameKey] {
        GameKey.ordered.filter { key in cards.contains { $0.game == key } }
    }

    private var filtered: [TicketCard] {
        cards.filter { status.matches($0.status) && (game == nil || $0.game == game) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                filterBars
                if filtered.isEmpty {
                    ContentUnavailableView("没有符合条件的票", systemImage: "line.3.horizontal.decrease.circle")
                        .padding(.top, 40)
                }
                ForEach(filtered) { item in
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
                    .onAppear {
                        if item.isNewResult { seenThisVisit.insert(item.id) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .background(Palette.canvas)
        .navigationTitle("全部电子票")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { status = initialFilter }
        .onDisappear {
            guard !seenThisVisit.isEmpty else { return }
            let batch = seenThisVisit
            seenThisVisit = []
            RecordService(context: context, drawStore: drawStore).markResultsSeen(batchIds: batch)
        }
    }

    /// 两条筛选：状态一条，彩种一条。
    private var filterBars: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WalletFilter.allCases) { item in
                        let count = cards.reduce(0) { $0 + (item.matches($1.status) ? 1 : 0) }
                        chip(title: "\(item.label) \(count)",
                             isOn: status == item,
                             tint: item.tint) { status = item }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(title: "全部彩种", isOn: game == nil, tint: .accentColor) { game = nil }
                    ForEach(games) { key in
                        chip(title: key.label, isOn: game == key, tint: key.tint) { game = key }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
        .animation(.easeOut(duration: 0.18), value: status)
        .animation(.easeOut(duration: 0.18), value: game)
        .padding(.bottom, 2)
    }

    private func chip(title: String, isOn: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(0.06)),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
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

    /// 筛选芯片选中时的底色。「待核对」用提示黄，和票面上的状态标一致。
    var tint: Color {
        switch self {
        case .all: .accentColor
        case .pending: Palette.warning
        case .won: Palette.profit
        case .lost: Color.secondary
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
