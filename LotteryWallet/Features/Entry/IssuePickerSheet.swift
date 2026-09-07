import SwiftUI

/// 期次选择器：一个月一屏的日历。
///
/// 原来是一条长列表。问题不在于信息不够，而在于**人脑子里的期次是按日期排的**：
/// 「我那张票是上个月月底买的」「下一期是这周六」—— 这些都是日期问题，
/// 在一条几百行的列表里翻找日期是最笨的办法。
///
/// 换成月历之后，开奖日在格子里一眼可见（哪几天开、隔几天开一次），
/// 点中某一天再在下面看那一期的完整信息：期号、开奖时刻、停售时刻、
/// 还能不能买。列表能给的信息一样不少，只是换了个人找得到的排法。
struct IssuePickerSheet: View {
    let game: GameKey
    /// 当前绑定的期号，用来高亮和定位。
    let current: String
    var onPick: (CalendarIssue) -> Void

    @Environment(DrawStore.self) private var drawStore
    @Environment(\.dismiss) private var dismiss

    /// 正在看哪个月，用当月 1 号表示。
    @State private var month = Date()
    @State private var selected: CalendarIssue?

    private static let weekdayHeaders = ["日", "一", "二", "三", "四", "五", "六"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var allIssues: [CalendarIssue] {
        drawStore.yearCalendars.keys.sorted()
            .flatMap { drawStore.calendarIssues(for: game, year: $0) }
    }

    /// 按开奖日索引，格子里查得快。
    private var byDate: [String: CalendarIssue] {
        Dictionary(allIssues.map { ($0.drawDate, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 现在还能买的第一期。
    private var onSaleIssue: CalendarIssue? {
        let now = Date()
        return allIssues.first { $0.isOnSale(at: now) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allIssues.isEmpty {
                    ContentUnavailableView {
                        Label("还没拿到开奖日历", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text("整年期次表来自开奖数据仓库，联网后会自动缓存到本机。")
                    } actions: {
                        Button("重新获取") { Task { await drawStore.loadYearCalendars() } }
                            .buttonStyle(SecondaryGlassButton(tint: game.tint))
                    }
                } else {
                    calendar
                }
            }
            .background(Palette.canvas)
            .navigationTitle("选择期次")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选这一期") {
                        if let selected { onPick(selected) }
                        dismiss()
                    }
                    .disabled(selected == nil)
                    .fontWeight(.semibold)
                }
            }
            .onAppear(perform: jumpToInitialMonth)
        }
    }

    // MARK: - 日历

    private var calendar: some View {
        VStack(spacing: 0) {
            monthBar
            weekdayBar
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .animation(.easeOut(duration: 0.18), value: monthKey)

                detailCard
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
            }
            // 左右滑动翻月，和系统日历一致
            .gesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        if value.translation.width < 0 { shift(by: 1) }
                        else if value.translation.width > 0 { shift(by: -1) }
                    }
            )
        }
    }

    private var monthBar: some View {
        HStack(spacing: 4) {
            Button { shift(by: -1) } label: {
                Image(systemName: "chevron.left").font(.subheadline.weight(.bold))
            }
            .buttonStyle(PressableIcon())
            .frame(width: 44, height: 44)
            .disabled(!canShift(by: -1))

            Text(monthTitle)
                .font(.headline)
                .monospacedDigit()
                .frame(maxWidth: .infinity)

            Button { shift(by: 1) } label: {
                Image(systemName: "chevron.right").font(.subheadline.weight(.bold))
            }
            .buttonStyle(PressableIcon())
            .frame(width: 44, height: 44)
            .disabled(!canShift(by: 1))
        }
        .foregroundStyle(game.accent.accentColor)
        .padding(.horizontal, 12)
    }

    private var weekdayBar: some View {
        HStack(spacing: 4) {
            ForEach(Self.weekdayHeaders, id: \.self) { text in
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// 一格：没有开奖的日子是灰的，有开奖的显示期号后三位。
    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let key = DateText.day(day)
            let issue = byDate[key]
            let isSelected = issue != nil && issue?.issue == selected?.issue
            let isBound = issue != nil && issue?.issue == current
            let closed = issue.map { !$0.isOnSale(at: Date()) } ?? false

            Button {
                guard let issue else { return }
                selected = issue
            } label: {
                VStack(spacing: 1) {
                    Text(dayNumber(day))
                        .font(.system(size: 15, weight: issue != nil ? .semibold : .regular))
                        .monospacedDigit()
                    // 期号只显示后三位：同一年里前面几位都一样，
                    // 全写出来这一格根本放不下，也没有区分度。
                    Text(issue.map { String($0.issue.suffix(3)) } ?? " ")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .opacity(0.75)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(cellForeground(issue: issue, isSelected: isSelected, closed: closed))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(game.tint)
                    } else if issue != nil {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(game.tint.opacity(closed ? 0.08 : 0.16))
                    }
                }
                .overlay {
                    // 当前已绑定的那一期描个边，翻月回来一眼找得到
                    if isBound && !isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(game.accent.accentColor, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(issue == nil)
            .accessibilityLabel(issue.map { "\(dayNumber(day)) 日，第 \($0.issue) 期" } ?? "\(dayNumber(day)) 日，不开奖")
        } else {
            Color.clear.frame(height: 44)
        }
    }

    private func cellForeground(issue: CalendarIssue?, isSelected: Bool, closed: Bool) -> Color {
        if isSelected { return game.onTint }
        if issue == nil { return .secondary.opacity(0.45) }
        return closed ? .secondary : .primary
    }

    /// 选中那一期的完整信息。列表里有的这里一样不少。
    @ViewBuilder
    private var detailCard: some View {
        if let issue = selected {
            let closed = !issue.isOnSale(at: Date())
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("第 \(issue.issue) 期")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(game.accent.accentColor)
                    Spacer(minLength: 8)
                    // 已截止的期次照样能选 —— 补录旧票、修正扫描识别错误都要选到它们
                    Text(closed ? "已截止" : "可购买")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(closed ? Color.secondary : Palette.live)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((closed ? Color.secondary : Palette.live).opacity(0.14), in: Capsule())
                }
                detailRow("开奖", "\(DateText.monthDay(issue.drawDate)) \(weekdayName(issue.weekday)) \(clock(issue.drawTime))")
                detailRow("停售", "\(DateText.monthDay(issue.drawDate)) \(clock(issue.saleCloseTime))")
                if issue.issue == current {
                    Text("这张票当前就绑在这一期")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentCard()
        } else {
            Text("点一个有期号的日子")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
    }

    // MARK: - 月份计算

    private var chinaCalendar: Calendar { Calendar.chinaCalendar }

    private var monthKey: String {
        let parts = chinaCalendar.dateComponents([.year, .month], from: month)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)"
    }

    private var monthTitle: String {
        let parts = chinaCalendar.dateComponents([.year, .month], from: month)
        return "\(parts.year ?? 0) 年 \(parts.month ?? 0) 月"
    }

    /// 这个月的格子：前面补空到周日起头，然后是这个月的每一天。
    private var gridDays: [Date?] {
        guard let interval = chinaCalendar.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        // weekday 是 1...7（周日为 1），格子从周日起头，所以前面补 weekday-1 个空
        let leading = chinaCalendar.component(.weekday, from: first) - 1
        let count = chinaCalendar.range(of: .day, in: .month, for: first)?.count ?? 30
        var days: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<count {
            days.append(chinaCalendar.date(byAdding: .day, value: offset, to: first))
        }
        return days
    }

    private func dayNumber(_ date: Date) -> String {
        String(chinaCalendar.component(.day, from: date))
    }

    /// 日历覆盖的月份范围，翻到头就把箭头灰掉。
    private var bounds: (first: Date, last: Date)? {
        guard let first = allIssues.first.flatMap({ DateText.parse($0.drawDate) }),
              let last = allIssues.last.flatMap({ DateText.parse($0.drawDate) }) else { return nil }
        return (first, last)
    }

    private func canShift(by months: Int) -> Bool {
        guard let bounds, let target = chinaCalendar.date(byAdding: .month, value: months, to: month) else { return false }
        let low = chinaCalendar.dateInterval(of: .month, for: bounds.first)?.start ?? bounds.first
        let high = chinaCalendar.dateInterval(of: .month, for: bounds.last)?.end ?? bounds.last
        return target >= low && target < high
    }

    private func shift(by months: Int) {
        guard canShift(by: months),
              let target = chinaCalendar.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(.easeOut(duration: 0.2)) { month = target }
    }

    /// 打开时先跳到已绑定的那一期，没有就跳到现在能买的那一期。
    private func jumpToInitialMonth() {
        let anchor = allIssues.first { $0.issue == current } ?? onSaleIssue
        guard let anchor, let date = DateText.parse(anchor.drawDate) else { return }
        month = date
        selected = anchor
    }

    private func clock(_ raw: String) -> String {
        raw.count >= 16 ? String(raw.suffix(8).prefix(5)) : raw
    }

    private static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    private func weekdayName(_ weekday: Int) -> String {
        Self.weekdayNames.indices.contains(weekday) ? Self.weekdayNames[weekday] : ""
    }
}
