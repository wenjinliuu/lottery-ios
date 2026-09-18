import SwiftUI

/// 往期开奖：按彩种查看往期。
///
/// **默认只读近 50 期**（仓库的 `draws/{game}.json`），用户滑到底点
/// 「查看今年全部」才去拉 `by-year/{game}/{year}.json`。整年是近 50 期的
/// 十倍体量，一进页面就全拉等于下载、解码、渲染都翻十倍，
/// 而绝大多数人根本翻不到第 50 期。
struct DrawHistoryView: View {
    @Environment(DrawStore.self) private var drawStore
    @Environment(\.dismiss) private var dismiss

    @State private var game: GameKey = .ssq

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
        let loadedYear = drawStore.hasLoadedYear(item)
        // 「还没拉过」和「拉过但是空的」是两回事。只按当前选中的彩种判断
        // 是否在加载，滑到还没加载的那一页会直接看到「网络没连上」的空状态 ——
        // 明明只是还没轮到它。
        let hasLoaded = drawStore.attemptedHistoryGames.contains(item)
        ScrollView {
            LazyVStack(spacing: 12) {
                if !rows.isEmpty {
                    ForEach(rows) { draw in
                        DrawHistoryRow(game: item, draw: draw)
                    }
                    moreFooter(for: item, loadedYear: loadedYear, count: rows.count)
                } else if !hasLoaded {
                    ProgressView("正在读取往期开奖")
                        .padding(.top, 60)
                } else {
                    // 拉取失败或该彩种确实没有数据时，原来会一直转圈，
                    // 用户既不知道出了什么事，也没有重试的入口。
                    ContentUnavailableView {
                        Label("暂时没有往期数据", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("可能是网络没连上，或者数据仓库还没有这个彩种的往期记录。")
                    } actions: {
                        Button("重试") { Task { await drawStore.reloadHistory(for: item) } }
                            .buttonStyle(SecondaryGlassButton(tint: item.tint))
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        // 每一页管自己那份数据，滑过去就开始拉
        .task(id: item) { await drawStore.loadHistory(for: item) }
    }

    /// 列表底部：还没拉整年就给一颗「查看今年全部」，拉过了就说明已经到底。
    @ViewBuilder
    private func moreFooter(for item: GameKey, loadedYear: Bool, count: Int) -> some View {
        if loadedYear {
            Text("已显示 \(count) 期 · 今年的都在这儿了")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        } else {
            VStack(spacing: 6) {
                Button {
                    Task { await drawStore.loadYearHistory(for: item) }
                } label: {
                    if drawStore.isLoadingYear(item) {
                        ProgressView()
                    } else {
                        Text("查看今年全部")
                    }
                }
                .buttonStyle(SecondaryGlassButton(tint: item.tint))
                .disabled(drawStore.isLoadingYear(item))

                Text(drawStore.yearLoadFailed(item)
                     ? "没读到整年数据，检查一下网络再试"
                     : "当前显示最近 \(count) 期")
                    .font(.caption2)
                    .foregroundStyle(drawStore.yearLoadFailed(item) ? Palette.warning : .tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
        }
    }

    /// 彩种切换条。
    ///
    /// 这里刻意**不用玻璃**：本项目的分层原则是玻璃只属于悬浮在内容之上的导航层，
    /// 这排芯片跟着内容一起滚，早期版本给它套 glassPill，选中态的渐变被玻璃糊掉，
    /// 白字压上去也读不清。改成和票夹筛选条一致的实心芯片。
    private var gameTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GameKey.ordered) { item in
                    let isOn = game == item
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { game = item }
                    } label: {
                        Text(item.label)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(isOn ? item.onTint : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isOn ? AnyShapeStyle(item.tint) : AnyShapeStyle(Palette.card),
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(isOn ? item.accent.solidStroke : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
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
