import SwiftUI

/// 往期开奖：按彩种查看最近 50 期。
struct DrawHistoryView: View {
    @Environment(DrawStore.self) private var drawStore
    @Environment(\.dismiss) private var dismiss

    @State private var game: GameKey = .ssq

    private var history: [Draw] {
        drawStore.draws(for: game)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    gameTabs
                    if history.isEmpty {
                        ProgressView("正在读取往期开奖")
                            .padding(.top, 60)
                    } else {
                        ForEach(history) { draw in
                            DrawHistoryRow(draw: draw)
                        }
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
            .task(id: game) { await drawStore.loadHistory(for: game) }
        }
    }

    private var gameTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(GameKey.ordered) { item in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { game = item }
                        } label: {
                            Text(item.label)
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(game == item ? .white : Color.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .background {
                            if game == item { Capsule().fill(item.gradient) }
                        }
                        .glassPill(tint: game == item ? item.tint : nil)
                    }
                }
                .padding(.vertical, 2)
            }
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
                Spacer()
                Text(DateText.monthDay(draw.openDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                DrawNumbersView(draw: draw, size: 28)
            }
            .scrollClipDisabled()
            if let first = draw.firstPrize, first.winningCount > 0 {
                Text("一等奖 \(first.winningCount) 注" + (first.amount > 0 ? " · \(MoneyText.compact(first.amount))元/注" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 20)
    }
}
