import SwiftUI

/// 一颗号码球。命中时放大高亮，未命中在核对结果里压暗。
struct BallView: View {
    let value: Int
    var color: BallColor
    var size: CGFloat = 32
    /// 是否命中开奖号。
    var isHit: Bool = false
    /// 核对结果里未命中的球压暗，让命中的更跳。
    var isDimmed: Bool = false
    /// 空心球用于选号盘上的未选中状态。
    var isHollow: Bool = false
    /// 号码区最大值大于 9 时补零到两位，数字型玩法（3D、排列3/5、七星彩）保持单位数。
    var padded: Bool = true

    private var label: String {
        padded && value < 10 ? String(format: "%02d", value) : String(value)
    }

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.44, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isHollow ? color.accentColor : color.ink)
            .frame(width: size, height: size)
            .background {
                if isHollow {
                    Circle()
                        .fill(color.accentColor.opacity(0.12))
                        .overlay(Circle().strokeBorder(color.accentColor.opacity(0.38), lineWidth: 1))
                } else {
                    Circle()
                        .fill(color.gradient)
                        .overlay(
                            // 顶部高光，让球有体积。这里刻意不用 plusLighter：
                            // 没有 compositingGroup 的加色混合会连页面底色一起提亮，
                            // 在浅色模式下球周围会糊出一圈。
                            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
                        )
                        // 黄球、琥珀球本身很亮，压在浅色卡片上边缘会糊掉，
                        // 补一圈同色深端把轮廓勾出来。
                        .overlay(Circle().strokeBorder(color.rimStroke, lineWidth: 0.8))
                }
            }
            // 命中就是放大 + 更重的辉光。原来还叠了一圈白描边，
            // 在小尺寸下反而把数字挤得发糊。
            .shadow(color: isHollow ? .clear : color.deep.opacity(isHit ? 0.55 : 0.28),
                    radius: isHit ? 9 : 4, y: isHit ? 3 : 2)
            .opacity(isDimmed ? 0.34 : 1)
            .scaleEffect(isHit ? 1.1 : 1)
            // Apple 的说法是「阻尼比 + 响应时间」。命中是一次带冲量的状态变化，
            // 给一点点回弹（bounce 0.25）比临界阻尼更贴合。
            .animation(.spring(duration: 0.34, bounce: 0.25), value: isHit)
            .accessibilityLabel(Text(isHit ? "\(label) 已命中" : label))
    }
}

/// 一个号码区（红球、前区……）的一行球。
struct BallRow: View {
    let section: GameSection
    let values: [Int]
    /// 逐球命中标记，来自核对结果。
    var matched: [Bool] = []
    var size: CGFloat = 32
    /// 有核对结果时，未命中的球压暗。
    var dimUnmatched: Bool = false
    /// 最多画几颗，超出的用省略号代替。0 表示不限制。
    var limit: Int = 0

    private var shown: [Int] {
        limit > 0 ? Array(values.prefix(limit)) : values
    }

    private var hidden: Int {
        Swift.max(values.count - shown.count, 0)
    }

    var body: some View {
        HStack(spacing: size * 0.19) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, value in
                let hit = index < matched.count && matched[index]
                BallView(value: value,
                         color: section.color,
                         size: size,
                         isHit: hit,
                         isDimmed: dimUnmatched && !hit,
                         padded: section.range.upperBound > 9)
            }
            if hidden > 0 {
                // 快乐8 一期开 20 个号，全画出来会把卡片撑爆。
                // 用一颗「省略球」收尾，形状和号码球一致，读者一眼知道后面还有。
                Text("···")
                    .font(.system(size: size * 0.5, weight: .black))
                    .foregroundStyle(section.color.accentColor)
                    .frame(width: size, height: size)
                    .background(Circle().fill(section.color.accentColor.opacity(0.14)))
                    .accessibilityLabel("另有 \(hidden) 个号码")
            }
        }
    }
}

/// 一整注号码（可能有多个号码区）。
///
/// **不滚动。** 早期版本给每一行号码套一个横向 ScrollView，既让列表里
/// 出现几十个嵌套滚动视图，也让用户以为号码是被裁掉的。现在改成
/// 在几档球径里挑一个装得下的，装不下再靠 `limit` 收省略号。
struct TicketNumbersView: View {
    let game: GameKey
    let ticket: Ticket
    var matched: [SectionKey: [Bool]] = [:]
    /// 期望球径。装不下时会自动往下降档。
    var size: CGFloat = 30
    var dimUnmatched: Bool = false

    var body: some View {
        FittedBallLayout(preferred: size) { resolved in
            HStack(spacing: resolved * 0.33) {
                ForEach(game.sections) { section in
                    let values = ticket[section.key]
                    if !values.isEmpty {
                        BallRow(section: section,
                                values: values,
                                matched: matched[section.key] ?? [],
                                size: resolved,
                                dimUnmatched: dimUnmatched)
                    }
                }
            }
        }
    }
}

/// 开奖号码的一行球。同样不滚动。
struct DrawNumbersView: View {
    let draw: Draw
    var size: CGFloat = 30
    /// 每个号码区最多画几颗。快乐8 在首页只画 8 颗。
    var limit: Int = 0

    var body: some View {
        FittedBallLayout(preferred: size) { resolved in
            HStack(spacing: resolved * 0.33) {
                ForEach(draw.gameKey.drawSections) { section in
                    let values = draw.drawValues[section.key]
                    if !values.isEmpty {
                        BallRow(section: section, values: values, size: resolved, limit: limit)
                    }
                }
            }
        }
    }
}

/// 在几档球径里挑第一个装得下的。
///
/// `ViewThatFits` 会按顺序量一遍候选项，选第一个不溢出的 —— 正好是
/// 「能大就大，装不下就缩」这个需求，而且不需要 GeometryReader 那一层
/// 读尺寸再回写状态的循环。
struct FittedBallLayout<Content: View>: View {
    var preferred: CGFloat
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        // 候选项写死成五个，不要用 ForEach —— ViewThatFits 需要的是一组
        // 静态子视图，按顺序量到第一个不溢出的为止。
        // 最小到 62%，再小数字就看不清了，那种情况交给 `limit` 收省略号。
        ViewThatFits(in: .horizontal) {
            content(preferred)
            content(preferred * 0.88)
            content(preferred * 0.78)
            content(preferred * 0.70)
            content(preferred * 0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
