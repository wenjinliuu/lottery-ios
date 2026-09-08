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
    @State private var isShowingAllDays = false
    @State private var isPeriodPickerPresented = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
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
        // 换年 / 换月之后重新收起，否则从"全年"切到某个月还留着展开状态
        if isShowingAllDays { isShowingAllDays = false }
    }

    // MARK: - 年月选择

    /// 年月选择。
    ///
    /// 第一版是两个 `.menu` Picker —— 点一下弹菜单、选完再弹一次，两级弹窗很碎。
    /// 第二版改成横滑芯片条 —— 月份要滑好几屏才够到，而且切月时崩过。
    /// 这一版按系统日历的做法：一行摘要，点开是一个年份左右翻 + 12 个月的网格，
    /// 一眼看全，一次点中。
    private var selector: some View {
        Button {
            isPeriodPickerPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(periodTitle)
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("更改")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentCard(padding: 14)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPeriodPickerPresented) {
            PeriodPicker(year: $year, month: $month, years: years)
        }
    }

    private var periodTitle: String {
        month.map { "\(year) 年 \($0) 月" } ?? "\(year) 年 全年"
    }

    private var kpiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            // 数值本身用 primary。原来给"投入""中奖率"传的是 .secondary，
            // KPI 最该看清的那个数字反而是灰的。
            kpi("投入", MoneyText.format(stats.cost), "cart", .primary)
            kpi("奖金", MoneyText.format(stats.prize), "trophy", Palette.profit)
            kpi("盈亏", MoneyText.format(stats.net), "chart.line.uptrend.xyaxis", Palette.profitColor(stats.net))
            kpi("中奖率", String(format: "%.1f%%", stats.winRate), "target", .primary)
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
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "彩种花费占比", subtitle: "共 \(stats.ticketCount) 注 · \(MoneyText.format(stats.cost))")
            if stats.byGame.isEmpty {
                emptyHint
            } else {
                // 环形图只能看出扇区大小，读者还得对着图例猜金额。
                // 中间补上总额，下面的明细直接写金额和百分比 ——
                // 明细占满整行才放得下「彩种 + 注数 + 占比 + 金额」四段。
                Chart(stats.byGame) { item in
                    SectorMark(angle: .value("花费", item.cost),
                               innerRadius: .ratio(0.68),
                               angularInset: 1.5)
                        .foregroundStyle(by: .value("彩种", item.game.label))
                        .cornerRadius(4)
                }
                // domain 和 range 必须等长且非空，否则 Swift Charts 会直接崩。
                // 上面的 isEmpty 分支保证了非空，这里保证等长。
                .chartForegroundStyleScale(domain: stats.byGame.map(\.game.label),
                                           range: stats.byGame.map(\.game.tint))
                .chartLegend(.hidden)
                .frame(height: 156)
                .overlay {
                    VStack(spacing: 1) {
                        Text("总花费")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(MoneyText.compactYuan(stats.cost))
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 8)
                }

                SpendBreakdown(items: stats.byGame, total: stats.cost, limit: 8)
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

    /// 「有记录的日子」。
    ///
    /// 原来是一行一天的清单，一个月三十行、一整年三百多行，密密麻麻还看不出重点。
    /// 现在默认只给一条概览 + 最值得看的几天（赚最多和亏最多），
    /// 想看全部再展开成清单。
    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "有记录的日子",
                subtitle: "\(stats.byDay.count) 天" + (month == nil ? " · \(year) 全年" : " · \(month ?? 0) 月"),
                action: stats.byDay.isEmpty ? nil : { isShowingAllDays.toggle() },
                actionLabel: isShowingAllDays ? "收起" : "全部"
            )

            if stats.byDay.isEmpty {
                emptyHint
            } else if isShowingAllDays {
                dayList(stats.byDay)
            } else {
                dayDigest
            }
        }
        .contentCard()
    }

    /// 概览：赚钱 / 亏钱 / 打平各多少天，再点出最好和最差的一天。
    @ViewBuilder
    private var dayDigest: some View {
        let winning = stats.byDay.filter { $0.net > 0 }
        let losing = stats.byDay.filter { $0.net < 0 }
        let best = winning.max { $0.net < $1.net }
        let worst = losing.min { $0.net < $1.net }

        VStack(spacing: 12) {
            HStack(spacing: 10) {
                dayTally("赚钱", winning.count, Palette.profit)
                dayTally("亏钱", losing.count, Palette.loss)
                dayTally("打平", stats.byDay.count - winning.count - losing.count, .secondary)
            }

            if best != nil || worst != nil {
                VStack(spacing: 8) {
                    if let best { highlight("最好的一天", best) }
                    if let worst { highlight("最差的一天", worst) }
                }
            }

            // 一条赚 / 亏 / 平的比例条。原来是一整排按天排开的小柱子，
            // 密密麻麻又没有刻度，读者读不出任何具体信息，只剩视觉噪音。
            DayProportionBar(win: winning.count, lose: losing.count,
                             flat: stats.byDay.count - winning.count - losing.count)
        }
    }

    private func dayTally(_ title: String, _ count: Int, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func highlight(_ title: String, _ day: ProfitDay) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(DateText.monthDay(day.date))
                .font(.caption.weight(.medium))
                .monospacedDigit()
            Text("\(day.count) 注")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(MoneyText.format(day.net))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Palette.profitColor(day.net))
        }
    }

    private func dayList(_ days: [ProfitDay]) -> some View {
        VStack(spacing: 0) {
            ForEach(days) { day in
                HStack(spacing: 8) {
                    Text(DateText.monthDay(day.date))
                        .font(.subheadline)
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Text("\(day.count) 注")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(MoneyText.format(day.net))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Palette.profitColor(day.net))
                        .frame(width: 96, alignment: .trailing)
                }
                .padding(.vertical, 9)
                if day.id != days.last?.id { Divider() }
            }
        }
    }

    private var emptyHint: some View {
        Text("这个区间还没有记录")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
    }
}

