import SwiftUI
import SwiftData
import Charts

/// 记录集合的变化指纹。
///
/// 统计、分组这类重活只在指纹变化时算一次，算完存进 @State。
/// 千万别写成 body 里的计算属性 —— body 一次求值会访问它很多次，
/// 每次都会把全部记录重算一遍，记录一多就直接卡死主线程。
struct RecordsToken: Equatable {
    let count: Int
    let latest: Date

    init(_ records: [TicketRecord]) {
        count = records.count
        var newest = Date.distantPast
        for record in records where record.updatedAt > newest { newest = record.updatedAt }
        latest = newest
    }
}

struct HomeView: View {
    var onOpenEntry: () -> Void
    var onOpenScan: () -> Void

    @Environment(DrawStore.self) private var drawStore
    @Query(sort: \TicketRecord.createdAt, order: .reverse) private var records: [TicketRecord]

    @State private var range: ProfitRange = .all
    @State private var series = ProfitSeries()
    @State private var monthStats = ProfitStats.PeriodStats()
    @State private var carouselIndex = 0
    /// 自动轮播暂停到什么时候。用户一滑就往后推 12 秒。
    @State private var autoScrollResumeAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrawSheetPresented = false
    /// 点开奖卡片上的省略球时，把整期号码摊开给用户看。
    @State private var expandedDraw: Draw?

