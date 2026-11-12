import SwiftUI
import SwiftData
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
    /// 卡片里画曲线还是方格。两种二选一，记住上次选的。
    @AppStorage("home.chartStyle", store: HomeChartStyle.store) private var chartStyle = HomeChartStyle.line.rawValue
    @State private var series = ProfitSeries()
    /// 号码球罐：看哪一罐、罐里放什么。
    @State private var jarScope = JarScope.all
    @State private var jar = JarBuilder.Jar()
    @State private var jarEntries: [JarEntry] = []
    @State private var jarYears: [Int] = []
    @State private var monthStats = ProfitStats.PeriodStats()
    /// 下面那张概览卡看哪一段：某年某月、某年全年（月份为 nil）、或者全部。
    @State private var overviewYear = Calendar.chinaCalendar.component(.year, from: AppClock.now)
    @State private var overviewMonth: Int? = Calendar.chinaCalendar.component(.month, from: AppClock.now)
    @State private var isOverviewAll = false
    @State private var overviewYears: [Int] = []
    @State private var isOverviewPickerPresented = false
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
    /// 今天开奖的彩种各自几点开，卡片上的倒计时用。
    @State private var todayDrawTimes: [GameKey: Date] = [:]
    @State private var pendingGames: [GameKey] = []
    @State private var carouselGames: [GameKey] = GameKey.ordered
    /// 量出来的可用宽度。量到之前用起手值，见 `HomeLayout.fallbackScreenWidth`。
    @State private var measuredWidth: CGFloat?

    private var screenWidth: CGFloat { measuredWidth ?? HomeLayout.fallbackScreenWidth }

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
            // 量宽度放在 `background` 里：背景不参与布局，量它不会把
            // `GeometryReader` 的贪心尺寸带进内容，也动不到导航栏那套
            // 大标题/滚动渐变的行为。量到之后经环境值往下传。
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { measuredWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in measuredWidth = width }
                }
            )
            // **导航栏这里什么都不要加。**
            //
            // 试过两版，两版都是退步：
            // 1. `.toolbarBackgroundVisibility(.visible)` 把导航栏钉死在
            //    「已滚动」外观上，大标题只存在于未滚动的 scrollEdge 外观里，
            //    结果大标题整个消失，从头到尾只剩中间那行小字。
            // 2. 只给 `.toolbarBackground(Palette.canvas)` 也不行 —— 那是一块
            //    平涂的不透明色，把 iOS 26 自带的渐变模糊顶掉了，
            //    滚动时是一条硬边界压在内容上，比原来更难看。
            //
            // 系统的 scroll edge effect 本来就会在滚动时给标题后面铺一层
            // 渐变模糊，那才是这一版该有的观感。偶发的标题错位是轮播每 4 秒
            // 用全局 withAnimation 写 @State 引起的，已经在下面 TabView 那里
            // 把动画作用域收窄解决了，跟导航栏背景没关系。
            // 只要导航栏里那行小标题，不要页面上的大标题：大标题把内容往下压了一大截。
            // 小标题得留着 —— 往下滑的时候顶上要有一条带标题的栏，和设置页一样。
            .navigationTitle("首页")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await drawStore.refresh() }
            .task(id: RecordsToken(records)) { recompute() }
            .task(id: drawStore.scheduleToken) { refreshSchedule() }
            .task(id: ChinaClock.year()) {
                // 最新开奖先显示；日历按年缓存，拿到后再显示准确的今日标记。
                await drawStore.loadCalendar(year: ChinaClock.year())
            }
            // 换范围时曲线和数字一起过渡，不是啪地一下换掉
            .onChange(of: range) { _, _ in
                // 球罐跟着上面的范围走：累计看全部那一罐，本月 / 本年看今年那一罐
                jarScope = defaultJarScope
                withAnimation(.snappy(duration: 0.35)) { recomputeSeries() }
            }
            .onChange(of: jarScope) { _, _ in recomputeJar() }
            .onChange(of: chartStyle) { _, _ in recomputeJar() }
            .onChange(of: overviewYear) { _, _ in recompute() }
            .onChange(of: overviewMonth) { _, _ in recompute() }
            .onChange(of: isOverviewAll) { _, _ in recompute() }
            .sheet(isPresented: $isOverviewPickerPresented) {
                PeriodPicker(year: $overviewYear, month: $overviewMonth, isAll: $isOverviewAll, years: overviewYears)
            }
            .environment(\.screenWidth, screenWidth)
        }
    }

    // MARK: - 派生数据

    @State private var entries: [SettledEntry] = []

    private func recompute() {
        entries = ProfitStats.snapshot(records)
        recomputeSeries()
        jarEntries = []
        recomputeJar()
        let all = ProfitStats.snapshotAll(records)
        overviewYears = ProfitStats.availableYears(entries: all)
        monthStats = ProfitStats.period(entries: all, year: isOverviewAll ? nil : overviewYear, month: overviewMonth)
    }

    private var defaultJarScope: JarScope {
        range == .all ? .all : .year(Calendar.chinaCalendar.component(.year, from: AppClock.now))
    }

    /// 球罐要把每张票的号码和逐球命中都解出来，只在选了球罐的时候算。
    private func recomputeJar() {
        guard chartStyle == HomeChartStyle.jar.rawValue else { return }
        if jarEntries.isEmpty {
            jarEntries = records.compactMap { record in
                guard record.status == .won || record.status == .lost else { return nil }
                return JarEntry(day: record.profitDay, game: record.game, numbers: record.ticket.numbers,
                                matched: record.matched, prize: record.prizeAmount)
            }
            jarYears = Set(jarEntries.compactMap { Int($0.day.prefix(4)) }).sorted(by: >)
        }
        jar = JarBuilder.build(jarEntries, scope: jarScope, now: AppClock.now)
    }

    private func recomputeSeries() {
        series = ProfitStats.series(entries: entries, range: range, now: AppClock.now)
    }

    private func refreshSchedule() {
        todayGames = Set(drawStore.todayOpenGames())
        var times: [GameKey: Date] = [:]
        for game in todayGames { times[game] = drawStore.todayDrawTime(for: game) }
        todayDrawTimes = times
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

    /// 从上到下一条线：标签、范围和图表模式 → 大数字 → 两个小指标 → 一行读数 → 图。
    ///
    /// 返奖率和公益金紧跟在大数字下面：它们是对这个数字的**解读**
    /// （花出去的钱回来多少、捐出去多少）。投入、奖金这些流水数不再单独占方块，
    /// 并进图上面那一行读数里，见 `ProfitFlowChart`。
    private var profitCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("累计收支")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    // 看哪一段：本月、本年、从头累计。三档就够，原来的下拉菜单和「累计 / 每月」切换都并到这里。
                    Picker("范围", selection: $range) {
                        Text("本月").tag(ProfitRange.month)
                        Text("本年").tag(ProfitRange.year)
                        Text("累计").tag(ProfitRange.all)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("home.range")
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(MoneyText.grouped(series.netTotal))
                        // 大号字要收紧字距 —— 字号越大，字母间那点默认间隙看着越松。
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .tracking(-1)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("元")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Palette.profitColor(series.netTotal))
                .accessibilityElement(children: .combine)

                HStack(spacing: 8) {
                    // 返奖率：花出去的钱回来了多少。比「中奖率」诚实 —— 中 5 元也算中奖，
                    // 中奖率很好看的时候钱照样是净出去的。
                    inlineStat("返奖率", returnRateText, tint: series.prizeTotal > 0 ? Palette.profit : .secondary)
                    Rectangle()
                        .fill(Palette.separator)
                        .frame(width: 1, height: 11)
                    // 公益金逐条按彩种计提，比例见 `GameKey.welfareRate` ——
                    // 八个彩种不是同一个比例，不能拿总额乘一个数。
                    inlineStat("公益金", "\(MoneyText.grouped(series.welfareTotal)) 元", tint: Palette.warning)
                    Spacer(minLength: 0)
                    // 曲线看总数怎么涨，方格看每一天，球罐看买过的号码。三选一。
                    Picker("图表样式", selection: $chartStyle) {
                        Image(systemName: "chart.xyaxis.line")
                            .accessibilityLabel("曲线")
                            .tag(HomeChartStyle.line.rawValue)
                        Image(systemName: "square.grid.3x3.fill")
                            .accessibilityLabel("方格")
                            .tag(HomeChartStyle.grid.rawValue)
                        Image(systemName: "circle.hexagongrid.fill")
                            .accessibilityLabel("球罐")
                            .tag(HomeChartStyle.jar.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("home.chart.style")
                }
            }

            // 原来这里是逐日方格图加四个数字方块。方块里的数现在都在图上面那一行，
            // 而且按住图表拖动时会跟着变成那一天的数。
            Group {
                if chartStyle == HomeChartStyle.jar.rawValue {
                    BallJarView(jar: jar, scope: $jarScope, years: jarYears)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if chartStyle == HomeChartStyle.grid.rawValue, !series.days.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        // 方格图自己读不出金额，上面放和曲线图同样的两个数
                        HStack(alignment: .top, spacing: 8) {
                            gridTotal("投入", series.costTotal, Color.accentColor)
                            gridTotal("奖金", series.prizeTotal, Palette.profit)
                        }
                        ProfitHeatmap(days: series.days, range: range, width: screenWidth - 64)
                        HStack(spacing: 12) {
                            heatLegend(Palette.profit, "当天有中奖")
                            heatLegend(Palette.loss, "当天没中")
                            Text("颜色越深金额越大")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    ProfitFlowChart(series: series, mode: .cumulative)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.smooth(duration: 0.3), value: chartStyle)
        }
        // 换范围、换图表样式时各给一下轻的触感
        .sensoryFeedback(.selection, trigger: range)
        .sensoryFeedback(.selection, trigger: chartStyle)
        .contentCard()
    }

    private func gridTotal(_ title: String, _ value: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(MoneyText.grouped(value))
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 概览卡上那三个快捷范围选中了哪个；都不是（比如选了去年某个月）返回 -1。
    private var overviewQuick: Int {
        let now = AppClock.now
        let year = Calendar.chinaCalendar.component(.year, from: now)
        let month = Calendar.chinaCalendar.component(.month, from: now)
        if isOverviewAll { return 2 }
        guard overviewYear == year else { return -1 }
        if overviewMonth == nil { return 1 }
        return overviewMonth == month ? 0 : -1
    }

    private func setOverviewQuick(_ choice: Int) {
        let now = AppClock.now
        isOverviewAll = choice == 2
        guard choice != 2 else { return }
        overviewYear = Calendar.chinaCalendar.component(.year, from: now)
        overviewMonth = choice == 0 ? Calendar.chinaCalendar.component(.month, from: now) : nil
    }

    /// 在概览卡上左右滑：看着某个月时换到上个月 / 下个月。不往未来翻。
    private func shiftOverviewMonth(_ delta: Int) {
        guard !isOverviewAll, let month = overviewMonth else { return }
        var year = overviewYear, next = month + delta
        if next < 1 { next = 12; year -= 1 }
        if next > 12 { next = 1; year += 1 }
        let now = AppClock.now
        let thisYear = Calendar.chinaCalendar.component(.year, from: now)
        let thisMonth = Calendar.chinaCalendar.component(.month, from: now)
        guard year < thisYear || (year == thisYear && next <= thisMonth) else { return }
        withAnimation(.snappy(duration: 0.3)) {
            overviewYear = year
            overviewMonth = next
        }
    }

    private func heatLegend(_ tint: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(tint)
                .frame(width: 9, height: 9)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 一分钱都还没结算时，返奖率是 0/0 —— 那不是「返奖率 0%」，
    /// 是「还没有能算的东西」。写成 0% 会让人以为买了都没中。
    private var returnRateText: String {
        series.costTotal > 0 ? String(format: "%.0f%%", series.prizeTotal / series.costTotal * 100) : "—"
    }

    private func inlineStat(_ title: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .font(.footnote)
        .lineLimit(1)
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
                             opensToday: todayGames.contains(game),
                             drawsAt: todayDrawTimes[game])
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
            .frame(height: DrawCardMetrics.unifiedHeight(screenWidth: screenWidth))
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
                .scaledFont(10)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

            pageDots
        }
        // 进往期页时**带上正在看的那个彩种**。
        //
        // 原来固定从双色球开始：用户明明正盯着快乐8 那张卡点的「更多」，
        // 进去却是双色球，还得自己再滑回去。轮播每 4 秒换一张，
        // 「我刚才看的是哪个」是用户唯一带进这一页的上下文，不该丢掉。
        .sheet(isPresented: $isDrawSheetPresented) {
            DrawHistoryView(initialGame: currentCarouselGame)
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

    /// 轮播上正在显示的那个彩种。
    ///
    /// `carouselIndex` 是跟着 `carouselGames` 走的，而 `carouselGames` 会随
    /// 「今天开哪个彩种」重排，所以这里要防一手越界 —— 重排和读取之间
    /// 隔着一次 body 求值。
    private var currentCarouselGame: GameKey {
        guard carouselGames.indices.contains(carouselIndex) else {
            return carouselGames.first ?? .ssq
        }
        return carouselGames[carouselIndex]
    }

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

    // MARK: - 概览

    private var overviewTitle: String {
        if isOverviewAll { return "全部概览" }
        if let month = overviewMonth { return "\(overviewYear) 年 \(month) 月概览" }
        return "\(overviewYear) 年概览"
    }

    private var monthlyCard: some View {
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(overviewTitle)
                        .font(.headline)
                    Text("本机记录 · \(monthStats.ticketCount) 注")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                // 选哪个月、哪一年、还是全部
                Button {
                    isOverviewPickerPresented = true
                } label: {
                    HStack(spacing: 3) {
                        Text("选择时间")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline)
                }
                .accessibilityIdentifier("home.overview.period")
            }
            // 和上面那张卡一样的三档；要看别的月份点「选择时间」，或者在这张卡上左右滑
            Picker("概览范围", selection: Binding(get: { overviewQuick }, set: { setOverviewQuick($0) })) {
                Text("本月").tag(0)
                Text("本年").tag(1)
                Text("累计").tag(2)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("home.overview.quick")

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
                miniStat("票面金额", MoneyText.format(monthStats.cost), "yensign.circle.fill", .secondary)
                miniStat("奖金", MoneyText.format(monthStats.prize), "trophy.fill", Palette.profit)
            }

            if monthStats.byGame.isEmpty {
                Text("这一段还没有记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                Divider()
                // 原来是一张横向柱状图，只能看出长短。换成一条占比色带
                // 加一份明细，金额和比例都直接写出来。
                // 彩种一共就八个，全部列出来，不并成「其他」
                SpendBreakdown(items: monthStats.byGame, total: monthStats.cost, limit: monthStats.byGame.count)
            }
        }
        .contentCard()
        .sensoryFeedback(.selection, trigger: overviewMonth)
        // 横着滑才算；竖着滑是页面在滚
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    guard abs(dx) > 60, abs(dx) > abs(dy) * 2 else { return }
                    shiftOverviewMonth(dx < 0 ? 1 : -1)
                }
        )
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

    /// 首屏第一帧用的宽度，**只是个起手值**。
    ///
    /// 真正的宽度由 `HomeView` 量出来，经 `\.screenWidth` 传给卡片
    /// （见下面的环境值）。这里留一个起手值是为了第一帧就画对高度 ——
    /// 量宽度要等一次布局，那一帧用默认值画会让卡片肉眼可见地弹一下。
    ///
    /// `keyWindow` 在分屏/多窗口下未必是自己那一个，所以它只配当起手值，
    /// 不配当数据源。
    static var fallbackScreenWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.width }
            .first ?? 393
    }
}

