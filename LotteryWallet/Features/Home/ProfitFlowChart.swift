import SwiftUI
import Charts

/// 首页图表的两种看法。
enum FlowMode: String, CaseIterable, Identifiable {
    case cumulative
    case monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cumulative: "累计"
        case .monthly: "每月"
        }
    }
}

/// 图上面那一行读数。平时是整个范围的总数；按住图表拖动时是手指所在那一天
/// （或那个月）的数。
struct FlowReading: Equatable {
    var caption: String
    var cost: Double
    var prize: Double
    var welfare: Double
    /// 第四格：累计模式下是净支出（投入 − 奖金），每月模式下是「其余」。
    var lastTitle: String
    var lastValue: Double
    var lastIsGain: Bool = false

    /// - Parameters:
    ///   - day: 累计模式下手指所在的日期。取**不晚于它的最后一个点** ——
    ///     两次购买之间的任何一天，数都等于前一次购买之后的累计（圆点也落在那个点上）。
    ///   - month: 每月模式下选中的那个月（yyyy-MM）。
    static func make(series: ProfitSeries, mode: FlowMode, day: Date?, month: String?) -> FlowReading {
        switch mode {
        case .cumulative:
            if let day, let point = series.flow.last(where: { $0.day <= day }) ?? series.flow.first {
                return cumulative("截至 \(DateText.monthDay(DateText.day(point.day)))",
                                  cost: point.cost, prize: point.prize, welfare: point.welfare)
            }
            // 没按住的时候就写「截至最后一天」，不再放一句操作提示
            let caption = series.flow.last.map { "截至 \(DateText.monthDay(DateText.day($0.day)))" } ?? "还没有已开奖的记录"
            return cumulative(series.isEmpty ? "还没有已开奖的记录" : caption,
                              cost: series.costTotal, prize: series.prizeTotal, welfare: series.welfareTotal)
        case .monthly:
            if let month, let item = series.months.first(where: { $0.month == month }) {
                return FlowReading(caption: monthTitle(month), cost: item.cost, prize: item.prize,
                                   welfare: item.welfare, lastTitle: "其余", lastValue: item.rest)
            }
            let rest = max(series.costTotal - series.prizeTotal - series.welfareTotal, 0)
            return FlowReading(caption: series.isEmpty ? "还没有已开奖的记录" : "点一根柱子，看那个月",
                               cost: series.costTotal, prize: series.prizeTotal,
                               welfare: series.welfareTotal, lastTitle: "其余", lastValue: rest)
        }
    }

    private static func cumulative(_ caption: String, cost: Double, prize: Double, welfare: Double) -> FlowReading {
        // 奖金超过投入就不是「净支出」了，换个说法，别显示一个负的支出。
        let net = cost - prize
        return FlowReading(caption: caption, cost: cost, prize: prize, welfare: welfare,
                           lastTitle: net < 0 ? "净收入" : "净支出", lastValue: abs(net), lastIsGain: net < 0)
    }

    /// `2026-09` → `2026 年 9 月`。
    static func monthTitle(_ month: String) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let number = Int(parts[1]) else { return month }
        return "\(parts[0]) 年 \(number) 月"
    }

    /// 柱子底下的标签：`9月`。
    static func monthLabel(_ month: String) -> String {
        guard let number = Int(month.suffix(2)) else { return month }
        return "\(number)月"
    }
}

/// 首页的收支图。
///
/// **累计**：三条从零画起的平滑线 —— 投入（主题蓝）、公益金（橙）、奖金（红），
/// 线下面是由深到透明的渐变。每条线的高度就是它自己的数；蓝线和红线之间的距离
/// 就是净支出。
///
/// 第一版画的是阶梯线（钱是一笔一笔花的），真机上一看全是锯齿，改成平滑的。
/// 用的是**保单调**的插值：线一定经过每一个数据点，两点之间只升不降、不会鼓出去 ——
/// 累计值不会凭空多出一截，也不会掉下去再回来。读数和圆点仍然落在真实的数据点上。
///
/// **每月**：一个月一根柱子，自下而上是奖金、公益金、其余，总高等于当月投入。
///
/// 按住拖动（每月模式下是点一下）时，上面那行读数跟着变。
struct ProfitFlowChart: View {
    let series: ProfitSeries
    let mode: FlowMode

    @State private var selectedDay: Date?
    @State private var selectedMonth: String?

    private static let spend = Color.accentColor

    private var reading: FlowReading {
        FlowReading.make(series: series, mode: mode, day: selectedDay, month: selectedMonth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readout
            Group {
                switch mode {
                case .cumulative: cumulativeChart
                case .monthly: monthlyChart
                }
            }
            .frame(height: 170)
        }
        // 换范围、换模式之后，原来选中的那一天多半已经不在图上了。
        .onChange(of: mode) { _, _ in clearSelection() }
        .onChange(of: series.flow.count) { _, _ in clearSelection() }
    }