    /// 开奖日程也不能在 body 里算。`todayOpenGames` / `pendingDrawUpdates` /
    /// `carouselOrder` 每次都要取一遍东八区时间、过一遍八个彩种，
    /// 而 body 在滚动时一秒会跑很多次。统一在数据变化时算好存下来。
    @State private var todayGames: Set<GameKey> = []
    @State private var pendingGames: [GameKey] = []
    @State private var carouselGames: [GameKey] = GameKey.ordered

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    profitCard
                    latestDrawSection
                    monthlyCard
                    if !pendingGames.isEmpty { pendingNotice }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 120)
            }
            .background(Palette.canvas)
            .navigationTitle("首页")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        StatsView()
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .accessibilityLabel("统计")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                FloatingActionButtons(onScan: onOpenScan, onAdd: onOpenEntry)
            }
            .refreshable { await drawStore.refresh() }
            .task(id: RecordsToken(records)) { recompute() }
            .task(id: drawStore.scheduleToken) { refreshSchedule() }
            .onChange(of: range) { _, _ in recomputeSeries() }
        }
    }

    // MARK: - 派生数据

    @State private var entries: [SettledEntry] = []

    private func recompute() {
        entries = ProfitStats.snapshot(records)
        recomputeSeries()
        let now = Date()
        let year = Calendar.chinaCalendar.component(.year, from: now)
        let month = Calendar.chinaCalendar.component(.month, from: now)
        monthStats = ProfitStats.period(entries: ProfitStats.snapshotAll(records), year: year, month: month)
    }

    private func recomputeSeries() {
        series = ProfitStats.series(entries: entries, range: range)
    }

    private func refreshSchedule() {
        todayGames = Set(drawStore.todayOpenGames())
        pendingGames = drawStore.pendingDrawUpdates()
        let order = drawStore.carouselOrder()
        carouselGames = order
        // 轮播顺序会随「今天开哪个彩种」变化，旧的下标可能越界，
        // 越界后 TabView 会白屏一页。
        if carouselIndex >= order.count { carouselIndex = 0 }
    }

    // MARK: - 累计盈亏

    private var profitCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("累计盈亏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(MoneyText.format(series.netTotal))
                        // 大号字要收紧字距 —— 字号越大，字母间那点默认间隙看着越松。
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .tracking(-0.8)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(Palette.profitColor(series.netTotal))
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                Picker("范围", selection: $range) {
                    ForEach(ProfitRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(.secondary)
                .fixedSize()
            }

            ProfitHeatmap(days: series.days, range: range)

            Divider()

            HStack(alignment: .top, spacing: 8) {
                statPair("投入", MoneyText.format(series.costTotal))
                statPair("奖金", MoneyText.format(series.prizeTotal))
                // 公益金：彩票面额的 36% 计提，这部分钱是确定流向公益事业的
                statPair("公益金", MoneyText.format(series.costTotal * 0.36))
                statPair("已结算", "\(series.settledCount) 注")
            }
        }
        .contentCard()
    }

    private func statPair(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 最新开奖

    private var latestDrawSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: "最新开奖",
                subtitle: drawStore.latestUpdatedAt.isEmpty
                    ? "暂无更新时间"
                    : "更新于 \(DateText.friendly(drawStore.latestUpdatedAt))",
                action: { isDrawSheetPresented = true }
            )

            TabView(selection: $carouselIndex) {
                ForEach(Array(carouselGames.enumerated()), id: \.element) { index, game in
                    DrawCard(game: game,
                             draw: drawStore.latestDraw(for: game),
                             opensToday: todayGames.contains(game),
                             onExpandNumbers: { expandedDraw = drawStore.latestDraw(for: game) })
                        // 分页是整屏宽翻的，卡片自己不留边就会和下一张严丝合缝地
                        // 贴在一起，滑动时看起来像一整条在动，分不出是两张卡。
                        .padding(.horizontal, 5)
                        .tag(index)
                }
            }
            // 系统自带的分页圆点画在 TabView 的画布里，会压在卡片下沿上。
            // 关掉它自己画一排放到卡片外面，既不重叠也能控制配色。
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 140)
            .accessibilityHint("左右滑动查看其他彩种的最新开奖")
            // 手一碰就停自动轮播。轮播抢走用户正在看的那张卡是很讨厌的事。
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                autoScrollResumeAt = Date().addingTimeInterval(12)
            })
            .task(id: carouselGames.count) { await runAutoScroll() }

            pageDots
        }
        .sheet(isPresented: $isDrawSheetPresented) {
            DrawHistoryView()
        }
        .sheet(item: $expandedDraw) { draw in
            DrawNumbersSheet(draw: draw)
        }
    }

    /// 开奖卡片自动轮播。
    ///
    /// 减弱动效下**完全不转** —— 自动播放的轮播是无障碍里最经典的问题之一，
    /// 对前庭敏感和阅读较慢的用户都是干扰。
    private func runAutoScroll() async {
        guard !reduceMotion, carouselGames.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, Date() >= autoScrollResumeAt else { continue }
            withAnimation(.easeInOut(duration: 0.45)) {
                carouselIndex = (carouselIndex + 1) % carouselGames.count
            }
        }
    }

    /// 自己画的分页指示器。
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(carouselGames.enumerated()), id: \.element) { index, game in
                Capsule()
                    .fill(index == carouselIndex ? game.tint : Color.primary.opacity(0.18))
                    .frame(width: index == carouselIndex ? 16 : 6, height: 6)
                    .animation(.spring(duration: 0.3, bounce: 0), value: carouselIndex)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    /// 今天到点了但号码还没更新的彩种。原来这条挤在页面最顶上，
    /// 大多数时候是空的却仍占着位置；挪到页尾当一条轻提示。
    private var pendingNotice: some View {
        Label("今日\(pendingGames.map(\.label).joined(separator: "、"))的开奖号码尚未更新",
              systemImage: "clock.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(Palette.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - 本月概览

    private var monthlyCard: some View {
        let month = Calendar.chinaCalendar.component(.month, from: Date())
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "\(month) 月概览", subtitle: "本机记录 · \(monthStats.ticketCount) 注")

            // 盈亏是这张卡的主角，单独占一行给足字号；
            // 投入和奖金退到下面一行当支撑数据。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MoneyText.format(monthStats.net))
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .tracking(-0.5)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Palette.profitColor(monthStats.net))
                if monthStats.ticketCount > 0 {
                    Text(monthStats.net >= 0 ? "盈利" : "亏损")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if monthStats.ticketCount > 0 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("中奖率")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", monthStats.winRate))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                    }
                }
            }

            HStack(spacing: 10) {
                miniStat("投入", MoneyText.format(monthStats.cost), "arrow.down.circle.fill", .secondary)
                miniStat("奖金", MoneyText.format(monthStats.prize), "trophy.fill", Palette.profit)
            }

            if monthStats.byGame.isEmpty {
                Text("这个月还没有记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                Divider()
                // 原来是一张横向柱状图，只能看出长短。换成一条占比色带
                // 加一份明细，金额和比例都直接写出来。
                SpendBreakdown(items: monthStats.byGame, total: monthStats.cost)
            }
        }
        .contentCard()
    }

    private func miniStat(_ title: String, _ value: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 盈亏热力图

/// 逐日盈亏方格图。
///
/// 换掉原来的折线图：买彩票长期期望为负，折线永远是一条从左上到右下的
/// 45° 斜坡，看一次就没有信息量了。方格图把「哪天买了、那天是赚是亏、
/// 亏了多少」摊开成一张图，密度和节奏本身就是信息。
struct ProfitHeatmap: View {
    let days: [ProfitDay]
    let range: ProfitRange

    /// 一格的边长和间距。7 行（一周七天）纵向排，按周横向铺开。
    private let cell: CGFloat = 13
    private let gap: CGFloat = 3

    /// 有记录的那些天。
    private var byDay: [String: ProfitDay] {
        var map: [String: ProfitDay] = [:]
        for day in days where day.count > 0 { map[day.date] = day }
        return map
    }

    /// 一天的颜色浓度，0…1。
    ///
    /// **不用全局最大值归一化。** 大多数人每天投入是差不多的，一年里偶尔
    /// 一两天多买了几倍，用全局最大值当刻度就会把其余三百多天全压成浅色 ——
    /// 图上只剩一两个深格子，其他全是几乎看不见的淡色。
    ///
    /// 改成按**当天自己的投入**归一化：
    /// - 亏损侧：亏掉了当天投入的百分之多少。**全亏 = 满色**，这也是最常见的情况，
    ///   所以「买了没中」的日子颜色是齐的，不会互相压。
    /// - 盈利侧：赚了当天投入的几倍，走对数刻度 —— 小赚和大赚要能分出来，
    ///   但小赚也不能一下就满色。赚到 9 倍投入封顶。
    private func intensity(for day: ProfitDay) -> Double {
        let base = Swift.max(day.cost, 1)
        if day.net < 0 {
            return Swift.min(abs(day.net) / base, 1)
        }
        if day.net == 0 { return 0.22 }
        return Swift.min(log(1 + day.net / base) / log(10.0), 1)
    }

    /// 图上要画的日期区间，按周对齐（每列是完整一周，周一起头）。
    private var weeks: [[Date?]] {
        let calendar = Calendar.chinaCalendar
        let today = Date()
        guard let start = calendar.date(byAdding: .day, value: -(range.gridSpan - 1), to: today) else { return [] }

        // 回退到那一周的周一，列才不会错位
        let weekdayIndex = (calendar.component(.weekday, from: start) + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -weekdayIndex, to: start) else { return [] }

        var columns: [[Date?]] = []
        var cursor = gridStart
        while cursor <= today {
            var column: [Date?] = []
            for _ in 0..<7 {
                column.append(cursor <= today ? cursor : nil)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            columns.append(column)
        }
        return columns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: gap) {
                            ForEach(Array(column.enumerated()), id: \.offset) { _, date in
                                cellView(for: date)
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            // 从右往左看更符合「最近的在手边」，默认停在最新的一周
            .defaultScrollAnchor(.trailing)

            legend
        }
        .frame(height: cell * 7 + gap * 6 + 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("逐日盈亏方格图，共 \(byDay.count) 天有记录")
    }

    @ViewBuilder
    private func cellView(for date: Date?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        if let date, let day = byDay[DateText.day(date)] {
            shape
                .fill(color(for: day))
                .frame(width: cell, height: cell)
        } else if date != nil {
            shape
                .fill(Color.primary.opacity(0.06))
                .frame(width: cell, height: cell)
        } else {
            Color.clear.frame(width: cell, height: cell)
        }
    }

    /// 赚的日子偏红、亏的日子偏绿，浓度按 `intensity` 算。
    /// 最低透明度留 0.30，否则小额那天几乎和空格子分不出来。
    private func color(for day: ProfitDay) -> Color {
        let level = 0.30 + 0.70 * intensity(for: day)
        return (day.net >= 0 ? Palette.profit : Palette.loss).opacity(level)
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("全亏")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            ForEach([1.0, 0.55, 0.25], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.loss.opacity(0.30 + 0.70 * level))
                    .frame(width: 9, height: 9)
            }
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 9, height: 9)
            ForEach([0.25, 0.55, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.profit.opacity(0.30 + 0.70 * level))
                    .frame(width: 9, height: 9)
            }
            Text("大赚")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let best = days.filter({ $0.count > 0 }).max(by: { $0.net < $1.net }), best.net > 0 {
                Text("最好的一天 \(MoneyText.format(best.net))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 花费占比

/// 一条占比色带 + 明细。金额和百分比都直接写出来，不用去比柱子长短。
struct SpendBreakdown: View {
    let items: [GameSpend]
    let total: Double
    /// 明细最多列几行，其余并进「其他」。
    var limit: Int = 4

    private var visible: [GameSpend] { Array(items.prefix(limit)) }
    private var otherCost: Double {
        items.dropFirst(limit).reduce(0) { $0 + $1.cost }
    }

    private func share(_ cost: Double) -> Double {
        total > 0 ? cost / total : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(items) { item in
                        Capsule()
                            .fill(item.game.tint)
                            .frame(width: Swift.max(proxy.size.width * share(item.cost) - 2, 3))
                    }
                }
            }
            .frame(height: 8)

            VStack(spacing: 7) {
                ForEach(visible) { item in
                    row(color: item.game.tint,
                        label: item.game.label,
                        detail: "\(item.count) 注",
                        cost: item.cost)
                }
                if otherCost > 0 {
                    row(color: .secondary,
                        label: "其他 \(items.count - limit) 个彩种",
                        detail: "",
                        cost: otherCost)
                }
            }
        }
    }

    private func row(color: Color, label: String, detail: String, cost: Double) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.footnote)
                .lineLimit(1)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(String(format: "%.0f%%", share(cost) * 100))
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(MoneyText.format(cost))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 62, alignment: .trailing)
        }
    }
}

