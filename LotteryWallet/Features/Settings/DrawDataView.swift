import SwiftUI

/// 数据状态详情。
///
/// 设置页那一行已经把最要紧的三件事说完了（什么时候跑的、成没成功、齐了几个）。
/// 进来是为了看清**两个方向**上各自发生了什么：
///
/// ```
/// 更新时间        ← 这台设备上一次去腾讯云取数的时刻
/// 数据来源        ← 取到的那一份是谁给的
/// 数据源状态      ← 后端八个彩种齐了几个
/// 数据源更新时间  ← 后端上一次抓取任务什么时候跑的、成没成功
/// ```
///
/// 上面两行是**本机这边**，下面两行是**后端那边**。开奖号迟迟不更新时，
/// 分清是谁没动全靠这个对照：上面新下面旧 = 后端没抓到，重试没用；
/// 上面旧 = 这台设备没取到，点一下刷新就行。
///
/// **「数据来源」这一行是 V2 迁移唯一能在真机上自证的地方。** CloudBase 和
/// GitHub 兜底取回来的数据一模一样，界面上分不出来。
struct DrawDataView: View {
    @Environment(DrawStore.self) private var drawStore

    var body: some View {
        Form {
            Section {
                LabeledContent("更新时间") {
                    Text(drawStore.lastFetchedAt.map(DateText.stamp) ?? "暂无")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("数据来源") {
                    Text(drawStore.lastSource?.label ?? "尚未取数")
                        .foregroundStyle(sourceTint)
                }
                LabeledContent("数据源状态") {
                    Text(progressText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("数据源更新时间") {
                    Text(executionText)
                        .foregroundStyle(executionTint)
                        .multilineTextAlignment(.trailing)
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
        .navigationTitle("数据状态")
        .navigationBarTitleDisplayMode(.inline)
        .task { await drawStore.loadStatus() }
    }

    // MARK: - 片段

    /// `6/8 数据完整`。读不到状态时不编一个分数出来。
    private var progressText: String {
        if let status = drawStore.fetchStatus { return status.progressText }
        return drawStore.statusState.isLoading ? "读取中…" : "暂无"
    }

    /// `09月22日 02:44 · 执行成功`
    private var executionText: String {
        if let status = drawStore.fetchStatus { return status.executionText }
        return drawStore.statusState.isLoading ? "读取中…" : "暂无执行记录"
    }

    /// 只有执行失败才标黄。数据没齐不标 —— 今天还没开奖的彩种
    /// 本来就该是 waiting，画成警告等于每天一次假警报。
    private var executionTint: Color {
        drawStore.fetchStatus?.needsAttention == true ? Palette.warning : .secondary
    }

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
        return source + "上面两行是这台设备取数的情况，下面两行是数据源那边抓取的情况。开奖号迟迟不更新时，看下面两行就知道是不是后端还没抓到 ——「数据完整」按八个彩种算，今天还没开奖的彩种不计入，所以白天看到 6/8 是正常的。"
    }

    private var calendarYears: [Int] {
        drawStore.yearCalendars.keys.sorted(by: >)
    }

    private func issueCount(_ year: Int) -> Int {
        GameKey.ordered.reduce(0) { $0 + drawStore.calendarIssues(for: $1, year: year).count }
    }
}
