import SwiftUI

/// 一颗号码球。命中时放大高亮，未命中在核对结果里换成中性灰。
struct BallView: View {
    let value: Int
    var color: BallColor
    var size: CGFloat = 32
    /// 是否命中开奖号。
    var isHit: Bool = false
    /// 核对结果里未命中的球。
    var isDimmed: Bool = false
    /// 空心球用于选号盘上的未选中状态。
    var isHollow: Bool = false
    /// 号码区最大值大于 9 时补零到两位，数字型玩法（3D、排列3/5、七星彩）保持单位数。
    var padded: Bool = true

    /// 这一位还没认出来（扫描识别用，见 `NumberSet.unknown`）。
    private var isUnknown: Bool { value < 0 }

    private var label: String {
        if isUnknown { return "?" }
        return padded && value < 10 ? String(format: "%02d", value) : String(value)
    }

    /// 未命中的球换成实心中性灰，而不是把彩色球调透明。
    /// 半透明的做法会连白字一起变淡，整张票看起来像褪了色；
    /// 灰球是「设计成这样」，透明球是「没加载完」。
    private var fill: LinearGradient {
        isDimmed
            ? LinearGradient(colors: [Palette.missLight, Palette.missDeep], startPoint: .top, endPoint: .bottom)
            : color.gradient
    }

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.44, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(unknownOrRegularInk)
            .frame(width: size, height: size)
            .background {
                if isUnknown {
                    // 虚线空心 + 警示色：一眼看得出「这一位要你补」，
                    // 而不是像个普通号码球那样被划过去。
                    Circle()
                        .fill(Palette.warning.opacity(0.12))
                        .overlay(Circle().strokeBorder(Palette.warning,
                                                       style: StrokeStyle(lineWidth: 1.4, dash: [3, 2.5])))
                } else if isHollow {
                    Circle()
                        .fill(color.accentColor.opacity(0.12))
                        .overlay(Circle().strokeBorder(color.accentColor.opacity(0.38), lineWidth: 1))
                } else {
                    Circle()
                        .fill(fill)
                        .overlay(Circle().strokeBorder(.white.opacity(isDimmed ? 0 : 0.35), lineWidth: 0.8))
                        // 黄球、琥珀球本身很亮，压在浅色卡片上边缘会糊掉，
                        // 补一圈同色深端把轮廓勾出来。
                        .overlay(Circle().strokeBorder(isDimmed ? .clear : color.rimStroke, lineWidth: 0.8))
                }
            }
            // 阴影只给命中的球。一屏几百个阴影图层是票夹卡顿的来源之一，
            // 而未命中的球本来就该退到后面去。
            //
            // 半径刻意收得很紧：8pt 的光晕在票夹里会漫到相邻球上，
            // 一行命中三四颗时整排糊成一片。命中要靠"亮一点、鼓一点"来读，
            // 而不是靠一圈发光。
            .shadow(color: isHit ? color.deep.opacity(0.34) : .clear,
                    radius: isHit ? 3 : 0, y: isHit ? 1.5 : 0)
            .scaleEffect(isHit ? 1.06 : 1)
            .animation(.spring(duration: 0.34, bounce: 0.25), value: isHit)
            .accessibilityLabel(Text(accessibilityText))
    }

    private var unknownOrRegularInk: Color {
        if isUnknown { return Palette.warning }
        if isHollow { return color.accentColor }
        return isDimmed ? Palette.missInk : Color.white
    }

    private var accessibilityText: String {
        if isUnknown { return "这一位没认出来，点一下补" }
        if isHit { return "\(label) 已命中" }
        return isDimmed ? "\(label) 未命中" : label
    }
}

