import SwiftUI

/// 奖级对照表。
///
/// 版式刻意和「往期开奖」一模一样：顶上一条彩种芯片，下面分页 TabView，
/// 左右滑动换彩种。这两页都是「按彩种查一份参考资料」，用同一套骨架，
/// 用户学一次就够了。
///
/// **这一页不做任何计算。** 它是说明书，判奖永远走 `PrizeRules` + 官方当期数据。
struct PrizeTableView: View {
    @Environment(\.dismiss) private var dismiss

    /// 从哪个彩种打开。默认双色球，和首页排序一致。
    @State private var game: GameKey = .ssq

    var body: some View {
        VStack(spacing: 10) {
            gameTabs
                .padding(.horizontal, 16)
            TabView(selection: $game) {
                ForEach(GameKey.ordered) { item in
                    page(for: item).tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .padding(.top, 8)
        .background(Palette.canvas)
        .navigationTitle("奖级对照表")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 一个彩种一页

    private func page(for item: GameKey) -> some View {
        let table = PrizeTable.table(for: item)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if item == .k8 { k8Card }
                ForEach(table.groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        if let title = group.title {
                            Text(title)
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(item.accent.accentColor)
                                .padding(.bottom, 8)
                        }
                        ForEach(Array(group.tiers.enumerated()), id: \.element.id) { index, tier in
                            if index > 0 { Divider().padding(.vertical, 8) }
                            tierRow(tier, game: item)
                        }
                    }
                    .contentCard()
                }

                if let note = table.note {
                    footnote(note, icon: "info.circle")
                }
                // 这一行必须有，而且每个彩种都要看得到：
                // 固定奖金官方会调，表是死的，实际以官方为准。
                footnote(Self.sourceNote, icon: "checkmark.seal")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
    }

    /// 快乐8：一个玩法一行，「中N 金额」成对横排。
    ///
    /// 十个玩法各自铺一张卡要滚三屏，而这张表就是用来「一眼扫到自己那档」的。
    /// 压成十行之后整个表一屏多一点就看完了，和官方那张对照表的密度一致。
    private var k8Card: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(PrizeTable.k8Rows.enumerated()), id: \.element.play) { index, row in
                if index > 0 { Divider().padding(.vertical, 7) }
                HStack(alignment: .top, spacing: 10) {
                    Text(row.play)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(GameKey.k8.accent.accentColor)
                        .frame(width: 34, alignment: .leading)
                    // 每行最多四档，多的折到下一行。
                    //
                    // 固定分行而不是自适应换行：最长的「选十」也只有七档，
                    // 4+3 两行在最窄的机型上也放得下，而且每一行的列位固定，
                    // 十个玩法竖着扫下来是对齐的 —— 表格要的就是这个。
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(Self.chunked(row.hits, size: 4).enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 6) {
                                ForEach(Array(line.enumerated()), id: \.element.0) { _, hit in
                                    HStack(spacing: 3) {
                                        Text(hit.0)
                                            .foregroundStyle(.secondary)
                                        Text(hit.1)
                                            .fontWeight(.semibold)
                                            .monospacedDigit()
                                    }
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(GameKey.k8.tint.opacity(0.10), in: Capsule())
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
        .contentCard()
    }

    private static func chunked(_ items: [(String, String)], size: Int) -> [[(String, String)]] {
        stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }

    private static let sourceNote =
        "数据整理自中国体彩网、中国福彩网公布的游戏规则。奖金金额官方可能调整，"
        + "本表仅供参考，中奖与兑奖一律以官方公布和实体票为准。"

    // MARK: - 一行奖级

    private func tierRow(_ tier: PrizeTable.Tier, game: GameKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(tier.name)
                .font(.caption.weight(.bold))
                .frame(width: 52, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(tier.conditions.enumerated()), id: \.offset) { _, condition in
                    switch condition {
                    case let .balls(groups):
                        HStack(spacing: 8) {
                            ForEach(Array(groups.enumerated()), id: \.offset) { _, item in
                                ballGroup(item)
                            }
                        }
                    case let .text(text):
                        Text(text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note = tier.note {
                    Text(note)
                        .scaledFont(10)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 6)

            Text(tier.amount)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(game.tint)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 84, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(tier))
    }

    /// 一组球：对上的实心、其余中性灰。
    ///
    /// 这里不用 `BallView` —— 那颗球上要写号码，而对照表说的是「对上几个」，
    /// 具体是哪个号无关紧要，写上数字反而像在举例。只取它的配色。
    private func ballGroup(_ group: PrizeTable.BallGroup) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<group.total, id: \.self) { index in
                Circle()
                    .fill(index < group.hit
                          ? AnyShapeStyle(group.color.gradient)
                          : AnyShapeStyle(Palette.missLight))
                    .frame(width: 11, height: 11)
                    .overlay(
                        Circle().strokeBorder(index < group.hit
                                              ? group.color.rimStroke
                                              : Palette.missDeep,
                                              lineWidth: 0.6)
                    )
            }
        }
    }

    private func accessibilityText(_ tier: PrizeTable.Tier) -> String {
        var parts = [tier.name]
        for condition in tier.conditions {
            switch condition {
            case let .text(text): parts.append(text)
            case let .balls(groups):
                parts.append(groups.map { "对中 \($0.hit) 个（共 \($0.total) 个）" }.joined(separator: "，"))
            }
        }
        parts.append(tier.amount)
        return parts.joined(separator: "，")
    }

    // MARK: - 彩种切换条
    //
    // 和「往期开奖」那条完全一致，见 `DrawHistoryView.gameTabs` 的说明：
    // 跟着内容滚的芯片条不用玻璃，用实心。

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

    @ViewBuilder
    private func footnote(_ text: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).scaledFont(10)
            Text(text)
                .scaledFont(11)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

// MARK: - Preview
//
// 这一页的排版全靠肉眼：八个彩种的球、金额列在窄屏会不会挤、
// 快乐8 那张压缩表折行对不对。有了 Preview 就不用每次等 TestFlight。
#Preview("奖级对照表") {
    NavigationStack { PrizeTableView() }
}

#Preview("奖级对照表 · 最大字号") {
    NavigationStack { PrizeTableView() }
        .environment(\.dynamicTypeSize, .accessibility3)
}
