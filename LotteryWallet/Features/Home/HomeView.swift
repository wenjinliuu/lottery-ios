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

    @State private var range: ProfitRange = .year
    @State private var historicalEnd: Date?
    @State private var pickerYear = 0
    @State private var pickerMonth: Int?
    @State private var pickerAll = false
    @State private var showsProfitPicker = false

    private var periodEnd: Date { historicalEnd ?? AppClock.now }
    private var periodLabel: String {
        guard let historicalEnd else { return range.label }
        let day = DateText.day(historicalEnd)
        return range == .month ? String(day.prefix(7)) : String(day.prefix(4)) + " 年"
    }

    /// 首页默认以放大版玻璃球罐作为视觉主角；曲线与方格图共用同一时间范围并完整保留。
    @AppStorage("home.chartStyle", store: HomeChartStyle.store) private var chartStyle = HomeChartStyle.jar.rawValue
    @State private var series = ProfitSeries()
    @State private var jar = JarBuilder.Jar()
    @State private var jarEntries: [JarEntry]?
    @State private var periodStats = ProfitStats.PeriodStats()
    @State private var availableYears: [Int] = []

    @State private var carouselIndex = 0
    /// TabView 的真实页码。首尾各多挂一张哨兵页（末卡的副本放在最前、
    /// 首卡的副本放在最后），滑到哨兵页上再无动画地跳回对应的真页，
    /// 这样最后一张往右滑就能接回第一张。
    @State private var pageIndex = 1
    /// 区分代码自动轮播 / 哨兵回绕与用户手动左右滑，避免挂 DragGesture 抢占首页上下滚动。
    @State private var isAutoAdvancing = false
    /// 自动轮播暂停到什么时候。用户一滑就往后推 12 秒。
    @State private var autoScrollResumeAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrawSheetPresented = false

    /// 开奖日程也不能在 body 里算。统一在数据变化时算好存下来。
    @State private var todayGames: Set<GameKey> = []
    /// 今天开奖的彩种各自几点开，卡片上的倒计时用。
    @State private var todayDrawTimes: [GameKey: Date] = [:]
    @State private var pendingGames: [GameKey] = []
    @State private var carouselGames: [GameKey] = GameKey.ordered
    /// 量出来的可用宽度与可见高度。量到之前用起手值，见 `HomeLayout.fallbackScreenWidth`。
    @State private var measuredWidth: CGFloat?
    @State private var measuredHeight: CGFloat?

    private var screenWidth: CGFloat { measuredWidth ?? HomeLayout.fallbackScreenWidth }

    /// 按屏幕可见高度自适应玻璃球罐高度，保证默认一屏内「最新开奖」完整卡片、免责提示与轮播状态圆点
    /// 全部清透露在官方标签栏之上，既不遮挡又保持球罐充盈主角感。
    private var adaptiveJarHeight: CGFloat {
        guard let viewportHeight = measuredHeight, viewportHeight > 0 else {
            return BallJarView.defaultHeight
        }
        return BallJarView.adaptiveHeight(viewportHeight: viewportHeight, screenWidth: screenWidth)
    }

    private var rangePickerWidth: CGFloat {
        min(216, max(202, screenWidth - 182))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // 外层不再整体加 `.padding(.horizontal, 16)`：
                // 最新开奖轮播需要整屏宽轨道才能平滑滑到手机物理边缘，不被 16pt 隐形边界截断。
                VStack(spacing: 14) {
                    heroSection
                        .padding(.horizontal, HomeLayout.pagePadding)

                    latestDrawSection

                    spendCard
                        .padding(.horizontal, HomeLayout.pagePadding)

                    if !pendingGames.isEmpty {
                        pendingNotice
                            .padding(.horizontal, HomeLayout.pagePadding)
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 28)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background { HomeAmbientBackdrop() }
            // 量尺寸放在 `background` 里：背景不参与布局，量它不会把
            // `GeometryReader` 的贪心尺寸带进内容，也动不到导航栏的行为。
            // 注意这里不带 `.ignoresSafeArea()`，`proxy.size.height` 本身已经是扣除顶部导航栏和
            // 底部官方 TabView 安全区之后的可见高度；再减 `safeAreaInsets` 会双重扣减导致球罐被压到最小高度。
            .background(
                GeometryReader { proxy in
                    let usableHeight = proxy.size.height
                    Color.clear
                        .onAppear {
                            measuredWidth = proxy.size.width
                            measuredHeight = usableHeight
                        }
                        .onChange(of: proxy.size.width) { _, width in measuredWidth = width }
                        .onChange(of: usableHeight) { _, height in measuredHeight = height }
                }
            )
            .navigationTitle("首页")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await drawStore.refresh() }
            .task(id: RecordsToken(records)) { recompute() }
            .task(id: drawStore.scheduleToken) { refreshSchedule() }
            .task(id: ChinaClock.year()) {
                // 最新开奖先显示；日历按年缓存，拿到后再显示准确的今日标记。
                await drawStore.loadCalendar(year: ChinaClock.year())
            }
            // 换范围或左右翻期时数字和统计柔和滚动，球罐物理重排移出布局动画事务以免主线程卡顿
            .onChange(of: periodLabel) { _, _ in
                recomputeJar()
                withAnimation(.easeOut(duration: 0.22)) {
                    recomputeSeries()
                    recomputePeriodStats()
                }
            }
            .onChange(of: chartStyle) { _, _ in
                recomputeSeries()
                recomputeJar()
            }
            .sheet(isPresented: $showsProfitPicker, onDismiss: applyProfitPeriod) {
                PeriodPicker(year: $pickerYear, month: $pickerMonth, isAll: $pickerAll,
                             years: availableYears + [Calendar.chinaCalendar.component(.year, from: AppClock.now) - 2],
                             latest: AppClock.now)
            }
            .environment(\.screenWidth, screenWidth)
        }
    }

    // MARK: - 派生数据

    @State private var entries: [SettledEntry] = []
    @State private var allEntries: [SettledEntry] = []

    private func recompute() {
        entries = ProfitStats.snapshot(records)
        allEntries = ProfitStats.snapshotAll(records)
        availableYears = ProfitStats.availableYears(entries: allEntries)
        recomputeSeries()
        jarEntries = nil
        recomputeJar()
        recomputePeriodStats()
    }

    private var earliestPickableYear: Int {
        let nowYear = Calendar.chinaCalendar.component(.year, from: AppClock.now)
        return min(availableYears.min() ?? nowYear, nowYear - 2)
    }

    private func canStepPeriod(by delta: Int) -> Bool {
        guard range == .month || range == .year else { return false }
        let cal = Calendar.chinaCalendar
        let now = AppClock.now
        if range == .month {
            guard let currentStart = cal.dateInterval(of: .month, for: periodEnd)?.start,
                  let nowStart = cal.dateInterval(of: .month, for: now)?.start,
                  let targetStart = cal.date(byAdding: .month, value: delta, to: currentStart) else { return false }
            let targetYear = cal.component(.year, from: targetStart)
            return targetYear >= earliestPickableYear && targetStart <= nowStart
        } else {
            let nowYear = cal.component(.year, from: now)
            let targetYear = cal.component(.year, from: periodEnd) + delta
            return targetYear >= earliestPickableYear && targetYear <= nowYear
        }
    }

    private func stepPeriod(by delta: Int) {
        guard canStepPeriod(by: delta) else { return }
        let cal = Calendar.chinaCalendar
        let now = AppClock.now
        if range == .month {
            guard let currentStart = cal.dateInterval(of: .month, for: periodEnd)?.start,
                  let targetStart = cal.date(byAdding: .month, value: delta, to: currentStart),
                  let interval = cal.dateInterval(of: .month, for: targetStart) else { return }
            historicalEnd = interval.contains(now) ? nil : interval.end.addingTimeInterval(-1)
        } else if range == .year {
            let targetYear = cal.component(.year, from: periodEnd) + delta
            guard let first = cal.date(from: DateComponents(year: targetYear, month: 1, day: 1)),
                  let interval = cal.dateInterval(of: .year, for: first) else { return }
            historicalEnd = interval.contains(now) ? nil : interval.end.addingTimeInterval(-1)
        }
    }

    private func openProfitPicker() {
        let calendar = Calendar.chinaCalendar
        pickerYear = calendar.component(.year, from: periodEnd)
        pickerMonth = range == .month ? calendar.component(.month, from: periodEnd) : nil
        pickerAll = range == .all
        showsProfitPicker = true
    }

    private func applyProfitPeriod() {
        let calendar = Calendar.chinaCalendar
        guard !pickerAll else {
            historicalEnd = nil
            range = .all
            return
        }
        guard let first = calendar.date(from: DateComponents(year: pickerYear, month: pickerMonth ?? 1, day: 1)),
              let interval = calendar.dateInterval(of: pickerMonth == nil ? .year : .month, for: first),
              first <= AppClock.now else { return }
        historicalEnd = interval.contains(AppClock.now) ? nil : interval.end.addingTimeInterval(-1)
        range = pickerMonth == nil ? .year : .month
    }

    private func recomputeJar() {
        guard chartStyle == HomeChartStyle.jar.rawValue else { return }
        if DemoData.isEnabled, let value = ProcessInfo.processInfo.environment["JAR_PREVIEW_HITS"],
           let hits = Int(value), [309, 2000].contains(hits) {
            jar = JarBuilder.demoPreview(hits: hits)
            return
        }
        if jarEntries == nil {
            jarEntries = records.compactMap { record in
                guard record.status.hasResult else { return nil }
                return JarEntry(day: record.profitDay, game: record.game, numbers: record.ticket.numbers,
                                matched: record.matched)
            }
        }
        jar = JarBuilder.build(jarEntries ?? [], range: range, now: periodEnd)
    }

    private func recomputeSeries() {
        series = ProfitStats.series(
            entries: entries, range: range, now: periodEnd,
            sampleDays: chartStyle != HomeChartStyle.grid.rawValue
        )
    }

    private func recomputePeriodStats() {
        let calendar = Calendar.chinaCalendar
        let year = calendar.component(.year, from: periodEnd)
        let month = calendar.component(.month, from: periodEnd)
        switch range {
        case .all:
            periodStats = ProfitStats.period(entries: allEntries, year: nil, month: nil)
        case .year, .half:
            periodStats = ProfitStats.period(entries: allEntries, year: year, month: nil)
        case .month:
            periodStats = ProfitStats.period(entries: allEntries, year: year, month: month)
        }
    }

    private func refreshSchedule() {
        todayGames = Set(drawStore.todayOpenGames())
        var times: [GameKey: Date] = [:]
        for game in todayGames { times[game] = drawStore.todayDrawTime(for: game) }
        todayDrawTimes = times
        pendingGames = drawStore.pendingDrawUpdates()
        let order = drawStore.carouselOrder()
        carouselGames = order
        #if DEBUG && targetEnvironment(simulator)
        if DemoData.isEnabled, ProcessInfo.processInfo.arguments.contains("--store-dlt"),
           let index = order.firstIndex(of: .dlt) {
            carouselIndex = index
            pageIndex = index + 1
            return
        }
        #endif
        // 轮播顺序会随「今天开哪个彩种」变化，旧的下标可能越界，
        // 越界后 TabView 会白屏一页。
        if carouselIndex >= order.count || pageIndex > order.count + 1 || pageIndex < 0 {
            carouselIndex = 0
            pageIndex = 1
        }
    }

    // MARK: - 主舞台：无外框累计收支 + 放大版玻璃球罐

    /// 取消顶部白卡片外壳：累计收支与彩点指标直接写在清透白底微光画布上，
    /// 下方承接独立放大的玻璃球罐（或可切换的曲线/方格轻雾卡）。
    private var heroSection: some View {
        let showsSteppers = range == .month || range == .year
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("累计收支")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .onTapGesture(perform: openProfitPicker)
                        Button(action: openProfitPicker) {
                            Image(systemName: "calendar")
                                .scaledFont(11, weight: .medium)
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle().inset(by: -8))
                        }
                        .buttonStyle(PressableIcon())
                        .accessibilityLabel("选择统计区间，当前 \(periodLabel)")
                        .accessibilityIdentifier("home.profit.period")
                    }

                    Spacer(minLength: 4)

                    // 选中「全部」时收起左右翻期箭头，让分段条自然贴紧右边缘不留空缺；
                    // 采用按内容分配宽度的原生分段控件，固定总宽防切期横向跳动，同时彻底避免「2026-09」等月份被截成省略号。
                    HStack(spacing: 5) {
                        if showsSteppers {
                            periodStepButton("chevron.left",
                                             enabled: canStepPeriod(by: -1),
                                             id: "home.period.prev",
                                             label: range == .month ? "上个月" : "上一年") {
                                stepPeriod(by: -1)
                            }
                            .transition(.scale(scale: 0.65).combined(with: .opacity))
                        }

                        HomeRangeSegmentedControl(
                            selection: Binding(
                                get: { range },
                                set: { next in
                                    historicalEnd = nil
                                    range = next
                                }
                            ),
                            monthTitle: range == .month ? periodLabel : "本月",
                            yearTitle: range == .year ? periodLabel : "本年",
                            allTitle: "全部"
                        )
                        .frame(width: rangePickerWidth, height: 32)

                        if showsSteppers {
                            periodStepButton("chevron.right",
                                             enabled: canStepPeriod(by: 1),
                                             id: "home.period.next",
                                             label: range == .month ? "下个月" : "下一年") {
                                stepPeriod(by: 1)
                            }
                            .transition(.scale(scale: 0.65).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.34, bounce: 0.08), value: showsSteppers)
                }

                HStack(alignment: .center, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(MoneyText.grouped(series.netTotal))
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .tracking(-1.0)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("元")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Palette.profitColor(series.netTotal))
                    .accessibilityElement(children: .combine)

                    Spacer(minLength: 4)

                    // 球罐设为默认首项，曲线与方格图完整保留并共享时间范围。
                    Picker("图表样式", selection: $chartStyle) {
                        Image(systemName: "circle.hexagongrid.fill")
                            .accessibilityLabel("球罐")
                            .tag(HomeChartStyle.jar.rawValue)
                        Image(systemName: "chart.xyaxis.line")
                            .accessibilityLabel("曲线")
                            .tag(HomeChartStyle.line.rawValue)
                        Image(systemName: "square.grid.3x3.fill")
                            .accessibilityLabel("方格")
                            .tag(HomeChartStyle.grid.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("home.chart.style")
                }
            }

            chartTotals

            Group {
                if chartStyle == HomeChartStyle.jar.rawValue {
                    BallJarView(jar: jar, periodLabel: periodLabel, height: adaptiveJarHeight)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if chartStyle == HomeChartStyle.grid.rawValue {
                    VStack(alignment: .leading, spacing: 10) {
                        ProfitHeatmap(days: series.days, range: range, end: periodEnd,
                                      width: screenWidth - HomeLayout.pagePadding * 2)
                            .id(periodLabel)
                        HStack(spacing: 12) {
                            heatLegend(Palette.profit, "有中奖")
                            heatLegend(Palette.loss, "未中奖")
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    ProfitFlowChart(series: series, mode: .cumulative)
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.smooth(duration: 0.3), value: chartStyle)
        }
        .sensoryFeedback(.selection, trigger: range)
        .sensoryFeedback(.selection, trigger: chartStyle)
    }

    private func periodStepButton(_ symbol: String,
                                  enabled: Bool,
                                  id: String,
                                  label: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(11, weight: .bold)
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)
                .glassCircle(interactive: enabled)
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(PressableIcon())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.28)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var chartTotals: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                metricDotStat("返奖率", returnRateText, dot: Palette.profit,
                              tint: series.prizeTotal > 0 ? Palette.profit : .secondary)
                metricDotStat("奖金", "\(MoneyText.grouped(series.prizeTotal)) 元",
                              dot: BallColor.red.accentColor, tint: Palette.profit)
            }
            GridRow {
                metricDotStat("投入", "\(MoneyText.grouped(series.costTotal)) 元",
                              dot: Palette.chartSpending, tint: Palette.chartSpending)
                metricDotStat("公益金", "\(MoneyText.grouped(series.welfareTotal)) 元",
                              dot: Palette.warning, tint: Palette.warning)
            }
        }
        .accessibilityIdentifier("home.chart.totals")
    }

    private func metricDotStat(_ title: String, _ value: String, dot: Color, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(tint)
        }
        .font(.footnote)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .accessibilityElement(children: .combine)
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

    /// 一分钱都还没结算时，返奖率是 0/0 —— 写成「—」避免误导。
    private var returnRateText: String {
        series.costTotal > 0 ? String(format: "%.0f%%", series.prizeTotal / series.costTotal * 100) : "—"
    }

    // MARK: - 最新开奖（全宽轨道无裁切 + 彩种微染卡面）

    private var latestDrawSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(
                title: "最新开奖",
                subtitle: drawStore.latestUpdatedAt.isEmpty
                    ? "暂无更新时间"
                    : "更新于 \(DateText.friendly(drawStore.latestUpdatedAt))",
                action: { isDrawSheetPresented = true }
            )
            .padding(.horizontal, HomeLayout.pagePadding)

            // TabView 撑满整屏宽（外层 0 水平边距），边距放在每页卡片内侧。
            // 这样自动/手动横滑时，卡片可以顺畅滑到手机物理屏幕边缘，不再在 16pt 处提前被截断。
            TabView(selection: $pageIndex) {
                ForEach(carouselPages, id: \.self) { page in
                    let game = carouselGames[realIndex(page)]
                    DrawCard(game: game,
                             draw: drawStore.latestDraw(for: game),
                             opensToday: todayGames.contains(game),
                             drawsAt: todayDrawTimes[game])
                        .padding(.horizontal, HomeLayout.carouselPagePadding)
                        .padding(.vertical, 2)
                        .tag(page)
                }
            }
            .onChange(of: pageIndex) { _, page in
                carouselIndex = realIndex(page)
                if isAutoAdvancing {
                    isAutoAdvancing = false
                } else {
                    // 用户主动左右滑动切换了开奖卡，暂停自动轮播 12 秒，且不挂 DragGesture 阻塞竖滑。
                    autoScrollResumeAt = Date().addingTimeInterval(12)
                }
                wrapIfNeeded(page)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.45), value: pageIndex)
            // 卡片去掉外层灰影后不再需要阴影缓冲，收紧留白让免责提示与状态圆点完整露在底栏上方。
            .frame(height: DrawCardMetrics.unifiedHeight(screenWidth: screenWidth) + 4)
            .accessibilityHint("左右滑动查看其他彩种的最新开奖")
            .task(id: carouselGames.count) { await runAutoScroll() }

            Text(Disclaimer.draw)
                .scaledFont(10)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, HomeLayout.pagePadding)

            pageDots
                .padding(.horizontal, HomeLayout.pagePadding)
        }
        .sheet(isPresented: $isDrawSheetPresented) {
            DrawHistoryView(initialGame: currentCarouselGame)
        }
    }

    /// 开奖卡片自动轮播。减弱动效下完全不转。
    private func runAutoScroll() async {
        #if DEBUG && targetEnvironment(simulator)
        if DemoData.isEnabled, ProcessInfo.processInfo.arguments.contains("--store-dlt") { return }
        #endif
        guard !reduceMotion, carouselGames.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, Date() >= autoScrollResumeAt else { continue }
            isAutoAdvancing = true
            pageIndex += 1
        }
    }

    // MARK: - 轮播的环

    private var currentCarouselGame: GameKey {
        guard carouselGames.indices.contains(carouselIndex) else {
            return carouselGames.first ?? .ssq
        }
        return carouselGames[carouselIndex]
    }

    private var carouselPages: [Int] {
        guard carouselGames.count > 1 else { return carouselGames.isEmpty ? [] : [1] }
        return Array(0...(carouselGames.count + 1))
    }

    private func realIndex(_ page: Int) -> Int {
        let count = carouselGames.count
        guard count > 0 else { return 0 }
        guard count > 1 else { return 0 }
        return ((page - 1) % count + count) % count
    }

    private func wrapIfNeeded(_ page: Int) {
        let count = carouselGames.count
        guard count > 1, page == 0 || page == count + 1 else { return }
        let target = page == 0 ? count : 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(480))
            guard pageIndex == page else { return }
            isAutoAdvancing = true
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { pageIndex = target }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(carouselGames.enumerated()), id: \.element) { index, game in
                Capsule()
                    .fill(index == carouselIndex ? game.tint : Color.primary.opacity(0.16))
                    .frame(width: index == carouselIndex ? 18 : 6, height: 6)
                    .animation(.spring(duration: 0.3, bounce: 0), value: carouselIndex)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    private var pendingNotice: some View {
        Label("今日\(pendingGames.map(\.label).joined(separator: "、"))的开奖号码尚未更新",
              systemImage: "clock.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(Palette.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - 彩种投入分布（去重瘦身，跟随首页统一时间范围）

    private var spendCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("彩种投入分布")
                        .font(.headline)
                    Text("\(periodLabel) · 本机记录 \(periodStats.ticketCount) 注")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if periodStats.ticketCount > 0 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("中奖率")
                            .scaledFont(10, weight: .medium)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", periodStats.winRate))
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(periodStats.winRate > 0 ? Palette.profit : .primary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("中奖率 \(String(format: "%.0f%%", periodStats.winRate))")
                }
            }

            if periodStats.byGame.isEmpty {
                Text("这一段还没有记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                SpendBreakdown(items: periodStats.byGame, total: periodStats.cost, limit: periodStats.byGame.count)
            }
        }
        .contentCard(cornerRadius: 22)
    }
}

