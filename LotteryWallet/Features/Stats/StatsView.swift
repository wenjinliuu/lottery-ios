import SwiftUI
import SwiftData
import Charts

/// 统计：按年或按月查看盈亏、彩种占比、全年彩种堆叠与每日明细。
struct StatsView: View {
    @Query(sort: \TicketRecord.createdAt, order: .reverse) private var records: [TicketRecord]

    @State private var year = Calendar.chinaCalendar.component(.year, from: Date())
    @State private var month: Int? = Calendar.chinaCalendar.component(.month, from: Date())
    @State private var entries: [SettledEntry] = []
    @State private var stats = ProfitStats.PeriodStats()
    @State private var years: [Int] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                selector
                kpiGrid
                gameShareCard
                if month == nil { monthlyStackCard }
                calendarCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .background(Palette.canvas)
        .navigationTitle("统计")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: RecordsToken(records)) { reload() }
        .onChange(of: year) { _, _ in recompute() }
        .onChange(of: month) { _, _ in recompute() }
    }

    private func reload() {
        entries = ProfitStats.snapshotAll(records)
        years = ProfitStats.availableYears(entries: entries)
        recompute()
    }

    private func recompute() {
        stats = ProfitStats.period(entries: entries, year: year, month: month)
    }

    // MARK: - 年月选择

    private var selector: some View {
        HStack(spacing: 10) {
            Picker("年份", selection: $year) {
                ForEach(years, id: \.self) { Text("\($0) 年").tag($0) }
            }
            .pickerStyle(.menu)

            Picker("月份", selection: Binding(
                get: { month ?? 0 },
                set: { month = $0 == 0 ? nil : $0 }
            )) {
                Text("全年").tag(0)
                ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) }
            }
            .pickerStyle(.menu)

            Spacer()
        }
        .contentCard(padding: 8)
    }

    private var kpiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            kpi("投入", MoneyText.format(stats.cost), "cart", .secondary)
            kpi("奖金", MoneyText.format(stats.prize), "trophy", Palette.profit)
            kpi("盈亏", MoneyText.format(stats.net), "chart.line.uptrend.xyaxis", Palette.profitColor(stats.net))
            kpi("中奖率", String(format: "%.1f%%", stats.winRate), "target", .secondary)
        }
    }

    private func kpi(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .contentCard(cornerRadius: 14)
    }

    private var gameShareCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "彩种花费占比", subtitle: "共 \(stats.ticketCount) 注")
            if stats.byGame.isEmpty {
                emptyHint
            } else {
                Chart(stats.byGame) { item in
                    SectorMark(angle: .value("花费", item.cost),
                               innerRadius: .ratio(0.6),
                               angularInset: 1.5)
                        .foregroundStyle(by: .value("彩种", item.game.label))
                        .cornerRadius(4)
                }
                .chartForegroundStyleScale(domain: stats.byGame.map(\.game.label),
                                           range: stats.byGame.map(\.game.tint))
                .frame(height: 200)
            }
        }
        .contentCard()
    }

    private var monthlyStackCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "全年彩种花费", subtitle: "\(year) 年逐月堆叠")
            let rows = (1...12).flatMap { index in
                (stats.byMonth[index] ?? []).map { (month: index, spend: $0) }
            }
            if rows.isEmpty {
                emptyHint
            } else {
                Chart {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        BarMark(x: .value("月份", "\(row.month)月"),
                                y: .value("花费", row.spend.cost))
                            .foregroundStyle(by: .value("彩种", row.spend.game.label))
                            .cornerRadius(3)
                    }
                }
                .chartForegroundStyleScale(domain: GameKey.ordered.map(\.label),
                                           range: GameKey.ordered.map(\.tint))
                .frame(height: 210)
            }
        }
        .contentCard()
    }

    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "每日明细",
                          subtitle: month == nil ? "全年有记录的日子" : "\(month ?? 0) 月")
                .padding(.bottom, 8)
            if stats.byDay.isEmpty {
                emptyHint
            } else {
                ForEach(stats.byDay) { day in
                    HStack {
                        Text(DateText.monthDay(day.date))
                            .font(.subheadline)
                            .monospacedDigit()
                        Spacer()
                        Text("\(day.count) 注")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(MoneyText.format(day.net))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Palette.profitColor(day.net))
                            .frame(width: 90, alignment: .trailing)
                    }
                    .padding(.vertical, 9)
                    if day.id != stats.byDay.last?.id {
                        Divider()
                    }
                }
            }
        }
        .contentCard()
    }

    private var emptyHint: some View {
        Text("这个区间还没有记录")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
    }
}
