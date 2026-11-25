import SwiftUI
import SwiftData
import UIKit

/// 票夹：一张实体票对应一条票据记录，按录入时间倒序。
struct WalletView: View {
    var isActive: Bool = true

    @Environment(DrawStore.self) private var drawStore
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var showToast
    @Environment(CelebrationCenter.self) private var celebrate
    @Query(sort: \TicketRecord.createdAt, order: .reverse) private var records: [TicketRecord]

    @State private var filter: WalletFilter = .all
    @State private var expandedBatches: Set<String> = []
    @State private var isChecking = false
    /// 正在修改的那张票。
    @State private var editTarget: EntryDraft?
    /// 渲染快照。记录变化时算一次，之后渲染完全不碰 SwiftData 对象。
    @State private var cards: [TicketCard] = []
    @State private var counts: [WalletFilter: Int] = [:]
    /// 筛选结果也存下来。放在 body 里当计算属性的话，每帧都要把全部票据过一遍。
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

    /// 首屏一共画这么多张。一张票据是一整块带号码球的卡片，
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

    /// 首屏要画的分组：每个分区作为独立 `Section`，配合 `pinnedViews: [.sectionHeaders]`
    /// 实现类似 Telegram 的动态吸顶效果（上滑时当前分组固定在筛选条下方，下一组到达时顺滑顶走）。
    private var previewSections: [WalletSection] {
        guard filter == .all else { return [] }
        let totals = zoneTotals
        var sections: [WalletSection] = []
        for card in previewCards {
            let here = zone(of: card)
            if sections.last?.zone == here {
                sections[sections.count - 1].cards.append(card)
            } else {
                sections.append(WalletSection(zone: here, total: totals[here] ?? 0, cards: [card]))
            }
        }
        return sections
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // LazyVStack 间距设为 0，把卡片间距收进各 Section 内部：
                // 这样下一组吸顶胶囊会先紧贴上一组胶囊下沿，再 1:1 顺滑顶走，不再隔着一大段空白提前顶跑。
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if visibleCards.isEmpty {
                        emptyState
                    } else if filter == .all {
                        ForEach(previewSections) { section in
                            Section {
                                ForEach(Array(section.cards.enumerated()), id: \.element.id) { index, item in
                                    let isLast = index == section.cards.count - 1
                                    ticketCard(item)
                                        .padding(.top, index == 0 ? 8 : 12)
                                        .padding(.bottom, isLast ? 14 : 0)
                                        // 滚进屏幕 = 用户有机会看到了。先记下来，
                                        // 离开页面时才真正写库。
                                        .onAppear {
                                            if isActive && item.isNewResult { seenThisVisit.insert(item.id) }
                                        }
                                }
                            } header: {
                                WalletZoneHeader(zone: section.zone, total: section.total)
                            }
                        }
                        if overflowCount > 0 { moreButton }
                    } else {
                        ForEach(Array(previewCards.enumerated()), id: \.element.id) { index, item in
                            ticketCard(item)
                                .padding(.top, index == 0 ? 6 : 12)
                                .onAppear {
                                    if isActive && item.isNewResult { seenThisVisit.insert(item.id) }
                                }
                        }
                        if overflowCount > 0 {
                            moreButton
                                .padding(.top, 12)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                WalletFilterGlassBar(selection: $filter, counts: counts)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(Palette.canvas)
            // 导航栏不要自己糊底色，交给系统的 scroll edge effect。
            // 理由见 `HomeView` 里同一处那段注释。
            // 只要导航栏里那行小标题，不要页面上的大标题：大标题把内容往下压了一大截。
            // 小标题得留着 —— 往下滑的时候顶上要有一条带标题的栏，和设置页一样。
            .navigationTitle("票夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await recheck() }
                    } label: {
                        if isChecking {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                                .foregroundStyle(.primary)
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
                // 下拉就是「再核对一遍」，和右上角那颗按钮同一件事，
                // 所以也给同样的结果提示，别让人以为什么都没发生。
                await recheck()
            }
            // 修改用的是录入页那套完整工作台，保存后照常按 RecordsToken 重排。
            .sheet(item: $editTarget) { draft in
                EntryFlowView(draft: draft)
            }
            .task(id: RecordsToken(records)) { rebuild() }
            .onChange(of: filter) { _, _ in applyFilter() }
            // 进票夹时**有条件地**重排：第一次进来、或者离开够久了才重排。
            // 每次切回来都重排的话，去设置看一眼再回来，「新结果」那一区
            // 就当场空了 —— 用户根本没来得及看完。
            .onAppear {
                guard isActive else { return }
                handleActivate()
            }
            .onDisappear { commitSeen() }
            .onChange(of: isActive) { _, active in
                if active {
                    handleActivate()
                } else {
                    commitSeen()
                }
            }
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

    private func handleActivate() {
        if let last = lastFreezeAt {
            needsRefreeze = Date().timeIntervalSince(last) > Self.refreezeAfter
        } else {
            needsRefreeze = true
        }
        rebuild()
        for card in previewCards where card.isNewResult {
            seenThisVisit.insert(card.id)
        }
    }

    private func ticketCard(_ item: TicketCard) -> some View {
        WalletTicketCard(
            card: item,
            isExpanded: expandedBatches.contains(item.id),
            onToggle: { toggle(item.id) },
            onDelete: { delete(item) },
            onEdit: { editTarget = EntryDraft.load(batchId: item.id, context: context) },
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
                onDelete: delete
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
            .contentCard(cornerRadius: 18, padding: 14)
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

    /// 空状态要分清是「一张票都没有」还是「筛选之后没有」。
    /// 原来两种情况都说"票夹是空的 / 添加彩票"，用户会以为记录丢了。
    @ViewBuilder
    private var emptyState: some View {
        if cards.isEmpty {
            ContentUnavailableView {
                Label("票夹是空的", systemImage: "wallet.bifold")
            } description: {
                Text("拍下你手里的实体票，或照着票面手动录入 —— 右下角那颗圆形扫描按钮就是入口")
            }
            .padding(.top, 50)
        } else {
            ContentUnavailableView {
                Label("没有\(filter.label)的票", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("这里只显示\(filter.label)的票据，切回「全部」可以看到其余 \(cards.count) 张。")
            } actions: {
                Button("查看全部") {
                    withAnimation(.easeOut(duration: 0.18)) { filter = .all }
                }
                .buttonStyle(SecondaryGlassButton(tint: .primary))
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
        guard !isChecking else { return }
        isChecking = true
        drawStore.checkingWallet = true
        defer { isChecking = false; drawStore.checkingWallet = false }
        let service = RecordService(context: context, drawStore: drawStore)
        await drawStore.refresh(force: true)
        _ = try? service.reconcileInferredTargets()
        let since = RecordService.recheckSince(Date())
        let today = DateText.day(Date())
        let targets = service.allRecords().filter {
            $0.targetOpenDate <= today && ($0.status == .pending || $0.status == .prizeFloat ||
                ($0.status == .won && $0.targetOpenDate >= since))
        }
        for (game, tickets) in Dictionary(grouping: targets, by: \.game) {
            await drawStore.loadRecent(for: game, force: true)
            let years = Set(tickets.compactMap { record -> Int? in
                let day = record.targetOpenDate.isEmpty ? DateText.day(record.createdAt) : record.targetOpenDate
                guard day < since || drawStore.draw(matching: record) == nil && day < today else { return nil }
                return Int(day.prefix(4))
            })
            for year in years { await drawStore.loadYear(for: game, year: year, force: true) }
        }
        guard let outcome = try? service.checkAll() else {
            if !silent { showToast("核对失败", symbol: "exclamationmark.triangle", feedback: .error) }
            return
        }
        rebuild()
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

/// 票夹列表里的一个吸顶分区（等开奖 / 新结果 / 已看过）。
private struct WalletSection: Identifiable {
    let zone: TicketCard.Zone
    let total: Int
    var cards: [TicketCard]

    var id: TicketCard.Zone { zone }
}

/// Telegram 风格动态吸顶液态玻璃分组角标：采用官方 `.regular` 玻璃材质（规避 `.clear` 在浅色画布上
/// 触发真机亮度压暗的问题），紧凑上下留白让下一组紧贴前一组后再 1:1 顺滑顶走。
private struct WalletZoneHeader: View {
    let zone: TicketCard.Zone
    let total: Int

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(zone.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(total)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassPill(interactive: false)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(zone.title)，共 \(total) 张")
    }
}

/// 完整票据列表。票夹首屏只放前几张，其余在这里翻。
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

    @Environment(DrawStore.self) private var drawStore
    @Environment(\.modelContext) private var context
    @State private var editTarget: EntryDraft?
    @State private var status: WalletFilter = .all
    @State private var game: GameKey?
    /// 和首屏一样：滚到过就算看过，离开这一页时统一写库。
    @State private var seenThisVisit: Set<String> = []

    /// 出现过的彩种。没买过的彩种不该占着筛选条。
    private var games: [GameKey] {
        GameKey.ordered.filter { key in cards.contains { $0.game == key } }
    }

    private var statusCounts: [WalletFilter: Int] {
        var tally: [WalletFilter: Int] = [:]
        for item in WalletFilter.allCases {
            tally[item] = item == .all ? cards.count : cards.reduce(0) { $0 + (item.matches($1.status) ? 1 : 0) }
        }
        return tally
    }

    private var filtered: [TicketCard] {
        cards.filter { status.matches($0.status) && (game == nil || $0.game == game) }
    }

    private var filteredSections: [WalletSection] {
        guard status == .all else { return [] }
        var sections: [WalletSection] = []
        for card in filtered {
            if sections.last?.zone == card.zone {
                sections[sections.count - 1].cards.append(card)
            } else {
                sections.append(WalletSection(zone: card.zone, total: 0, cards: [card]))
            }
        }
        return sections.map { WalletSection(zone: $0.zone, total: $0.cards.count, cards: $0.cards) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if filtered.isEmpty {
                    ContentUnavailableView("没有符合条件的票", systemImage: "line.3.horizontal.decrease.circle")
                        .padding(.top, 40)
                } else if status == .all {
                    ForEach(filteredSections) { section in
                        Section {
                            ForEach(Array(section.cards.enumerated()), id: \.element.id) { index, item in
                                let isLast = index == section.cards.count - 1
                                allTicketRow(item)
                                    .padding(.top, index == 0 ? 8 : 12)
                                    .padding(.bottom, isLast ? 14 : 0)
                            }
                        } header: {
                            WalletZoneHeader(zone: section.zone, total: section.total)
                        }
                    }
                } else {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        allTicketRow(item)
                            .padding(.top, index == 0 ? 6 : 12)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                WalletFilterGlassBar(selection: $status, counts: statusCounts)
                    .padding(.horizontal, 16)
                if games.count > 1 {
                    gameFilterBar
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Palette.canvas)
        .sheet(item: $editTarget) { draft in
            EntryFlowView(draft: draft)
        }
        .navigationTitle("全部票据")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { status = initialFilter }
        .onDisappear {
            guard !seenThisVisit.isEmpty else { return }
            let batch = seenThisVisit
            seenThisVisit = []
            RecordService(context: context, drawStore: drawStore).markResultsSeen(batchIds: batch)
        }
    }

    private func allTicketRow(_ item: TicketCard) -> some View {
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
            onEdit: { editTarget = EntryDraft.load(batchId: item.id, context: context) },
            draw: drawStore.draw(for: item.game, expect: item.expect)
        )
        .onAppear {
            if item.isNewResult { seenThisVisit.insert(item.id) }
        }
    }

    private var gameFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    gameChip(title: "全部彩种", isOn: game == nil, tint: .primary) {
                        game = nil
                    }
                    ForEach(games) { key in
                        gameChip(title: key.label, isOn: game == key, tint: key.tint) {
                            game = key
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
        }
        .scrollClipDisabled()
        .animation(.easeOut(duration: 0.2), value: game)
    }

    private func gameChip(title: String,
                          isOn: Bool,
                          tint: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isOn ? tint : Color.primary.opacity(0.84))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .glassPill(tint: isOn ? tint : nil, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// 票夹顶部官方液态玻璃四合一筛选条：
/// 恢复原生 `UISegmentedControl`（`TallSegmentedControl`）+ 官方 `.regular` 玻璃外框，
/// 保持默认中性选中透镜（不覆写 `selectedSegmentTintColor`），完整保留官方液态跳动手感、
/// 零蓝色填充、零切色闪烁，同时彻底消除 `.clear` 嵌套玻璃导致的票夹页面真机发暗问题。
struct WalletFilterGlassBar: View {
    @Binding var selection: WalletFilter
    let counts: [WalletFilter: Int]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WalletFilterSegmentedControl(
            selection: $selection,
            counts: counts,
            colorScheme: colorScheme
        )
        .frame(height: 40)
        .glassPill(interactive: false)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private struct WalletFilterSegmentedControl: UIViewRepresentable {
    @Binding var selection: WalletFilter
    let counts: [WalletFilter: Int]
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> TallSegmentedControl {
        let titles = WalletFilter.allCases.map { "\($0.label) \(counts[$0] ?? 0)" }
        let control = TallSegmentedControl(items: titles)
        control.targetHeight = 40
        control.apportionsSegmentWidthsByContent = true
        control.backgroundColor = .clear
        control.accessibilityIdentifier = "wallet.filter.bar"
        control.selectedSegmentIndex = WalletFilter.allCases.firstIndex(of: selection) ?? 0
        control.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        applyTypography(to: control)
        return control
    }

    func updateUIView(_ uiView: TallSegmentedControl, context: Context) {
        context.coordinator.parent = self
        for (index, item) in WalletFilter.allCases.enumerated() {
            let title = "\(item.label) \(counts[item] ?? 0)"
            if uiView.titleForSegment(at: index) != title {
                uiView.setTitle(title, forSegmentAt: index)
            }
        }
        let targetIndex = WalletFilter.allCases.firstIndex(of: selection) ?? 0
        if uiView.selectedSegmentIndex != targetIndex {
            uiView.selectedSegmentIndex = targetIndex
        }
        applyTypography(to: uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TallSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 340, height: 40)
    }

    private func applyTypography(to control: TallSegmentedControl) {
        let isDark = colorScheme == .dark
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        traits.performAsCurrent {
            control.selectedSegmentTintColor = nil
            let normalFont = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            let selectedFont = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            control.setTitleTextAttributes([
                .font: normalFont,
                .foregroundColor: UIColor.label.withAlphaComponent(0.76)
            ], for: .normal)
            control.setTitleTextAttributes([
                .font: selectedFont,
                .foregroundColor: UIColor.label
            ], for: .selected)
        }
    }

    final class Coordinator: NSObject {
        var parent: WalletFilterSegmentedControl

        init(_ parent: WalletFilterSegmentedControl) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: UISegmentedControl) {
            let index = sender.selectedSegmentIndex
            guard WalletFilter.allCases.indices.contains(index) else { return }
            withAnimation(.spring(duration: 0.30, bounce: 0.14)) {
                parent.selection = WalletFilter.allCases[index]
            }
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

    /// 筛选芯片选中时的底色。「待核对」用提示黄，和票面上的状态标一致。
    var tint: Color {
        switch self {
        case .all: .primary
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