/// 首页的固定尺寸。
///
/// 开奖卡片轮播撑满整屏宽，单张卡片左右内缩 `carouselPagePadding`（与页面 16pt 对齐），
/// 滑动时可以顺畅滑到屏幕物理边缘而不被提前截断。
enum HomeLayout {
    static let pagePadding: CGFloat = 16
    static let carouselPagePadding: CGFloat = 16

    static var fallbackScreenWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.width }
            .first ?? 393
    }
}

private struct ScreenWidthKey: EnvironmentKey {
    static var defaultValue: CGFloat { HomeLayout.fallbackScreenWidth }
}

extension EnvironmentValues {
    var screenWidth: CGFloat {
        get { self[ScreenWidthKey.self] }
        set { self[ScreenWidthKey.self] = newValue }
    }
}

/// 首页主舞台画哪一种视图。
enum HomeChartStyle: String {
    case jar, line, grid

    /// 选的样式记在哪。示例模式（截图、界面测试）每次启动都用一份清空了的，
    /// 不然一条测试切到别处，后面的测试和截图打开首页看到的视图会串。
    static let store: UserDefaults = {
        guard ProcessInfo.processInfo.arguments.contains("--demo-data"),
              let demo = UserDefaults(suiteName: "demo.home") else { return .standard }
        demo.removePersistentDomain(forName: "demo.home")
        return demo
    }()
}

