import SwiftUI
import SwiftData
import Charts
import UIKit

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

    @Environment(DrawStore.self) private var drawStore
    @Query(sort: \TicketRecord.createdAt, order: .reverse) private var records: [TicketRecord]

    @State private var range: ProfitRange = .all
    @State private var series = ProfitSeries()
    @State private var monthStats = ProfitStats.PeriodStats()
    @State private var carouselIndex = 0
    /// TabView 的真实页码。首尾各多挂一张哨兵页（末卡的副本放在最前、
    /// 首卡的副本放在最后），滑到哨兵页上再无动画地跳回对应的真页，
    /// 这样最后一张往右滑就能接回第一张。
    @State private var pageIndex = 1
    /// 自动轮播暂停到什么时候。用户一滑就往后推 12 秒。
    @State private var autoScrollResumeAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrawSheetPresented = false
    /// 点开奖卡片上的省略球时，把整期号码摊开给用户看。

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
            // **导航栏必须有底色。**
            //
            // 首页 / 票夹 / 设置是全 App 仅有的三个大标题页面，而
            // `Palette.canvas` 是加在 ScrollView 上的，导航栏本身是透明的。
            // 大标题往小标题收的过程中，标题文字底下没有任何遮挡，
            // 滚动的卡片会直接从它下面穿过去 —— 看起来就是「首页」两个字
            // 卡在卡片里。录入页和扫描页早就这么写了，这里补齐。
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
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
        if carouselIndex >= order.count || pageIndex > order.count + 1 || pageIndex < 0 {
            carouselIndex = 0
            pageIndex = 1
        }
    }

    // MARK: - 累计收支

    private var profitCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("累计收支")
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
                statPair("票面金额", MoneyText.format(series.costTotal))
                statPair("奖金", MoneyText.format(series.prizeTotal))
                // 公益金逐条按彩种计提，比例见 `GameKey.welfareRate` ——
                // 原来固定乘 0.36，八个彩种里五个是错的。
                statPair("公益金", MoneyText.format(series.welfareTotal))
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

            // 首尾各挂一张**哨兵页**，转成一个环：最后一张再往左滑就到第一张。
            //
            // `TabView` 的分页样式自己不会绕回去 —— 滑到最后一页再往左推，
            // 卡片只是弹一下，什么都不会发生。做法是在真页两头各放一张克隆页
            // （页 0 是最后一张的克隆，页 n+1 是第一张的克隆），
            // 用户滑到克隆页、翻页动画走完之后，**无动画地**跳到对应的真页。
            // 视觉上是连续的，用户感觉不到这一下。
            TabView(selection: $pageIndex) {
                ForEach(carouselPages, id: \.self) { page in
                    let game = carouselGames[realIndex(page)]
                    DrawCard(game: game,
                             draw: drawStore.latestDraw(for: game),
                             opensToday: todayGames.contains(game))
                        // 分页是整屏宽翻的，卡片自己不留边就会和下一张严丝合缝地
                        // 贴在一起，滑动时看起来像一整条在动，分不出是两张卡。
                        .padding(.horizontal, HomeLayout.carouselPagePadding)
                        .tag(page)
                }
            }
            .onChange(of: pageIndex) { _, page in
                carouselIndex = realIndex(page)
                wrapIfNeeded(page)
            }
            // 系统自带的分页圆点画在 TabView 的画布里，会压在卡片下沿上。
            // 关掉它自己画一排放到卡片外面，既不重叠也能控制配色。
            .tabViewStyle(.page(indexDisplayMode: .never))
            // 翻页动画绑在 TabView 上，而不是在 `runAutoScroll` 里用
            // `withAnimation` 包住 `pageIndex += 1`。
            //
            // `pageIndex` 是 HomeView 自己的 @State，用全局 withAnimation 写它
            // 等于**每 4 秒把整个 HomeView 的 body 拖进一次显式动画事务**。
            // 这一下要是正好落在用户滚动、大标题正在收起的瞬间，标题的布局
            // 会被卷进这个事务里停在半路 —— 就是那个偶发的标题卡住。
            // 绑在这里，动画只作用于轮播子树。
            .animation(.easeInOut(duration: 0.45), value: pageIndex)
            // 八张卡一个高度。跟着当前页的内容变高变矮是很难受的：
            // 页面下半截会跟着上下跳，眼睛每翻一页都要重新找位置。
            .frame(height: DrawCardMetrics.unifiedHeight(screenWidth: HomeLayout.screenWidth))
            .accessibilityHint("左右滑动查看其他彩种的最新开奖")
            // 手一碰就停自动轮播。轮播抢走用户正在看的那张卡是很讨厌的事。
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                autoScrollResumeAt = Date().addingTimeInterval(12)
            })
            .task(id: carouselGames.count) { await runAutoScroll() }

            // 免责声明摆在卡片和圆点之间。
            //
            // 这几个字必须有，而且必须在开奖号码旁边：数据是从第三方接口抓来的，
            // 抓错、延迟、口径不一致都可能发生，而彩票是真金白银的事。
            // 放在设置页里没人会看到 —— 它只在人正盯着开奖号的时候才有意义。
            Text(Disclaimer.draw)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

            pageDots
        }
        .sheet(isPresented: $isDrawSheetPresented) {
            DrawHistoryView()
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
            // 一直往后推就行 —— 推到尾部那张哨兵页之后，
            // `wrapIfNeeded` 会无动画地接回第一张，转成一个环。
            // 动画由 TabView 上的 `.animation(_:value:)` 负责，这里只改值。
            pageIndex += 1
        }
    }

    // MARK: - 轮播的环

    /// 含哨兵的页码表：`[最后一张的克隆] + 真页 + [第一张的克隆]`。
    private var carouselPages: [Int] {
        guard carouselGames.count > 1 else { return carouselGames.isEmpty ? [] : [1] }
        return Array(0...(carouselGames.count + 1))
    }

    /// 页码 → `carouselGames` 里的真实下标。
    private func realIndex(_ page: Int) -> Int {
        let count = carouselGames.count
        guard count > 0 else { return 0 }
        guard count > 1 else { return 0 }
        return ((page - 1) % count + count) % count
    }

    /// 落在哨兵页上时，等翻页动画走完，**无动画**地跳到对应的真页。
    private func wrapIfNeeded(_ page: Int) {
        let count = carouselGames.count
        guard count > 1, page == 0 || page == count + 1 else { return }
        let target = page == 0 ? count : 1
        Task { @MainActor in
            // 0.45s 是上面翻页动画的时长，等它走完再跳，否则用户会看到闪一下
            try? await Task.sleep(for: .milliseconds(480))
            guard pageIndex == page else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { pageIndex = target }
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

            // 收支是这张卡的主角，单独占一行给足字号；
            // 票面金额和奖金退到下面一行当支撑数据。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MoneyText.format(monthStats.net))
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .tracking(-0.5)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Palette.profitColor(monthStats.net))
                if monthStats.ticketCount > 0 {
                    Text(monthStats.net >= 0 ? "结余" : "支出")
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
                miniStat("票面金额", MoneyText.format(monthStats.cost), "arrow.down.circle.fill", .secondary)
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

/// 首页的固定尺寸。
///
/// 开奖卡片的号码块高度必须在 `GeometryReader` **外面**算出来
/// （高度依赖自身宽度会成布局环），所以内宽在这里统一算一次：
/// 屏幕宽 − 页面左右 16 − 轮播页左右 5 − 卡片左右 14。
enum HomeLayout {
    static let pagePadding: CGFloat = 16
    static let carouselPagePadding: CGFloat = 5

    static var screenWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.width }
            .first ?? 393
    }

    static var drawCardInnerWidth: CGFloat {
        screenWidth - pagePadding * 2 - carouselPagePadding * 2 - DrawCardMetrics.horizontalPadding * 2
    }
}

