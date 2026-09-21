import SwiftUI

/// 开奖数据详情。
///
/// 设置页那一行只给一个**更新时间** —— 那是日常唯一要看的东西，
/// 「数据是不是新的」一眼就能判断。剩下的（从哪儿取到的、后端什么时候抓到的、
/// 日历取到哪一年了）都是出问题时才关心的，进来看。
///
/// **「数据来源」这一行是这次迁移唯一能在真机上自证的地方。** CloudBase 和
/// GitHub 兜底取回来的数据一模一样，界面上分不出来；没有这一行，用户装上
/// 之后也说不清主数据源到底通没通。
///
/// ## 两个时间为什么都要
///
/// 「更新时间」是这份数据文件拼出来的时刻，「数据源更新时间」是后端把号码球
/// 和金额真正落库的时刻。**前者每次导出都会变，哪怕一个号码都没抓到。**
/// 开奖号迟迟不更新时，能分清是谁没动的只有后者：两个时间都新 = 正常；
/// 上面新、下面旧 = 后端没抓到，重试没用。
struct DrawDataView: View {
    @Environment(DrawStore.self) private var drawStore

    var body: some View {
        Form {
            Section {
                LabeledContent("更新时间") {
                    Text(drawStore.latestUpdatedAt.isEmpty
                         ? "暂无" : DateText.friendly(drawStore.latestUpdatedAt))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("数据源更新时间") {
                    Text(drawStore.sourceFetchedAt.isEmpty
                         ? "暂无" : DateText.friendly(drawStore.sourceFetchedAt))
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
                Text(footerText)
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
        }
        .navigationTitle("开奖数据")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 片段

    private var sourceTint: Color {
        switch drawStore.lastSource {
        case .cloudBase, .none: .secondary
        // 这两种都能正常用，但都说明主数据源当时没取到，值得看得见。
        case .githubFallback, .localCache: Palette.warning
        }
    }

    private var footerText: String {
        let source = switch drawStore.lastSource {
        case .cloudBase:
            "取自主数据源。"
        case .githubFallback:
            "主数据源当时没取到，这一份来自备用的公开镜像。数据一样，只是可能慢一步。"
        case .localCache:
            "网络没取到，显示的是本机上次存下来的那一份。"
        case .none:
            "优先从主数据源取；取不到就用备用的公开镜像；都取不到就用本机缓存。应用只读取，不上传任何内容。"
        }
        return source + "「数据源更新时间」是后端把号码和金额抓全之后落库的时刻；上面那个「更新时间」只是这份数据文件送出来的时刻。开奖号迟迟不更新时，看下面那个。"
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
}