// MARK: - 收支热力图

/// 逐日收支方格图。
struct ProfitHeatmap: View {
    let days: [ProfitDay]
    let range: ProfitRange

    private let cell: CGFloat
    private static let gapSize: CGFloat = 4
    private var gap: CGFloat { Self.gapSize }
    private static let minCell: CGFloat = 11
    private static let maxCell: CGFloat = 26

    private let grid: Grid

    init(days: [ProfitDay], range: ProfitRange, end: Date, width: CGFloat) {
        self.days = days
        self.range = range
        let grid = Self.buildGrid(days: days, range: range, end: end)
        self.grid = grid
        let columns = CGFloat(Swift.max(grid.weeks.count, 1))
        let fitted = (width - Self.gapSize * (columns - 1)) / columns
        self.cell = Swift.min(Swift.max(fitted.rounded(.down), Self.minCell), Self.maxCell)
    }

    private struct Grid {
        let byDay: [String: ProfitDay]
        let weeks: [[Date?]]
        let monthLabels: [String]
    }

    struct WeekSummary: Equatable {
        let title: String
        let cost: Double
        let prize: Double
        let days: Int
        let wonDays: Int

        var net: Double { prize - cost }
        var hitRate: Double { days > 0 ? Double(wonDays) / Double(days) : 0 }
    }