/// 首页量出来的可用宽度。
///
/// 开奖卡片的高度依赖自身宽度，而高度必须在 `GeometryReader` **外面**算好
/// （高度依赖自身宽度会成布局环）。所以宽度在首页量一次往下传，
/// 卡片自己不再去问系统要窗口宽度。
private struct ScreenWidthKey: EnvironmentKey {
    static var defaultValue: CGFloat { HomeLayout.fallbackScreenWidth }
}

extension EnvironmentValues {
    var screenWidth: CGFloat {
        get { self[ScreenWidthKey.self] }
        set { self[ScreenWidthKey.self] = newValue }
    }
}

/// 首页那张卡片里画哪一种图。
enum HomeChartStyle: String {
    case line, grid, jar

    /// 选的样式记在哪。示例模式（截图、界面测试）每次启动都用一份清空了的，
    /// 不然一条测试切到球罐，后面的测试和截图打开首页看到的都是球罐。
    static let store: UserDefaults = {
        guard ProcessInfo.processInfo.arguments.contains("--demo-data"), let demo = UserDefaults(suiteName: "demo.home") else { return .standard }
        demo.removePersistentDomain(forName: "demo.home")
        return demo
    }()
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
    ///
    /// 格子**按宽度铺满**：周数少时格子大（一眼看得清每一天），周数多到放不下时
    /// 格子收到 `minCell`、改成横向滚动。原来固定 13pt，记录只有几个月时
    /// 右边挤着一小块、左边一大片空格子。
    private let cell: CGFloat
    private static let gapSize: CGFloat = 4
    private var gap: CGFloat { Self.gapSize }
    private static let minCell: CGFloat = 11
    private static let maxCell: CGFloat = 26