// MARK: - 开奖卡

/// 首页轮播里的一张开奖卡。
///
/// 高度是抠出来的：标题、号码、一等奖三块之间原来各留了一大段空白，
/// 卡片被撑到近 200pt。现在固定成紧凑的三段式。
struct DrawCard: View {
    let game: GameKey
    let draw: Draw?
    /// 这个彩种今天开奖。原来「今日开奖」是页面顶部单独一行标签，
    /// 和它描述的卡片隔得很远；写进卡片里既更省地方也更好懂。
    var opensToday: Bool = false
    var onExpandNumbers: (() -> Void)?

    /// 首页每个号码区最多画 8 颗球。快乐8 一期开 20 个，
    /// 全画出来要么撑爆卡片要么缩到看不清。
    private let ballLimit = 8
    private let ballSize: CGFloat = 32

    private var firstPrize: PrizeEntry? {
        guard let entry = draw?.firstPrize, entry.winningCount > 0 || entry.amount > 0 else { return nil }
        return entry
    }

    var body: some View {
        // 三段各归各位：标题顶格、号码居中、一等奖贴底。
        // 早期版本把整组内容在卡片里垂直居中，结果标题浮在半空，
        // 而且卡片高度一固定，号码一换行就会压到一等奖那一行上。
        VStack(alignment: .leading, spacing: 8) {
            header
            Spacer(minLength: 0)
            numbersRow
            Spacer(minLength: 0)
            if let firstPrize {
                prizeStrip(firstPrize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.card)
        )
    }

    /// 号码那一行。
    ///
    /// **必须保证不换行。** 卡片高度是固定的（轮播要求各页等高），
    /// 一旦号码排到第二行就会盖住一等奖那一行 —— 快乐8 尤其明显：
    /// 8 颗球加一颗省略球，按 32pt 画出来正好比卡片可用宽度多十几个点。
    /// 所以这里先量出可用宽度，再反推一个能把所有球放进一行的球径。
    @ViewBuilder
    private var numbersRow: some View {
        if let draw {
            GeometryReader { proxy in
                let size = fittingBallSize(for: draw, width: proxy.size.width)
                DrawNumbersView(draw: draw, size: size, limit: ballLimit, onOverflow: onExpandNumbers)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            }
            .frame(height: ballSize)
        } else {
            Text("暂无开奖数据")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: ballSize)
        }
    }

