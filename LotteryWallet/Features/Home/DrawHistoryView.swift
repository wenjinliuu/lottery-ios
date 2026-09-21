import SwiftUI

/// 往期开奖：按彩种、按需、逐年往前翻。
///
/// **进来只取当前这一个彩种的最近 30 期**（`/v2/draws/{type}`）。左右滑到
/// 哪个彩种才取哪个 —— 八个彩种一次拉满是上一版冷启动最贵的那一步，
/// 而绝大多数人只看自己买的那一两种。
///
/// 滑到底部有一颗按钮，一次只往前推**一年**：先今年（`/v2/by-year/{type}/{今年}`），
/// 再上一年，再上上年。同一彩种同一年不会请求第二次。
struct DrawHistoryView: View {
    @Environment(DrawStore.self) private var drawStore
    @Environment(\.dismiss) private var dismiss

    @State private var game: GameKey

    /// 从哪个彩种打开。首页「更多」传的是**用户正盯着的那张轮播卡**，
    /// 不再固定从双色球开始。
    ///
    /// 用 `State(initialValue:)` 而不是 `.onAppear { game = initialGame }`：
    /// 后者会先按双色球渲染一帧再跳，用户看得见那一下闪，
    /// 而且会白白触发一次双色球的 `/v2/draws/ssq`。
    init(initialGame: GameKey = .ssq) {
        _game = State(initialValue: initialGame)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                gameTabs
                    .padding(.horizontal, 16)
                // 彩种之间用分页 TabView 而不是只换内容：这样左右滑动就能切彩种，
                // 不必每次都回到顶上的芯片条去点。竖向滚动仍然归各页自己。
                TabView(selection: $game) {
                    ForEach(GameKey.ordered) { item in
                        page(for: item).tag(item)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .padding(.top, 8)
            .background(Palette.canvas)
            .navigationTitle("往期开奖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func page(for item: GameKey) -> some View {
        let rows = drawStore.draws(for: item)
        // 「还没轮到它」和「取过但是空的」是两回事。滑到还没加载的那一页
        // 要看到转圈，而不是「网络没连上」。
        let state = drawStore.recentStates[item] ?? .idle
        ScrollView {
            LazyVStack(spacing: 12) {
                if !rows.isEmpty {
                    ForEach(rows) { draw in
                        DrawHistoryRow(game: item, draw: draw)
                    }
                    historyFooter(for: item, count: rows.count)
                } else if !state.hasTried || state.isLoading {
                    ProgressView("正在读取往期开奖")
                        .padding(.top, 60)
                } else {
                    // 拉取失败或该彩种确实没有数据时，原来会一直转圈，
                    // 用户既不知道出了什么事，也没有重试的入口。
                    ContentUnavailableView {
                        Label("暂时没有往期数据", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(state.failureText ?? "可能是网络没连上，或者数据源还没有这个彩种的往期记录。")
                    } actions: {
                        Button("重试") { Task { await drawStore.reloadRecent(for: item) } }
                            .buttonStyle(SecondaryGlassButton(tint: item.tint))
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        // 每一页管自己那份数据，滑过去才开始拉
        .task(id: item) { await drawStore.loadRecent(for: item) }
    }

    /// 列表底部：一次往前推一年。
    ///
    /// 按钮上直接写年份，用户知道自己下一步会拿到什么 ——
    /// 一颗含糊的「加载更多」既看不出还有没有、也看不出要等多久。
    @ViewBuilder
    private func historyFooter(for item: GameKey, count: Int) -> some View {
        let loadedYears = drawStore.loadedYears(for: item)
        let nextYear = drawStore.nextYearToLoad(for: item)
        VStack(spacing: 6) {
            if let nextYear {
                let state = drawStore.yearState(for: item, year: nextYear)
                Button {
                    Task { await drawStore.loadOlderHistory(for: item) }
                } label: {
                    if state.isLoading {
                        ProgressView()
                    } else {
                        Text(loadedYears.isEmpty ? "查看 \(nextYear) 年全部" : "加载 \(nextYear) 年")
                    }
                }
                .buttonStyle(SecondaryGlassButton(tint: item.tint))
                .disabled(state.isLoading)

                Text(state.failureText ?? subtitle(count: count, loadedYears: loadedYears))
                    .font(.caption2)
                    // 三元的两支必须同类型：Palette.warning 是 Color，
                    // 而 .tertiary 是 HierarchicalShapeStyle，直接混写编译不过。
                    .foregroundStyle(state.hasFailed
                                     ? AnyShapeStyle(Palette.warning)
                                     : AnyShapeStyle(.tertiary))
            } else {
                Text("已显示 \(count) 期 · 没有更早的了")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    private func subtitle(count: Int, loadedYears: [Int]) -> String {
        guard let earliest = loadedYears.min() else { return "当前显示最近 \(count) 期" }
        return "已显示 \(count) 期 · 最早到 \(earliest) 年"
    }

    /// 彩种切换条：**两行，八个彩种一屏全在**。
    ///
    /// 原来是一行横向滚动。八个名字一行放不下，屏幕右边总是截着半个芯片，
    /// 想选后面几个得先横滑一下 —— 而这一页的主交互本来就是左右滑切彩种，
    /// 于是同一个方向上有两套滑动：滑上面那条是滚动列表，滑下面是翻页。
    /// 手指落点差几十点，行为完全不同。
    ///
    /// 改成固定两行四列之后没有滚动了：八个都看得见，点哪个是哪个，
    /// 左右滑动这个手势只剩下面那一种含义。
    ///
    /// 这里刻意**不用玻璃**：本项目的分层原则是玻璃只属于悬浮在内容之上的导航层，
    /// 这排芯片跟着内容一起滚，早期版本给它套 glassPill，选中态的渐变被玻璃糊掉，
    /// 白字压上去也读不清。改成和票夹筛选条一致的实心芯片。
    private var gameTabs: some View {
        // 固定四列而不是 `.adaptive`：八个彩种要的是稳定的 2×4，
        // 自适应会随字号和机型变成 3+3+2 之类，每次进来排布都不一样。
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                  spacing: 8) {
            ForEach(GameKey.ordered) { item in
                let isOn = game == item
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { game = item }
                } label: {
                    Text(item.label)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(isOn ? item.onTint : Color.primary)
                        .lineLimit(1)
                        // 「快乐8」和「福彩3D」不等长，等宽格子里必须允许收缩，
                        // 否则窄机型上长名字会被截成省略号。
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(isOn ? AnyShapeStyle(item.tint) : AnyShapeStyle(Palette.card),
                                    in: Capsule())
                        .overlay(Capsule().strokeBorder(isOn ? item.accent.solidStroke : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityHint("也可以在下方左右滑动切换彩种")
    }
}

struct DrawHistoryRow: View {
    let game: GameKey
    let draw: Draw

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("第 \(draw.expect) 期")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(DateText.monthDay(draw.openDate))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // 往期这里要看全号码，所以不限制颗数，只让球径自适应缩小
            DrawNumbersView(draw: draw, size: 28)
            // 奖级和首页那张卡用同一套 —— 原来这里只有干巴巴一行
            // 「一等奖 N 注」，同一份数据在两个页面上长得不一样，
            // 翻到往期会以为信息丢了。
            DrawPrizeLines(game: game, draw: draw)
        }
        // contentCard 自己就带 16pt 内边距，外面再加一层等于 32pt，
        // 卡片里的内容会比首页窄一大截。
        .contentCard(cornerRadius: 20)
    }
}