// MARK: - 收支热力图

/// 逐日收支方格图。
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

    /// 有记录的那些天，以及要画的周列。
    ///
    /// **必须一次算好。** 这两个原来都是计算属性：`byDay` 在每个格子的
    /// `cellView` 里被访问一次（一年 371 格 × 每次重建整个字典），
    /// `weeks` 在 `monthLabel` 里每列被访问一次（53 列 × 每次重跑一遍
    /// 日历运算）。加起来是十几万次字典插入和上万次 Calendar 计算，
    /// **每渲染一帧一遍** —— 而这正是这一版要去卡顿的那块屏。
    private struct Grid {
        let byDay: [String: ProfitDay]
        let weeks: [[Date?]]
        /// 每一列要不要写月份，写哪个月。和列一一对应。
        let monthLabels: [String]
    }

    /// 点开某一列时算出来的那一周小结。
    struct WeekSummary: Equatable {
        let title: String
        let cost: Double
        let prize: Double
        let days: Int
        let wonDays: Int

        var net: Double { prize - cost }
        /// 中奖率按「有记录的天里中过奖的比例」算 —— 按注算需要把每注都
        /// 摊开，而这张图本来就是按天的。
        var hitRate: Double { days > 0 ? Double(wonDays) / Double(days) : 0 }
    }

    @State private var selectedWeek: Int?

    private var grid: Grid { Self.buildGrid(days: days, range: range) }

    private static func buildGrid(days: [ProfitDay], range: ProfitRange) -> Grid {
        var byDay: [String: ProfitDay] = [:]
        byDay.reserveCapacity(days.count)
        for day in days where day.count > 0 { byDay[day.date] = day }

        let calendar = Calendar.chinaCalendar
        let today = Date()
        guard let start = calendar.date(byAdding: .day, value: -(range.gridSpan - 1), to: today) else {
            return Grid(byDay: byDay, weeks: [], monthLabels: [])
        }
        // 回退到那一周的周一，列才不会错位
        let weekdayIndex = (calendar.component(.weekday, from: start) + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -weekdayIndex, to: start) else {
            return Grid(byDay: byDay, weeks: [], monthLabels: [])
        }

        var weeks: [[Date?]] = []
        var cursor = gridStart
        while cursor <= today {
            var column: [Date?] = []
            for _ in 0..<7 {
                column.append(cursor <= today ? cursor : nil)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            weeks.append(column)
        }

        // 月份刻度：只在换月的那一列写字
        var labels: [String] = []
        var previousMonth = 0
        for (index, column) in weeks.enumerated() {
            guard let first = column.compactMap({ $0 }).first else { labels.append(""); continue }
            let month = calendar.component(.month, from: first)
            defer { previousMonth = month }
            if index == 0 {
                // 首列这个月剩不下几天就别标，标签会被挤在最左边
                labels.append(column.compactMap { $0 }.count >= 4 ? "\(month)月" : "")
            } else {
                labels.append(month == previousMonth ? "" : "\(month)月")
            }
        }
        return Grid(byDay: byDay, weeks: weeks, monthLabels: labels)
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

    var body: some View {
        // 一次算好，下面所有格子和月份刻度都读这一份
        let grid = self.grid
        return VStack(alignment: .leading, spacing: 7) {
            // 图例和「最好的一天」放在图**上面**：先看懂颜色的含义，再看图。
            // 放在下面等于让人看完一遍图再回头找说明。
            topBar
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(Array(grid.weeks.enumerated()), id: \.offset) { index, column in
                            VStack(spacing: gap) {
                                ForEach(Array(column.enumerated()), id: \.offset) { _, date in
                                    cellView(for: date, byDay: grid.byDay)
                                }
                            }
                            // 一列就是一周。整列可点，弹一个很小的浮层说这一周
                            // 花了多少、中了多少、中奖率多少 —— 方格图本身只有
                            // 颜色，具体数字总得有地方看。
                            .contentShape(Rectangle())
                            .overlay {
                                if selectedWeek == index {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5)
                                        .padding(-2)
                                }
                            }
                            .onTapGesture {
                                selectedWeek = selectedWeek == index ? nil : index
                            }
                            .popover(isPresented: .init(
                                get: { selectedWeek == index },
                                set: { if !$0 { selectedWeek = nil } }
                            ), attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                                weekPopover(summary(for: column, byDay: grid.byDay))
                                    // 很小的一块，不铺满、不抢戏
                                    .presentationCompactAdaptation(.popover)
                            }
                        }
                    }
                    // 月份刻度跟着方格一起横向滚，所以必须画在 ScrollView **里面**，
                    // 而且每个标签要和它那一列对齐 —— 用等宽的列去铺。
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(Array(grid.monthLabels.enumerated()), id: \.offset) { _, label in
                            Text(label)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(width: cell, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            // 从右往左看更符合「最近的在手边」，默认停在最新的一周
            .defaultScrollAnchor(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("逐日收支方格图，共 \(grid.byDay.count) 天有记录")
    }

    /// 一周小结。
    private func summary(for column: [Date?], byDay: [String: ProfitDay]) -> WeekSummary {
        let dates = column.compactMap { $0 }
        var cost = 0.0, prize = 0.0, days = 0, wonDays = 0
        for date in dates {
            guard let day = byDay[DateText.day(date)] else { continue }
            cost += day.cost
            prize += day.prize
            days += 1
            if day.prize > 0 { wonDays += 1 }
        }
        let title: String
        if let first = dates.first, let last = dates.last {
            title = "\(DateText.monthDay(DateText.day(first))) – \(DateText.monthDay(DateText.day(last)))"
        } else {
            title = "这一周"
        }
        return WeekSummary(title: title, cost: cost, prize: prize, days: days, wonDays: wonDays)
    }

    private func weekPopover(_ summary: WeekSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(summary.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if summary.days == 0 {
                Text("这一周没有记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                row("票面金额", MoneyText.format(summary.cost), .primary)
                row("奖金", MoneyText.format(summary.prize), .primary)
                row("收支", MoneyText.format(summary.net), Palette.profitColor(summary.net))
                row("中奖率", "\(summary.wonDays)/\(summary.days) 天 · \(Int((summary.hitRate * 100).rounded()))%", .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 156, alignment: .leading)
    }

    private func row(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private func cellView(for date: Date?, byDay: [String: ProfitDay]) -> some View {
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

    /// 图例 + 最好的一天。
    ///
    /// 图例的字收成「支 / 收」两个字。原来写「全亏 / 大赚」是想说明色阶的
    /// 两端，但色块本身已经从浅到深排开了，浓度的含义一眼就看得出来，
    /// 那两个字只是把一行挤窄。
    private var topBar: some View {
        HStack(spacing: 6) {
            Text("支")
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
            Text("收")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let best = days.filter({ $0.count > 0 }).max(by: { $0.net < $1.net }), best.net > 0 {
                Text("最好的一天 \(MoneyText.format(best.net))")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.profit)
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

/// 开奖卡片的尺寸计算。
///
/// **所有卡片一个高度。** 轮播里每翻一页就变一次高度是很难受的：
/// 页面下半截跟着上下跳，眼睛得重新找位置。所以高度只算一次 ——
/// 按最占地方的那个彩种（快乐8：两行球）算出来，八张卡片共用。
///
/// 号码球的直径也是算出来的：先定这一行放几颗，再用可用宽度反推，
/// 这样任何彩种都不会出现「最后一颗球被挤到第二行」。
enum DrawCardMetrics {
    static let maxBall: CGFloat = 30
    static let minBall: CGFloat = 18
    /// 球之间、号码区之间的间隙，和 `BallFlow` 里的系数保持一致。
    static let ballGap: CGFloat = 0.19
    static let sectionGap: CGFloat = 0.24
    static let lineGap: CGFloat = 0.22
    /// 卡片自己的左右内边距。
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 16
    /// 快乐8 一期开 20 个号，一行放 10 颗、正好两行。
    static let k8PerRow = 10

    static let headerHeight: CGFloat = 22
    static let prizeRowHeight: CGFloat = 17
    static let blockSpacing: CGFloat = 8

    /// 一张票要画几颗球、分成几个号码区。
    static func layout(for draw: Draw) -> (balls: Int, sections: Int) {
        var balls = 0
        var sections = 0
        for section in draw.gameKey.drawSections {
            let count = draw.drawValues[section.key].count
            guard count > 0 else { continue }
            balls += count
            sections += 1
        }
        return (balls, sections)
    }

    static func perRow(for draw: Draw) -> Int {
        draw.gameKey == .k8 ? k8PerRow : Swift.max(layout(for: draw).balls, 1)
    }

    static func rows(for draw: Draw) -> Int {
        let balls = Swift.max(layout(for: draw).balls, 1)
        return Int(ceil(Double(balls) / Double(perRow(for: draw))))
    }

    /// 一行放下 `perRow` 颗球的最大球径。
    ///
    /// 分母是「以球径为单位」的总宽：n 颗球 + n−1 个球间隙 + 号码区间隙。
    /// 末尾留 2pt 余量 —— 布局里到处是浮点乘法，算得刚刚好就会因为零点几个
    /// 像素的误差换行，而换行的代价是整张卡片的排版垮掉。
    static func ballSize(perRow n: Int, sections: Int, spansAllSections: Bool, width: CGFloat) -> CGFloat {
        guard n > 0, width > 0 else { return maxBall }
        let gaps = spansAllSections && sections > 1 ? CGFloat(sections - 1) * sectionGap : 0
        let units = CGFloat(n) + CGFloat(n - 1) * ballGap + gaps
        return Swift.max(minBall, Swift.min(maxBall, ((width - 2) / units).rounded(.down)))
    }

    static func ballSize(for draw: Draw, width: CGFloat) -> CGFloat {
        let (balls, sections) = layout(for: draw)
        guard balls > 0 else { return maxBall }
        let n = Swift.min(perRow(for: draw), balls)
        return ballSize(perRow: n, sections: sections, spansAllSections: n >= balls, width: width)
    }

    static func numbersHeight(for draw: Draw, width: CGFloat) -> CGFloat {
        let size = ballSize(for: draw, width: width)
        let rowCount = CGFloat(rows(for: draw))
        return rowCount * size + (rowCount - 1) * size * lineGap
    }

    /// 八张卡片共用的高度。
    ///
    /// 取两种极端里更高的那个：
    /// - 快乐8：两行球 + 两行奖项（金额最高的两档）
    /// - 其余彩种：一行球 + 两行奖项（一、二等奖）
    ///
    /// 快乐8 从一行奖项加到两行之后，这里跟着加，八张卡片的高度才还是一个值 ——
    /// 高度只在这一处算，所以联动是自动的，不会出现只有快乐8 变高的情况。
    static func unifiedHeight(screenWidth: CGFloat) -> CGFloat {
        let inner = innerWidth(screenWidth: screenWidth)
        let chrome = headerHeight + verticalPadding * 2 + blockSpacing * 2

        let k8Ball = ballSize(perRow: k8PerRow, sections: 1, spansAllSections: false, width: inner)
        let k8Height = chrome + (2 * k8Ball + k8Ball * lineGap) + prizeRowHeight * 2

        // 其余彩种最多 8 颗球一行（七乐彩 7+1）
        let wideBall = ballSize(perRow: 8, sections: 2, spansAllSections: true, width: inner)
        let otherHeight = chrome + wideBall + prizeRowHeight * 2

        return Swift.max(k8Height, otherHeight).rounded(.up)
    }

    static func innerWidth(screenWidth: CGFloat) -> CGFloat {
        screenWidth - HomeLayout.pagePadding * 2
            - HomeLayout.carouselPagePadding * 2
            - horizontalPadding * 2
    }
}

/// 首页轮播里的一张开奖卡。
///
/// 高度对所有彩种是同一个值（见 `DrawCardMetrics.unifiedHeight`）。
/// 卡片里三段各归各位：**标题永远在最上面**（八张卡翻过去标题不会跳），
/// 号码在剩余空间里居中，奖项贴底。
struct DrawCard: View {
    let game: GameKey
    let draw: Draw?
    /// 这个彩种今天开奖。原来「今日开奖」是页面顶部单独一行标签，
    /// 和它描述的卡片隔得很远；写进卡片里既更省地方也更好懂。
    var opensToday: Bool = false

    /// 卡片上要列的奖级。
    ///
    /// 快乐8 的奖级表是「选十中十、选十中九…选九中九…」几十行，一等奖这个
    /// 概念在它身上不成立。排序的第一依据是**单注奖金**，不是表里的行序 ——
    /// 官方那张表按「选几」从大到小排，而「选十中十 1000 万」和
    /// 「选九中九 300 万」谁更值钱得按钱算。取金额最高的两档，
    /// 奖级名本身就带着玩法（「选十中10」），一眼看得出是哪个玩法中的。
    private var prizes: [PrizeEntry] {
        PrizeRanking.topTwo(of: draw?.prizeList ?? [], game: game)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DrawCardMetrics.blockSpacing) {
            header
            Spacer(minLength: 0)
            numbersRow
            Spacer(minLength: 0)
            if !prizes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(prizes.enumerated()), id: \.offset) { rank, entry in
                        prizeStrip(entry, rank: rank)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DrawCardMetrics.verticalPadding)
        .padding(.horizontal, DrawCardMetrics.horizontalPadding)
        .frame(height: DrawCardMetrics.unifiedHeight(screenWidth: HomeLayout.screenWidth))
        .background(
            RoundedRectangle(cornerRadius: DrawCardMetrics.cornerRadius, style: .continuous)
                .fill(Palette.card)
        )
        // 圆角要真的把内容裁掉，否则号码排到边上时会压在圆角外面，
        // 看起来就像卡片没有圆角。
        .clipShape(RoundedRectangle(cornerRadius: DrawCardMetrics.cornerRadius, style: .continuous))
    }

    /// 号码。球径按可用宽度反推，保证每行正好放下该放的颗数。
    @ViewBuilder
    private var numbersRow: some View {
        if let draw {
            let inner = DrawCardMetrics.innerWidth(screenWidth: HomeLayout.screenWidth)
            DrawNumbersView(draw: draw, size: DrawCardMetrics.ballSize(for: draw, width: inner))
                .frame(width: inner, alignment: .leading)
        } else {
            Text("暂无开奖数据")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: DrawCardMetrics.maxBall)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(game.tint)
                .frame(width: 8, height: 8)
            Text(game.label)
                .font(.headline)
                // 彩种名用彩种色。八张卡翻过去，认的就是这个颜色 ——
                // 和票夹卡片的做法保持一致。
                .foregroundStyle(game.accent.accentColor)

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

    /// 一个奖级一行。奖金后面不再跟「/注」—— 奖级本来就是按注计的，
    /// 那两个字每行都重复一遍，纯占地方。
    private func prizeStrip(_ entry: PrizeEntry, rank: Int) -> some View {
        HStack(spacing: 6) {
            // 快乐8 没有「一等奖」这个名字，用排名区分：金额最高的那行挂奖杯。
            Image(systemName: isTopPrize(entry, rank: rank) ? "trophy.fill" : "rosette")
                .font(.system(size: 10))
                .foregroundStyle(game.tint)
            Text("\(prizeLabel(entry)) \(entry.winningCount) 注")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if entry.amount > 0 {
                Text(MoneyText.compactYuan(entry.amount))
                    .font(.system(.footnote, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(game.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func isTopPrize(_ entry: PrizeEntry, rank: Int) -> Bool {
        game == .k8 ? rank == 0 : entry.prizeName.contains("一等奖")
    }

    /// 快乐8 的奖级名照抄票面（「选十中9」），其余彩种收成「一等奖 / 二等奖」。
    private func prizeLabel(_ entry: PrizeEntry) -> String {
        if game == .k8 { return entry.prizeName }
        return entry.prizeName.contains("一等奖") ? "一等奖" : "二等奖"
    }
}

/// 卡片上那两行奖级挑谁。
///
/// 单独拎出来是为了能测 —— 这段逻辑错了，首页就会把一个小奖当头奖摆着，
/// 而 View 里的 private 属性测不到。
enum PrizeRanking {

    /// 金额最高的两档。
    ///
    /// 快乐8 按**单注奖金**排，不按官方表的行序：那张表是按「选几」从大到小列的，
    /// 而「选十中10」和「选九中9」谁更值钱只能按钱比。奖级名本身带着玩法
    /// （「选十中10」），排完直接显示就说得清是哪个玩法中的。
    ///
    /// 其余彩种的一、二等奖是固定的两行，名字就是次序，不用比金额。
    static func topTwo(of list: [PrizeEntry], game: GameKey) -> [PrizeEntry] {
        guard game == .k8 else {
            return ["一等奖", "二等奖"].compactMap { name in
                list.first { $0.prizeName.contains(name) && ($0.winningCount > 0 || $0.amount > 0) }
            }
        }
        var open: [(offset: Int, entry: PrizeEntry)] = []
        for (offset, entry) in list.enumerated() where entry.winningCount > 0 && entry.amount > 0 {
            open.append((offset, entry))
        }
        // 金额一样（比如两档都是 4 元）时按官方表的原序，结果才稳定。
        let ranked = open.sorted { lhs, rhs in
            lhs.entry.amount == rhs.entry.amount
                ? lhs.offset < rhs.offset
                : lhs.entry.amount > rhs.entry.amount
        }
        var picked: [PrizeEntry] = []
        for item in ranked.prefix(2) { picked.append(item.entry) }
        return picked
    }
}
