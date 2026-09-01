import SwiftUI

/// 往期开奖：按彩种查看最近 50 期。
struct DrawHistoryView: View {
    @Environment(DrawStore.self) private var drawStore
    @Environment(\.dismiss) private var dismiss

    @State private var game: GameKey = .ssq
    @State private var isLoading = false

    private var history: [Draw] {
        drawStore.draws(for: game)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    gameTabs
                    if !history.isEmpty {
                        ForEach(history) { draw in
                            DrawHistoryRow(draw: draw)
                        }
                    } else if isLoading {
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
                            Button("重试") { Task { await reload() } }
                                .buttonStyle(SecondaryGlassButton(tint: game.tint))
                        }
                        .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .background(Palette.canvas)
            .navigationTitle("往期开奖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task(id: game) { await reload() }
        }
    }

    private func reload() async {
        guard history.isEmpty else { return }
        isLoading = true
        await drawStore.loadHistory(for: game)
        isLoading = false
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
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

struct DrawHistoryRow: View {
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
            ScrollView(.horizontal, showsIndicators: false) {
                DrawNumbersView(draw: draw, size: 28)
            }
            .scrollClipDisabled()
            if let first = draw.firstPrize, first.winningCount > 0 {
                Text("一等奖 \(first.winningCount) 注"
                     + (first.amount > 0 ? " · \(MoneyText.compactYuan(first.amount))/注" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // contentCard 自己就带 16pt 内边距，外面再加一层等于 32pt，
        // 卡片里的内容会比首页窄一大截。
        .contentCard(cornerRadius: 20)
    }
}