/// 「还有 N 个」的省略球。点一下展开全部号码。
struct OverflowBall: View {
    let hidden: Int
    var color: BallColor
    var size: CGFloat
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            Text("···")
                .font(.system(size: size * 0.5, weight: .black))
                .foregroundStyle(color.accentColor)
                .frame(width: size, height: size)
                .background(Circle().fill(color.accentColor.opacity(0.14)))
                .overlay(Circle().strokeBorder(color.accentColor.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(PressableIcon())
        .disabled(action == nil)
        .accessibilityLabel("展开其余 \(hidden) 个号码")
    }
}

/// 流式布局里的一颗球。
///
/// 必须把球摊平成 `Layout` 的直接子视图 —— `Layout` 只会展开 `ForEach`，
/// 不会拆开自定义 View。要是把「一个号码区」包成一个 View 塞进去，
/// 快乐8 的 20 颗球就是一整块，永远换不了行。
private struct BallItem: Identifiable {
    let id: Int
    let value: Int
    let color: BallColor
    let isHit: Bool
    let isDimmed: Bool
    let padded: Bool
    /// 号码区之间的额外间隙，加在该区首颗球的左边。
    let leadingGap: CGFloat
    /// 大于 0 表示这是一颗省略球，代表还有这么多号码没画。
    let overflow: Int
}

/// 把若干号码区摊平成一串球。
private func flatten(sections: [GameSection],
                     values: (GameSection) -> [Int],
                     matched: (GameSection) -> [Bool],
                     size: CGFloat,
                     dimUnmatched: Bool,
                     limit: Int) -> [BallItem] {
    var items: [BallItem] = []
    var isFirstSection = true
    for section in sections {
        let all = values(section)
        guard !all.isEmpty else { continue }
        let flags = matched(section)
        let shown = limit > 0 ? Array(all.prefix(limit)) : all
        let gap = isFirstSection ? 0 : size * 0.24
        for (index, value) in shown.enumerated() {
            let hit = index < flags.count && flags[index]
            items.append(BallItem(id: items.count, value: value, color: section.color,
                                  isHit: hit, isDimmed: dimUnmatched && !hit,
                                  padded: section.range.upperBound > 9,
                                  leadingGap: index == 0 ? gap : 0, overflow: 0))
        }
        let hidden = all.count - shown.count
        if hidden > 0 {
            items.append(BallItem(id: items.count, value: 0, color: section.color,
                                  isHit: false, isDimmed: false, padded: false,
                                  leadingGap: 0, overflow: hidden))
        }
        isFirstSection = false
    }
    return items
}

@ViewBuilder
private func ballFlow(_ items: [BallItem], size: CGFloat, onOverflow: (() -> Void)?) -> some View {
    BallFlow(spacing: size * 0.19, lineSpacing: size * 0.22) {
        ForEach(items) { item in
            if item.overflow > 0 {
                OverflowBall(hidden: item.overflow, color: item.color, size: size, action: onOverflow)
                    .padding(.leading, item.leadingGap)
            } else {
                BallView(value: item.value, color: item.color, size: size,
                         isHit: item.isHit, isDimmed: item.isDimmed, padded: item.padded)
                    .padding(.leading, item.leadingGap)
            }
        }
    }
}

/// 一整注号码（可能有多个号码区）。
///
/// **不滚动、不缩放。** 球径是固定的，装不下就换行 —— 这是最不容易出错的做法。
/// 早期版本先是给每行套横向 ScrollView（列表里几十个嵌套滚动视图），
/// 后来改成 ViewThatFits 在五档球径里挑（每行号码的视图树被构造五遍），
/// 两种都是票夹卡顿的直接原因。
struct TicketNumbersView: View {
    let game: GameKey
    let ticket: Ticket
    var matched: [SectionKey: [Bool]] = [:]
    var size: CGFloat = 30
    var dimUnmatched: Bool = false

    var body: some View {
        ballFlow(flatten(sections: game.sections,
                         values: { ticket[$0.key] },
                         matched: { matched[$0.key] ?? [] },
                         size: size, dimUnmatched: dimUnmatched, limit: 0),
                 size: size, onOverflow: nil)
    }
}

/// 一整注号码，但号码直接给纯数组 —— 票夹的渲染快照走这条路，
/// 全程不碰 SwiftData 对象。
struct TicketNumbersSnapshotView: View {
    let game: GameKey
    let numbers: [SectionKey: [Int]]
    var matched: [SectionKey: [Bool]] = [:]
    var size: CGFloat = 30
    var dimUnmatched: Bool = false

    var body: some View {
        ballFlow(flatten(sections: game.sections,
                         values: { numbers[$0.key] ?? [] },
                         matched: { matched[$0.key] ?? [] },
                         size: size, dimUnmatched: dimUnmatched, limit: 0),
                 size: size, onOverflow: nil)
    }
}

/// 开奖号码。同样固定球径、超宽换行。
struct DrawNumbersView: View {
    let draw: Draw
    var size: CGFloat = 30
    /// 每个号码区最多画几颗。首页卡片限 8 颗，往期页不限。
    var limit: Int = 0
    var onOverflow: (() -> Void)?

    var body: some View {
        ballFlow(flatten(sections: draw.gameKey.drawSections,
                         values: { draw.drawValues[$0.key] },
                         matched: { _ in [] },
                         size: size, dimUnmatched: false, limit: limit),
                 size: size, onOverflow: onOverflow)
    }
}

// MARK: - 流式布局

/// 从左到右排，排不下就换行。
///
/// 用 `Layout` 而不是 `ViewThatFits`：这里只量一遍，
/// 而 `ViewThatFits` 要把整组候选视图各构造一遍再挑。
struct BallFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > 0, x + spacing + s.width > maxWidth {
                widest = Swift.max(widest, x)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += (x > 0 ? spacing : 0) + s.width
            lineHeight = Swift.max(lineHeight, s.height)
        }
        widest = Swift.max(widest, x)
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > 0, x + spacing + s.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if x > 0 { x += spacing }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                       proposal: ProposedViewSize(s))
            x += s.width
            lineHeight = Swift.max(lineHeight, s.height)
        }
    }
}

/// 一排同色号码球，排不下就换行。选号预览、扫描复核这些"只是把号码摆出来"
/// 的地方用它，不用为了一排球去凑一个 `Ticket`。
struct BallRowView: View {
    let values: [Int]
    var color: BallColor
    var size: CGFloat = 26
    var padded: Bool = true
    /// 高亮其中某几个号（胆拖预览里的胆码、扫描复核里正在改的那颗）。
    var highlighted: Set<Int> = []
    var onTap: ((Int) -> Void)?

    var body: some View {
        BallFlow(spacing: size * 0.19, lineSpacing: size * 0.22) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                if let onTap {
                    Button { onTap(value) } label: {
                        BallView(value: value, color: color, size: size,
                                 isHit: highlighted.contains(value), padded: padded)
                    }
                    .buttonStyle(.plain)
                } else {
                    BallView(value: value, color: color, size: size,
                             isHit: highlighted.contains(value), padded: padded)
                }
            }
        }
    }
}