    /// 一行放得下的最大球径。系数和 `BallFlow` 里的间距一致：
    /// 球间 0.19 倍球径，号码区之间再多 0.24 倍。
    private func fittingBallSize(for draw: Draw, width: CGFloat) -> CGFloat {
        var balls = 0
        var sections = 0
        for section in draw.gameKey.drawSections {
            let all = draw.drawValues[section.key]
            guard !all.isEmpty else { continue }
            balls += Swift.min(all.count, ballLimit)
            if all.count > ballLimit { balls += 1 }   // 省略球也占一颗的位置
            sections += 1
        }
        guard balls > 0, width > 0 else { return ballSize }
        let units = CGFloat(balls)
            + CGFloat(balls - 1) * 0.19
            + CGFloat(Swift.max(sections - 1, 0)) * 0.24
        return Swift.min(ballSize, (width / units).rounded(.down))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(game.tint)
                .frame(width: 8, height: 8)
            Text(game.label)
                .font(.headline)

            if opensToday {
                Text("今日开奖")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.live)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.live.opacity(0.14), in: Capsule())
            }

            Spacer(minLength: 6)
            if let draw {
                Text("\(draw.expect) · \(DateText.monthDay(draw.openDate))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// 一等奖那一行。信息密度最高的「单注奖金」要被强调出来。
    private func prizeStrip(_ entry: PrizeEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 10))
                .foregroundStyle(game.tint)
            Text("一等奖 \(entry.winningCount) 注")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if entry.amount > 0 {
                Text(MoneyText.compactYuan(entry.amount))
                    .font(.system(.footnote, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(game.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("/注")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 展开一期的全部开奖号码。快乐8 那 20 个号在卡片上放不下，
/// 点省略球就弹这个。
struct DrawNumbersSheet: View {
    let draw: Draw
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(draw.gameKey.drawSections) { section in
                        let values = draw.drawValues[section.key]
                        if !values.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Text(section.label)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(section.color.accentColor)
                                    Text("\(values.count) 个")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                // 球径和其他彩种一致，放不下就换行
                                BallFlow(spacing: 7, lineSpacing: 9) {
                                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                                        BallView(value: value, color: section.color, size: 34,
                                                 padded: section.range.upperBound > 9)
                                    }
                                }
                            }
                            .contentCard()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            .background(Palette.canvas)
            .navigationTitle("\(draw.gameKey.label) 第 \(draw.expect) 期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