    private func clearSelection() {
        selectedDay = nil
        selectedMonth = nil
    }

    // MARK: - 读数

    private var readout: some View {
        let reading = reading
        return VStack(alignment: .leading, spacing: 6) {
            Text(reading.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                cell("投入", reading.cost, mode == .cumulative ? Self.spend : Color.primary)
                cell("奖金", reading.prize, Palette.profit)
                cell("公益金", reading.welfare, Palette.warning)
                cell(reading.lastTitle, reading.lastValue,
                     mode == .monthly ? Palette.missInk : (reading.lastIsGain ? Palette.profit : Palette.loss))
            }
        }
    }

    private func cell(_ title: String, _ value: Double, _ tint: Color) -> some View {
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
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(MoneyText.format(value))")
    }

    // MARK: - 累计

    private var selectedPoint: FlowPoint? {
        guard let selectedDay else { return nil }
        return series.flow.last { $0.day <= selectedDay } ?? series.flow.first
    }

    /// 投入和奖金之间那一块的颜色：亏的时候是支出色，赚的时候是奖金色。
    /// 第一版只涂了一成的主题蓝，叠在投入线自己的渐变上根本看不出来。
    private var netBand: Color {
        (series.prizeTotal > series.costTotal ? Palette.profit : Palette.loss).opacity(0.22)
    }

    private var cumulativeChart: some View {
        Chart {
            line("投入", Self.spend, fill: 0.26, value: \.cost)
            // 投入和奖金两条线之间的那一块就是净支出，再淡淡地涂一层
            ForEach(series.flow) { point in
                AreaMark(x: .value("日期", point.day),
                         yStart: .value("奖金", point.prize),
                         yEnd: .value("投入", point.cost),
                         series: .value("类别", "净支出"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(netBand)
            }
            line("公益金", Palette.warning, fill: 0.34, value: \.welfare)
            line("奖金", Palette.profit, fill: 0.38, value: \.prize)
            if let point = selectedPoint {
                RuleMark(x: .value("日期", point.day))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                marker(point, point.cost, Self.spend)
                marker(point, point.welfare, Palette.warning)
                marker(point, point.prize, Palette.profit)
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .foregroundStyle(Palette.separator)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
            }
        }
        // 纵轴顶到最高那条线就够了。交给系统自动取整的话会往上凑一个整数，
        // 图的上面三分之一是空的。
        .chartYScale(domain: 0...(max(series.costTotal, series.prizeTotal, 1) * 1.04))
        // 系统自带的选中手势：按住再拖，和页面的上下滚动不打架。
        .chartXSelection(value: $selectedDay)
        .accessibilityLabel("累计收支图")
        .accessibilityValue("投入 \(MoneyText.format(series.costTotal))，奖金 \(MoneyText.format(series.prizeTotal))，公益金 \(MoneyText.format(series.welfareTotal))")
    }

    @ChartContentBuilder
    private func line(_ name: String, _ color: Color, fill: Double,
                      value: KeyPath<FlowPoint, Double>) -> some ChartContent {
        ForEach(series.flow) { point in
            // 三块面积都从零起，不叠加 —— 叠起来的话公益金那条线的高度就不是公益金了。
            AreaMark(x: .value("日期", point.day),
                     y: .value(name, point[keyPath: value]),
                     series: .value("类别", name),
                     stacking: .unstacked)
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [color.opacity(fill), color.opacity(0)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("日期", point.day),
                     y: .value(name, point[keyPath: value]),
                     series: .value("类别", name))
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    @ChartContentBuilder
    private func marker(_ point: FlowPoint, _ value: Double, _ color: Color) -> some ChartContent {
        PointMark(x: .value("日期", point.day), y: .value("金额", value))
            .symbolSize(90)
            .foregroundStyle(Palette.card)
        PointMark(x: .value("日期", point.day), y: .value("金额", value))
            .symbolSize(42)
            .foregroundStyle(color)
    }

    // MARK: - 每月

    private var monthlyChart: some View {
        Chart {
            ForEach(series.months) { month in
                bar(month, "奖金", month.prizeShown, Palette.profit)
                bar(month, "公益金", month.welfareShown, Palette.warning)
                bar(month, "其余", month.rest, Palette.missDeep)
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .foregroundStyle(Palette.separator)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let month = value.as(String.self) { Text(FlowReading.monthLabel(month)) }
                }
            }
        }
        .chartXSelection(value: $selectedMonth)
        .accessibilityLabel("每月收支图")
    }

    @ChartContentBuilder
    private func bar(_ month: FlowMonth, _ name: String, _ value: Double, _ color: Color) -> some ChartContent {
        // x 用完整的 yyyy-MM 当身份（跨年时「9月」会重名），显示成「9月」。
        BarMark(x: .value("月份", month.month), y: .value(name, value), width: .ratio(0.56))
            .foregroundStyle(color)
            .cornerRadius(4)
            .opacity(selectedMonth == nil || selectedMonth == month.month ? 1 : 0.35)
    }
}