/// 赚 / 亏 / 平三段比例条。只回答一个问题：这段时间里赚钱的日子占多少。
struct DayProportionBar: View {
    let win: Int
    let lose: Int
    let flat: Int

    private var total: Int { Swift.max(win + lose + flat, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    segment(win, Palette.profit, proxy.size.width)
                    segment(lose, Palette.loss, proxy.size.width)
                    segment(flat, Color.secondary.opacity(0.35), proxy.size.width)
                }
            }
            .frame(height: 8)

            Text("赚钱的日子占 \(Int((Double(win) / Double(total) * 100).rounded()))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("赚钱 \(win) 天，亏钱 \(lose) 天，打平 \(flat) 天")
    }

    @ViewBuilder
    private func segment(_ count: Int, _ tint: Color, _ width: CGFloat) -> some View {
        if count > 0 {
            Capsule()
                .fill(tint)
                .frame(width: Swift.max(width * CGFloat(count) / CGFloat(total) - 2, 3))
        }
    }
}


/// 年月选择面板。年份左右翻，月份一个 3×4 的网格，外加一个「全年」。
struct PeriodPicker: View {
    @Binding var year: Int
    @Binding var month: Int?
    let years: [Int]

    @Environment(\.dismiss) private var dismiss

    private var minYear: Int { years.min() ?? year }
    private var maxYear: Int { years.max() ?? year }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                HStack {
                    stepButton("chevron.left", enabled: year > minYear) { year -= 1 }
                    Spacer()
                    Text("\(year) 年")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    stepButton("chevron.right", enabled: year < maxYear) { year += 1 }
                }
                .padding(.horizontal, 4)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(1...12, id: \.self) { item in
                        monthCell("\(item) 月", isOn: month == item) { month = item }
                    }
                }

                monthCell("全年", isOn: month == nil, wide: true) { month = nil }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Palette.canvas)
            .navigationTitle("选择统计区间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(360)])
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 40, height: 40)
                .background(Palette.card, in: Circle())
        }
        .buttonStyle(PressableIcon())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func monthCell(_ title: String, isOn: Bool, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isOn ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isOn ? Palette.onAccent : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: wide ? 44 : 40)
                .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.card),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
