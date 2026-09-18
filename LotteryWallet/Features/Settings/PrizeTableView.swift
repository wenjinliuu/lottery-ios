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
                        .font(.system(size: 10))
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
            Image(systemName: icon).font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