    @State private var selectedWeek: Int?

    private static func buildGrid(days: [ProfitDay], range: ProfitRange, end periodEnd: Date) -> Grid {
        var byDay: [String: ProfitDay] = [:]
        byDay.reserveCapacity(days.count)
        for day in days where day.count > 0 { byDay[day.date] = day }

        let calendar = Calendar.chinaCalendar
        let today = calendar.startOfDay(for: periodEnd)
        let daysWithRecords = days.filter { $0.count > 0 }
        let firstDay = daysWithRecords.first?.date ?? DateText.day(today)
        let lastDay = daysWithRecords.last?.date ?? firstDay
        let startDay = range.startDay(firstDay: firstDay, lastDay: lastDay, now: today)
        let end = range == .all ? max(today, daysWithRecords.last?.day ?? today) : today
        guard let start = DateText.parse(startDay) else {
            return Grid(byDay: byDay, weeks: [], monthLabels: [])
        }
        let weekdayIndex = (calendar.component(.weekday, from: start) + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -weekdayIndex, to: start) else {
            return Grid(byDay: byDay, weeks: [], monthLabels: [])
        }

        var weeks: [[Date?]] = []
        var cursor = gridStart
        while cursor <= end {
            var column: [Date?] = []
            for _ in 0..<7 {
                column.append(cursor >= start && cursor <= end ? cursor : nil)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            weeks.append(column)
        }

        var labels: [String] = []
        var previousMonth = 0
        for (index, column) in weeks.enumerated() {
            guard let first = column.compactMap({ $0 }).first else { labels.append(""); continue }
            let month = calendar.component(.month, from: first)
            defer { previousMonth = month }
            if index == 0 {
                labels.append(column.compactMap { $0 }.count >= 4 ? "\(month)月" : "")
            } else {
                labels.append(month == previousMonth ? "" : "\(month)月")
            }
        }
        return Grid(byDay: byDay, weeks: weeks, monthLabels: labels)
    }

    var body: some View {
        let grid = self.grid
        return VStack(alignment: .leading, spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: gap) {
                    ForEach(Array(grid.weeks.enumerated()), id: \.offset) { index, column in
                        VStack(alignment: .leading, spacing: 5) {
                            VStack(spacing: gap) {
                                ForEach(Array(column.enumerated()), id: \.offset) { _, date in
                                    cellView(for: date, byDay: grid.byDay)
                                }
                            }
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
                                    .presentationCompactAdaptation(.popover)
                            }
                            let label = grid.monthLabels[index]
                            Text(label.isEmpty ? " " : label)
                                .scaledFont(10)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(width: cell, alignment: .leading)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .defaultScrollAnchor(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("逐日收支方格图，共 \(grid.byDay.count) 天有记录")
    }

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

/// 开奖卡片的尺寸计算。所有卡片统一高度，避免轮播翻页时页面下方跟着跳动。
enum DrawCardMetrics {
    static let maxBall: CGFloat = 30
    static let minBall: CGFloat = 18
    static let ballGap: CGFloat = 0.19
    static let sectionGap: CGFloat = 0.24
    static let lineGap: CGFloat = 0.22
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 22
    static let k8PerRow = 10

    static let headerHeight: CGFloat = 22
    static let prizeRowHeight: CGFloat = 17
    static let blockSpacing: CGFloat = 6

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

    static func unifiedHeight(screenWidth: CGFloat) -> CGFloat {
        let inner = innerWidth(screenWidth: screenWidth)
        let chrome = headerHeight + verticalPadding * 2 + blockSpacing * 2

        let k8Ball = ballSize(perRow: k8PerRow, sections: 1, spansAllSections: false, width: inner)
        let k8Height = chrome + (2 * k8Ball + k8Ball * lineGap) + prizeRowHeight * 2

        let wideBall = ballSize(perRow: 8, sections: 2, spansAllSections: true, width: inner)
        let otherHeight = chrome + wideBall + prizeRowHeight * 2

        return Swift.max(k8Height, otherHeight).rounded(.up)
    }

    /// 轮播容器本身占满整屏宽，单张卡片只在内部缩进 `carouselPagePadding` 与 `horizontalPadding`。
    static func innerWidth(screenWidth: CGFloat) -> CGFloat {
        screenWidth - HomeLayout.carouselPagePadding * 2 - horizontalPadding * 2
    }
}

/// 首页轮播里的一张开奖卡：与票夹 `TicketPaper` 共用按感知明度校准的极淡彩种微染，
/// 浅色下直接落在纯白画布上、不加外层灰影，让卡片通透融入应用背景。
struct DrawCard: View {
    @Environment(\.screenWidth) private var screenWidth
    @Environment(\.colorScheme) private var colorScheme

    let game: GameKey
    let draw: Draw?
    var opensToday: Bool = false
    var drawsAt: Date? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DrawCardMetrics.cornerRadius, style: .continuous)
        let wash = game.paperTint(for: colorScheme)
        VStack(alignment: .leading, spacing: DrawCardMetrics.blockSpacing) {
            header
            Spacer(minLength: 0)
            numbersRow
            Spacer(minLength: 0)
            DrawPrizeLines(game: game, draw: draw)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DrawCardMetrics.verticalPadding)
        .padding(.horizontal, DrawCardMetrics.horizontalPadding)
        .frame(height: DrawCardMetrics.unifiedHeight(screenWidth: screenWidth))
        .background {
            ZStack {
                shape.fill(Palette.card)
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: wash, location: 0.0),
                            .init(color: wash.opacity(0.35), location: 0.38),
                            .init(color: .clear, location: 0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .clipShape(shape)
        }
        .overlay {
            shape.strokeBorder(game.paperBorder(for: colorScheme), lineWidth: 1)
        }
    }

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
                .foregroundStyle(game.accent.accentColor)

            if opensToday {
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
enum PrizeRanking {
    static func topTwo(of list: [PrizeEntry], game: GameKey, digits: [Int] = []) -> [PrizeEntry] {
        if game == .k8 {
            var open: [(offset: Int, entry: PrizeEntry)] = []
            for (offset, entry) in list.enumerated() where entry.winningCount > 0 && entry.amount > 0 {
                open.append((offset, entry))
            }
            let ranked = open.sorted { lhs, rhs in
                lhs.entry.amount == rhs.entry.amount
                    ? lhs.offset < rhs.offset
                    : lhs.entry.amount > rhs.entry.amount
            }
            return Array(ranked.prefix(2).map(\.entry))
        }

        if game == .fc3d || game == .pl3 {
            let direct = list.first { ($0.prizeName.contains("直选") || $0.prizeName.contains("单选")) && ($0.winningCount > 0 || $0.amount > 0) }
            let g3 = list.first { ($0.prizeName.contains("组三") || $0.prizeName.contains("组选3") || $0.prizeName.contains("组选三")) && ($0.winningCount > 0 || $0.amount > 0) }
            let g6 = list.first { ($0.prizeName.contains("组六") || $0.prizeName.contains("组选6") || $0.prizeName.contains("组选六")) && ($0.winningCount > 0 || $0.amount > 0) }
            let ordered = [direct, g3, g6].compactMap { $0 }

            // 优先按真实中奖注数挑（如排列3：组三期只有直选+组选3有注数，豹子期只有直选有注数）。
            let withWinners = ordered.filter { $0.winningCount > 0 }
            if !withWinners.isEmpty {
                return Array(withWinners.prefix(2))
            }
            // 数据源未公布注数时（如福彩3D 固定奖），按当期开奖 3 码的重复形态自动匹配当期可中奖项：
            // 3 个同号（豹子）仅直选；2 个同号为直选 + 组三；3 个不同号为直选 + 组六。
            if digits.count == 3 {
                switch Set(digits).count {
                case 1: return [direct].compactMap { $0 }
                case 2: return [direct, g3].compactMap { $0 }
                default: return [direct, g6].compactMap { $0 }
                }
            }
            return Array(ordered.prefix(2))
        }

        return ["一等奖", "二等奖"].compactMap { name in
            list.first { $0.prizeName.contains(name) && ($0.winningCount > 0 || $0.amount > 0) }
        }
    }
}

/// 首页「本月 / 本年 / 全部」原生分段控件：
/// 开启 `apportionsSegmentWidthsByContent`，按文案真实宽度分配三格空间，
/// 彻底解决 SwiftUI `Picker(.segmented)` 强制等宽导致「2026-09」「2026-08」被截成省略号的问题；
/// 同时保持固定总宽度与官方 iOS 26/27 液态玻璃滑动跳动透镜。
private struct HomeRangeSegmentedControl: UIViewRepresentable {
    @Binding var selection: ProfitRange
    let monthTitle: String
    let yearTitle: String
    let allTitle: String

    @Environment(\.colorScheme) private var colorScheme

    private static let ranges: [ProfitRange] = [.month, .year, .all]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> TallSegmentedControl {
        let control = TallSegmentedControl(items: [monthTitle, yearTitle, allTitle])
        control.targetHeight = 32
        control.apportionsSegmentWidthsByContent = true
        control.accessibilityIdentifier = "home.range"
        control.selectedSegmentIndex = Self.ranges.firstIndex(of: selection) ?? 1
        control.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        applyTypography(to: control)
        return control
    }

    func updateUIView(_ uiView: TallSegmentedControl, context: Context) {
        context.coordinator.parent = self
        let titles = [monthTitle, yearTitle, allTitle]
        var changed = false
        for (index, title) in titles.enumerated() where uiView.titleForSegment(at: index) != title {
            uiView.setTitle(title, forSegmentAt: index)
            changed = true
        }
        let targetIndex = Self.ranges.firstIndex(of: selection) ?? 1
        if uiView.selectedSegmentIndex != targetIndex {
            uiView.selectedSegmentIndex = targetIndex
        }
        applyTypography(to: uiView)
        if changed {
            uiView.setNeedsLayout()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TallSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 206, height: 32)
    }

    private func applyTypography(to control: TallSegmentedControl) {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        traits.performAsCurrent {
            control.selectedSegmentTintColor = nil
            control.setTitleTextAttributes([
                .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: UIColor.label.withAlphaComponent(0.76)
            ], for: .normal)
            control.setTitleTextAttributes([
                .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.label
            ], for: .selected)
        }
    }

    final class Coordinator: NSObject {
        var parent: HomeRangeSegmentedControl

        init(_ parent: HomeRangeSegmentedControl) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: UISegmentedControl) {
            let index = sender.selectedSegmentIndex
            guard HomeRangeSegmentedControl.ranges.indices.contains(index) else { return }
            parent.selection = HomeRangeSegmentedControl.ranges[index]
        }
    }
}
