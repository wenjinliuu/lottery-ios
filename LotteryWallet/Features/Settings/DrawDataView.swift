import SwiftUI

/// 开奖数据详情。
///
/// 设置页那一行只给一个**更新时间** —— 那是日常唯一要看的东西，
/// 「数据是不是新的」一眼就能判断。剩下的（从哪儿取到的、数据源那边正不正常、
/// 日历取到哪一年了）都是出问题时才关心的，进来看。
///
/// **「数据来源」这一行是这次迁移唯一能在真机上自证的地方。** CloudBase 和
/// GitHub 兜底取回来的数据一模一样，界面上分不出来；没有这一行，用户装上
/// 之后也说不清主数据源到底通没通。
struct DrawDataView: View {
    @Environment(DrawStore.self) private var drawStore

    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("更新时间") {
                    Text(drawStore.latestUpdatedAt.isEmpty
                         ? "暂无" : DateText.friendly(drawStore.latestUpdatedAt))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("数据来源") {
                    Text(drawStore.lastSource?.label ?? "尚未取数")
                        .foregroundStyle(sourceTint)
                }
                LabeledContent("已获取彩种") {
                    Text("\(gamesWithLatest)/\(GameKey.ordered.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("最新开奖")
            } footer: {
                Text(sourceFooter)
            }

            Section {
                LabeledContent("状态") {
                    healthValue
                }
                if let health = drawStore.health {
                    if !health.updatedAt.isEmpty {
                        LabeledContent("数据源更新于") {
                            Text(DateText.friendly(health.updatedAt)).foregroundStyle(.secondary)
                        }
                    }
                    if !health.message.isEmpty {
                        LabeledContent("说明") {
                            Text(health.message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            } header: {
                Text("数据源状态")
            } footer: {
                Text("这一项问的是**提供开奖数据的那一边**现在正不正常，不是这台设备。开奖号迟迟不更新时，用它分清是数据源还没抓到，还是应用这边没刷新。只有进入这一页时才会查询一次。")
            }

            Section {
                if calendarYears.isEmpty {
                    Text("尚未获取")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(calendarYears, id: \.self) { year in
                        LabeledContent("\(String(year)) 年") {
                            Text("\(issueCount(year)) 期")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("开奖日历")
            } footer: {
                Text("日历是按年、按需取的：录入或扫描彩票、需要选择期号时才会加载当年那一份，跨年前后才会多取下一年。它决定了每一期的期号、开奖日和停售时刻。")
            }

            Section {
                Button {
                    refresh()
                } label: {
                    HStack {
                        Text("刷新开奖数据")
                        Spacer()
                        if isRefreshing { ProgressView() }
                    }
                }
                .disabled(isRefreshing)
            } footer: {
                Text("重新获取各彩种的最新一期与开奖日程，并刷新你已经看过的那些彩种的往期。没打开过的彩种不会顺带下载。")
            }
        }
        .navigationTitle("开奖数据")
        .navigationBarTitleDisplayMode(.inline)
        .task { await drawStore.loadHealth() }
    }

    // MARK: - 片段

    @ViewBuilder
    private var healthValue: some View {
        switch drawStore.healthState {
        case .idle, .loading:
            ProgressView()
        case .loaded:
            Text(drawStore.health?.label ?? "未知")
                .foregroundStyle(drawStore.health?.isHealthy == false ? Palette.warning : Color.secondary)
        case .failed(let reason):
            // 查不到本身就是一条信息：多半是主数据源现在不通
            // （这一项不走 GitHub 兜底，问的就是它自己）。
            Text(reason)
                .font(.footnote)
                .foregroundStyle(Palette.warning)
                .multilineTextAlignment(.trailing)
        }
    }

    private var sourceTint: Color {
        switch drawStore.lastSource {
        case .cloudBase, .none: .secondary
        // 这两种都能正常用，但都说明主数据源当时没取到，值得看得见。
        case .githubFallback, .localCache: Palette.warning
        }
    }

    private var sourceFooter: String {
        switch drawStore.lastSource {
        case .cloudBase:
            "取自主数据源。"
        case .githubFallback:
            "主数据源当时没取到，这一份来自备用的公开镜像。数据一样，只是可能慢一步。"
        case .localCache:
            "网络没取到，显示的是本机上次存下来的那一份。"
        case .none:
            "优先从主数据源取；取不到就用备用的公开镜像；都取不到就用本机缓存。应用只读取，不上传任何内容。"
        }
    }

    private var gamesWithLatest: Int {
        GameKey.ordered.filter { drawStore.latestDraw(for: $0) != nil }.count
    }

    private var calendarYears: [Int] {
        drawStore.yearCalendars.keys.sorted(by: >)
    }

    private func issueCount(_ year: Int) -> Int {
        GameKey.ordered.reduce(0) { $0 + drawStore.calendarIssues(for: $1, year: year).count }
    }

    private func refresh() {
        Task {
            isRefreshing = true
            defer { isRefreshing = false }
            await drawStore.refresh()
            await drawStore.refreshLoadedRecents()
            await drawStore.loadHealth(force: true)
        }
    }
}
