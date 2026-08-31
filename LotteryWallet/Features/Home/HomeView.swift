import SwiftUI
import SwiftData
import Charts

struct HomeView: View {
    var onOpenEntry: () -> Void
    var onOpenScan: () -> Void

    @Environment(DrawStore.self) private var drawStore
    @Environment(\.showToast) private var showToast
    @Query(sort: \TicketRecord.createdAt, order: .reverse) private var records: [TicketRecord]

    @State private var range: ProfitRange = .all
    @State private var carouselIndex = 0
    @State private var isDrawSheetPresented = false
    @Namespace private var glassNamespace

    private var series: ProfitSeries {
        ProfitStats.series(records: records, range: range)
    }

    private var carouselGames: [GameKey] {
        drawStore.carouselOrder()
    }

    private var accent: Color {
        carouselGames.first?.tint ?? Color.accentColor
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    todayStrip
                    profitCard
                    latestDrawSection
                    monthlyCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .background { Palette.canvas(accent) }
            .scrollEdgeEffectStyle(.soft, for: .top)
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
            .overlay(alignment: .bottomTrailing) { floatingScanButton }
            .refreshable { await drawStore.refresh() }
        }
    }

    // MARK: - 今日开奖

    private var todayStrip: some View {
        let games = drawStore.todayOpenGames()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption)
                Text(games.isEmpty ? "今日无开奖" : "今日开奖")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)

            if !games.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassGroup(spacing: 10) {
                        HStack(spacing: 8) {
                            ForEach(games) { game in
                                Text(game.label)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(game.gradient, in: Capsule())
                                    .shadow(color: game.tint.opacity(0.28), radius: 6, y: 3)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if !drawStore.pendingDrawUpdates().isEmpty {
                let names = drawStore.pendingDrawUpdates().map(\.label).joined(separator: "、")
                Label("今日\(names)开奖号码尚未更新", systemImage: "clock.badge.exclamationmark")
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("累计盈亏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(MoneyText.format(series.netTotal))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.profitColor(series.netTotal))
                        .contentTransition(.numericText())
                }
                Spacer()
                Picker("范围", selection: $range.animation(.easeInOut(duration: 0.25))) {
                    ForEach(ProfitRange.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
            }

            if series.isEmpty {
                emptyChartPlaceholder
            } else {
                profitChart
            }

            HStack(spacing: 18) {
                statPair(title: "投入", value: MoneyText.format(series.costTotal))
                statPair(title: "奖金", value: MoneyText.format(series.prizeTotal))
                statPair(title: "已结算", value: "\(series.days.reduce(0) { $0 + $1.count }) 注")
            }
        }
        .padding(18)
        .glassCard(tint: accent)
    }

    private var profitChart: some View {
        Chart(series.days) { day in
            AreaMark(
                x: .value("日期", day.day),
                yStart: .value("基线", 0),
                yEnd: .value("累计", day.close)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Palette.profitColor(series.netTotal).opacity(0.28), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("日期", day.day),
                y: .value("累计", day.close)
            )
            .foregroundStyle(Palette.profitColor(series.netTotal))
            .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .interpolationMethod(.monotone)
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(MoneyText.compact(number))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    .font(.caption2)
            }
        }
        .frame(height: 168)
    }

    private var emptyChartPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.flattrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("还没有已结算的记录")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 168)
    }

    private func statPair(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }

    // MARK: - 最新开奖

    private var latestDrawSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        .padding(.horizontal, 2)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .frame(height: 214)
        }
        .sheet(isPresented: $isDrawSheetPresented) {
            DrawHistoryView()
        }
    }

    // MARK: - 本月概览

    private var monthlyCard: some View {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DateText.chinaTimeZone
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let stats = ProfitStats.period(records: records, year: year, month: month)

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "本月概览", subtitle: "\(year) 年 \(month) 月 · 本机记录")

            HStack(spacing: 14) {
                kpi("投入", MoneyText.format(stats.cost), .secondary)
                kpi("奖金", MoneyText.format(stats.prize), Palette.profit)
                kpi("盈亏", MoneyText.format(stats.net), Palette.profitColor(stats.net))
            }

            if stats.byGame.isEmpty {
                Text("本月还没有记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                Chart(stats.byGame) { item in
                    BarMark(
                        x: .value("花费", item.cost),
                        y: .value("彩种", item.game.label)
                    )
                    .foregroundStyle(item.game.tint.gradient)
                    .cornerRadius(6)
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(stats.byGame.count) * 30 + 12)
            }
        }
        .padding(18)
        .glassCard(tint: accent)
    }

    private func kpi(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 悬浮扫描

    private var floatingScanButton: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                Button(action: onOpenEntry) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .glassCircle(tint: accent)
                .glassMorph(id: "entry", in: glassNamespace)

                Button(action: onOpenScan) {
                    Image(systemName: "camera.viewfinder")
                        .font(.title3.weight(.semibold))
                        .frame(width: 58, height: 58)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(accent.gradientFill, in: Circle())
                .shadow(color: accent.opacity(0.4), radius: 14, y: 6)
                .glassMorph(id: "scan", in: glassNamespace)
            }
        }
        .padding(.trailing, 18)
        .padding(.bottom, 24)
    }
}

/// 首页轮播里的一张开奖卡。
struct DrawCard: View {
    let game: GameKey
    let draw: Draw?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.label)
                        .font(.title3.weight(.bold))
                    if let draw {
                        Text("第 \(draw.expect) 期 · \(DateText.monthDay(draw.openDate))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Circle()
                    .fill(game.gradient)
                    .frame(width: 10, height: 10)
            }

            if let draw {
                DrawNumbersView(draw: draw, size: 32)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let first = draw.firstPrize {
                    HStack(spacing: 10) {
                        Label("一等奖 \(first.winningCount) 注", systemImage: "trophy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if first.amount > 0 {
                            Text(MoneyText.compact(first.amount) + "元/注")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(game.tint)
                        }
                    }
                }
            } else {
                Text("暂无开奖数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: game.tint)
    }
}
