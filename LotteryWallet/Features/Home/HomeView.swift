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
    @Namespace private var glassNamespace

    private var carouselGames: [GameKey] { drawStore.carouselOrder() }

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
                }
            }
            .overlay(alignment: .bottomTrailing) { floatingButtons }
            .refreshable { await drawStore.refresh() }
            .task(id: RecordsToken(records)) { recompute() }
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

    // MARK: - 今日开奖

    private var todayStrip: some View {
        let games = drawStore.todayOpenGames()
        let pending = drawStore.pendingDrawUpdates()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                Text(games.isEmpty ? "今日无开奖" : "今日开奖")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            if !games.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(games) { game in
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

            if !pending.isEmpty {
                Label("今日\(pending.map(\.label).joined(separator: "、"))开奖号码尚未更新",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
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
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.profitColor(series.netTotal))
                        .contentTransition(.numericText())
                }
                Spacer()
                Picker("范围", selection: $range) {
                    ForEach(ProfitRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(.secondary)
            }

            if series.isEmpty {
                emptyChart
            } else {
                profitChart
            }

            Divider()

            HStack {
                statPair("投入", MoneyText.format(series.costTotal))
                Spacer()
                statPair("奖金", MoneyText.format(series.prizeTotal))
                Spacer()
                statPair("已结算", "\(series.settledCount) 注")
            }
        }
        .contentCard()
    }

    private var profitChart: some View {
        Chart(series.days) { day in
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
        }
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
                        .padding(.bottom, 26)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(height: 208)
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
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(monthStats.byGame.count) * 28 + 10)
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

    // MARK: - 悬浮按钮（这一层才用玻璃）

    private var floatingButtons: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                Button(action: onOpenEntry) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .glassCircle()
                .glassMorph(id: "entry", in: glassNamespace)

                Button(action: onOpenScan) {
                    Image(systemName: "camera.viewfinder")
                        .font(.title3.weight(.semibold))
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .glassMorph(id: "scan", in: glassNamespace)
            }
        }
        .padding(.trailing, 18)
        .padding(.bottom, 22)
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
                Spacer()
                if let draw {
                    Text("第 \(draw.expect) 期 · \(DateText.monthDay(draw.openDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            Text(MoneyText.compact(first.amount) + " 元/注")
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
