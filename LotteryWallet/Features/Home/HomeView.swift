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
    @State private var isDrawSheetPresented = false

    /// 开奖日程也不能在 body 里算。`todayOpenGames` / `pendingDrawUpdates` /
    /// `carouselOrder` 每次都要取一遍东八区时间、过一遍八个彩种，
    /// 而 body 在滚动时一秒会跑很多次。统一在数据变化时算好存下来。
    @State private var todayGames: [GameKey] = []
    @State private var pendingGames: [GameKey] = []
    @State private var carouselGames: [GameKey] = GameKey.ordered

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    todayStrip
                    profitCard
                    latestDrawSection
                    monthlyCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 120)
            }
            .background(Palette.canvas)
            .navigationTitle("彩票夹")
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
        todayGames = drawStore.todayOpenGames()
        pendingGames = drawStore.pendingDrawUpdates()
        let order = drawStore.carouselOrder()
        carouselGames = order
        // 轮播顺序会随「今天开哪个彩种」变化，旧的下标可能越界，
        // 越界后 TabView 会白屏一页。
        if carouselIndex >= order.count { carouselIndex = 0 }
    }

    // MARK: - 今日开奖

    private var todayStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                Text(todayGames.isEmpty ? "今日无开奖" : "今日开奖")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            if !todayGames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(todayGames) { game in
                            Text(game.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(game.tint)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(game.tint.opacity(0.13), in: Capsule())
                        }
                    }
                }
                .scrollClipDisabled()
            }

            if !pendingGames.isEmpty {
                Label("今日\(pendingGames.map(\.label).joined(separator: "、"))开奖号码尚未更新",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(Palette.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        // 用 .title 而不是写死 32pt，跟着动态字体走；
                        // 同时限制成一行、可缩放，金额上百万也不会撑破卡片。
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
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

            if series.isEmpty {
                emptyChart
            } else {
                profitChart
            }

            Divider()

            // 三列等宽。原来用 Spacer 分隔，金额一长就把后面两列挤没了。
            HStack(alignment: .top, spacing: 10) {
                statPair("投入", MoneyText.format(series.costTotal))
                statPair("奖金", MoneyText.format(series.prizeTotal))
                statPair("已结算", "\(series.settledCount) 注")
            }
        }
        .contentCard()
    }

    private var profitChart: some View {
        Chart {
            // 盈亏曲线没有零基线就看不出在赚还是在亏。
            // 注意画在 ForEach 外面：写在数据循环里会按点数重复画上百条。
            RuleMark(y: .value("盈亏平衡", 0.0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.quaternary)

            ForEach(series.days) { day in
                AreaMark(x: .value("日期", day.day), y: .value("累计", day.close))
                    .foregroundStyle(
                        LinearGradient(colors: [Palette.profitColor(series.netTotal).opacity(0.22), .clear],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .interpolationMethod(.monotone)

                LineMark(x: .value("日期", day.day), y: .value("累计", day.close))
                    .foregroundStyle(Palette.profitColor(series.netTotal))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(MoneyText.compact(number)).font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    .font(.caption2)
            }
        }
        .frame(height: 160)
    }

    private var emptyChart: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.flattrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("还没有已结算的记录")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
    }

    private func statPair(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
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
                    DrawCard(game: game, draw: drawStore.latestDraw(for: game))
                        .padding(.bottom, 30)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            // 分页圆点默认是半透明的，压在浅色分组底上几乎看不见，
            // 用户根本不知道这里可以左右滑。加一层背景把它衬出来。
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .frame(height: 212)
            .accessibilityHint("左右滑动查看其他彩种的最新开奖")
        }
        .sheet(isPresented: $isDrawSheetPresented) {
            DrawHistoryView()
        }
    }

    // MARK: - 本月概览

    private var monthlyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "本月概览", subtitle: "统计本机保存的记录")

            HStack(spacing: 12) {
                kpi("投入", MoneyText.format(monthStats.cost), .primary)
                kpi("奖金", MoneyText.format(monthStats.prize), Palette.profit)
                kpi("盈亏", MoneyText.format(monthStats.net), Palette.profitColor(monthStats.net))
            }

            if monthStats.byGame.isEmpty {
                Text("本月还没有记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                Chart(monthStats.byGame) { item in
                    BarMark(x: .value("花费", item.cost), y: .value("彩种", item.game.label))
                        .foregroundStyle(item.game.tint)
                        .cornerRadius(5)
                        // X 轴是隐藏的，柱子上不标数值就只剩长短，读不出金额
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(MoneyText.format(item.cost))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                // 留出右侧标注的位置，否则最长的那根柱子的金额会被裁掉
                .chartXScale(domain: 0...Swift.max((monthStats.byGame.map(\.cost).max() ?? 0) * 1.35, 1))
                .frame(height: CGFloat(monthStats.byGame.count) * 30 + 10)
            }
        }
        .contentCard()
    }

    private func kpi(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// 首页轮播里的一张开奖卡。
struct DrawCard: View {
    let game: GameKey
    let draw: Draw?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(game.tint)
                    .frame(width: 8, height: 8)
                Text(game.label)
                    .font(.headline)
                Spacer(minLength: 8)
                if let draw {
                    Text("第 \(draw.expect) 期 · \(DateText.monthDay(draw.openDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            if let draw {
                ScrollView(.horizontal, showsIndicators: false) {
                    DrawNumbersView(draw: draw, size: 32)
                }
                .scrollClipDisabled()

                if let first = draw.firstPrize {
                    HStack(spacing: 8) {
                        Text("一等奖 \(first.winningCount) 注")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if first.amount > 0 {
                            Text(MoneyText.compactYuan(first.amount) + "/注")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(game.tint)
                        }
                    }
                }
            } else {
                Text("暂无开奖数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            Spacer(minLength: 0)
        }
        .contentCard()
    }
}
