import SwiftUI

/// 期次选择器：从整年开奖日历里挑一期绑定。
///
/// 录入页和扫描复核页共用。日历文件是数据仓库预生成的静态文件，
/// 每一期的期号、开奖日、停售时刻都在里面，所以这里不做任何推算 ——
/// 只是把它按月分组列出来。
struct IssuePickerSheet: View {
    let game: GameKey
    /// 当前绑定的期号，用来高亮和定位。
    let current: String
    var onPick: (CalendarIssue) -> Void

    @Environment(DrawStore.self) private var drawStore
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""

    private var allIssues: [CalendarIssue] {
        drawStore.yearCalendars.keys.sorted()
            .flatMap { drawStore.calendarIssues(for: game, year: $0) }
    }

    private var filtered: [CalendarIssue] {
        let text = keyword.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return allIssues }
        return allIssues.filter { $0.issue.contains(text) || $0.drawDate.contains(text) }
    }

    /// 按 "2026-03" 分组，月份倒不倒序都不重要 —— 用户是顺着往下找的。
    private var months: [(key: String, issues: [CalendarIssue])] {
        var order: [String] = []
        var buckets: [String: [CalendarIssue]] = [:]
        for issue in filtered {
            let month = String(issue.drawDate.prefix(7))
            if buckets[month] == nil { order.append(month) }
            buckets[month, default: []].append(issue)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// 现在还能买的第一期。列表默认滚到这里。
    private var onSaleIssue: String? {
        let now = Date()
        return allIssues.first { $0.isOnSale(at: now) }?.issue
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
                    list
                }
            }
            .navigationTitle("选择期次")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, prompt: "期号或日期")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(months, id: \.key) { month, issues in
                    Section(monthTitle(month)) {
                        ForEach(issues) { issue in
                            row(issue)
                                .id(issue.issue)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .onAppear {
                guard keyword.isEmpty else { return }
                let anchor = current.isEmpty ? onSaleIssue : current
                if let anchor { proxy.scrollTo(anchor, anchor: .center) }
            }
        }
    }

    private func row(_ issue: CalendarIssue) -> some View {
        let isCurrent = issue.issue == current
        let closed = !issue.isOnSale(at: Date())
        return Button {
            onPick(issue)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("第 \(issue.issue) 期")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("\(DateText.monthDay(issue.drawDate)) \(Self.weekdayName(issue.weekday)) · \(String(issue.drawTime.suffix(8).prefix(5))) 开奖")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                // 已截止的期次不禁用 —— 补录旧票、修正扫描识别错误都要选到它们，
                // 只是标一下"已截止"，别让用户以为选错了。
                if closed {
                    Text("已截止")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(game.accent.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func monthTitle(_ month: String) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let m = Int(parts[1]) else { return month }
        return "\(parts[0]) 年 \(m) 月"
    }

    private static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func weekdayName(_ weekday: Int) -> String {
        weekdayNames.indices.contains(weekday) ? weekdayNames[weekday] : ""
    }
}