    /// 一次算好的网格，见 `Grid` 的注释。
    private let grid: Grid

    /// - Parameter width: 方格图能用的宽度。
    init(days: [ProfitDay], range: ProfitRange, width: CGFloat) {
        self.days = days
        self.range = range
        let grid = Self.buildGrid(days: days, range: range)
        self.grid = grid
        let columns = CGFloat(Swift.max(grid.weeks.count, 1))
        let fitted = (width - Self.gapSize * (columns - 1)) / columns
        self.cell = Swift.min(Swift.max(fitted.rounded(.down), Self.minCell), Self.maxCell)
    }

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

    /// 「全部」画多少天：从第一条记录往前再留两周，最少 16 周、最多一年。
    /// 固定画一整年的话，只有几个月记录的人看到的是一大片空格子。
    private static func span(range: ProfitRange, days: [ProfitDay], today: Date) -> Int {
        guard range == .all else { return range.gridSpan }
        guard let first = days.filter({ $0.count > 0 }).map(\.day).min() else { return 16 * 7 }
        let recorded = (Calendar.chinaCalendar.dateComponents([.day], from: first, to: today).day ?? 0) + 14
        return Swift.min(Swift.max(recorded, 16 * 7), 365)
    }

    private static func buildGrid(days: [ProfitDay], range: ProfitRange) -> Grid {
        var byDay: [String: ProfitDay] = [:]
        byDay.reserveCapacity(days.count)
        for day in days where day.count > 0 { byDay[day.date] = day }

        let calendar = Calendar.chinaCalendar
        let today = AppClock.now
        let span = Self.span(range: range, days: days, today: today)
        guard let start = calendar.date(byAdding: .day, value: -(span - 1), to: today) else {
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
        // 图例不再单独占一行：红赚绿亏写在首页那行说明里，「最好的一天」挪到大数字下面。
        return VStack(alignment: .leading, spacing: 7) {
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
                            //
                            // 格子只有 9pt 宽，整列的命中区也就 9pt，远低于 HIG
                            // 的 28pt 下限。用负 inset 把命中区向两侧撑开，
                            // **视觉一点没变**，只是手指更容易点中。
                            .contentShape(Rectangle().inset(by: -(28 - cell) / 2))
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
                                .scaledFont(10)
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
        let shape = RoundedRectangle(cornerRadius: cell > 18 ? 5 : 3, style: .continuous)
        // 「全部」范围最前面补的那个零点不是真的买过，不涂色
        if let date, let day = byDay[DateText.day(date)], day.count > 0 {
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

    /// 当天有一注中奖就是红的，都没中就是绿的；深浅分三档，见 `HeatTone`。
    private func color(for day: ProfitDay) -> Color {
        let scales = HeatTone.scales(days)
        let level = HeatTone.level(of: day, wins: scales.wins, losses: scales.losses)
        return (HeatTone.isWin(day) ? Palette.profit : Palette.loss).opacity([0.4, 0.7, 1.0][level])
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
    /// 首页量好的宽度。卡片自己不去问系统要窗口宽度 —— 那在分屏/多窗口下
    /// 拿到的未必是自己这一个窗口。
    @Environment(\.screenWidth) private var screenWidth

    let game: GameKey
    let draw: Draw?
    /// 这个彩种今天开奖。原来「今日开奖」是页面顶部单独一行标签，
    /// 和它描述的卡片隔得很远；写进卡片里既更省地方也更好懂。
    var opensToday: Bool = false
    /// 今天这一期的开奖时刻。有它，「今日开奖」那枚标签里就多一段倒计时。
    var drawsAt: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DrawCardMetrics.blockSpacing) {
            header
            Spacer(minLength: 0)
            numbersRow
            Spacer(minLength: 0)
            // 奖级行和「往期开奖」共用，见 `DrawPrizeLines`
            DrawPrizeLines(game: game, draw: draw)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DrawCardMetrics.verticalPadding)
        .padding(.horizontal, DrawCardMetrics.horizontalPadding)
        .frame(height: DrawCardMetrics.unifiedHeight(screenWidth: screenWidth))
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
            let inner = DrawCardMetrics.innerWidth(screenWidth: screenWidth)
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
                // 倒计时写在原来那枚标签**里面**，不另起一行：卡片高度是八张卡共用的
                // 定值，多一行会把号码和奖项挤出去。
                //
                // 每秒一跳只重画这枚标签（`TimelineView` 的作用域），不会把整张卡、
                // 更不会把首页拖进每秒一次的重算。示例模式不走表：截图里出现
                // 一个每秒都在变的数，参考图就永远对不上。
                if let drawsAt, !DemoData.isEnabled {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        todayBadge(DrawCountdown.badge(until: drawsAt, now: context.date))
                    }
                } else {
                    todayBadge("今日开奖")
                }
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

}

extension DrawCard {
    fileprivate func todayBadge(_ text: String) -> some View {
        Text(text)
            .scaledFont(10, weight: .bold)
            .monospacedDigit()
            .foregroundStyle(Palette.live)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Palette.live.opacity(0.14), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// 「今日开奖」标签上的倒计时文字。
enum DrawCountdown {
    /// 还没到点：`今日开奖 2:14:37`（不足一小时是 `14:37`）；到点之后只剩「今日开奖」。
    static func badge(until drawsAt: Date, now: Date) -> String {
        let left = Int(drawsAt.timeIntervalSince(now).rounded(.up))
        guard left > 0 else { return "今日开奖" }
        let hours = left / 3600, minutes = left / 60 % 60, seconds = left % 60
        let clock = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        return "今日开奖 \(clock)"
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
