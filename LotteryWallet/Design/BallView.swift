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
                }
            }
            .overlay {
                if isHit {
                    // 命中环紧贴球沿。父层已经整体放大 1.08，这里不能再叠一次缩放，
                    // 否则环会被放到 1.17 倍，飘在球外面。
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.6)
                }
            }
            .shadow(color: isHollow ? .clear : color.deep.opacity(isHit ? 0.5 : 0.28),
                    radius: isHit ? 8 : 4, y: isHit ? 3 : 2)
            .opacity(isDimmed ? 0.34 : 1)
            .scaleEffect(isHit ? 1.08 : 1)
            .animation(.spring(response: 0.34, dampingFraction: 0.62), value: isHit)
            .accessibilityLabel(Text(isHit ? "\(label) 已命中" : label))
    }
}

/// 一个号码区（红球、前区……）的一行球。
struct BallRow: View {
    let game: GameKey
    let section: GameSection
    let values: [Int]
    /// 逐球命中标记，来自核对结果。
    var matched: [Bool] = []
    var size: CGFloat = 32
    /// 有核对结果时，未命中的球压暗。
    var dimUnmatched: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                let hit = index < matched.count && matched[index]
                BallView(value: value,
                         color: section.color,
                         size: size,
                         isHit: hit,
                         isDimmed: dimUnmatched && !hit,
                         padded: section.range.upperBound > 9)
            }
        }
    }
}

/// 一整注号码（可能有多个号码区）。
struct TicketNumbersView: View {
    let game: GameKey
    let ticket: Ticket
    var matched: [SectionKey: [Bool]] = [:]
    var size: CGFloat = 30
    var dimUnmatched: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(game.sections) { section in
                let values = ticket[section.key]
                if !values.isEmpty {
                    BallRow(game: game,
                            section: section,
                            values: values,
                            matched: matched[section.key] ?? [],
                            size: size,
                            dimUnmatched: dimUnmatched)
                }
            }
        }
    }
}

/// 开奖号码的一行球。
struct DrawNumbersView: View {
    let draw: Draw
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: 10) {
            ForEach(draw.gameKey.drawSections) { section in
                let values = draw.drawValues[section.key]
                if !values.isEmpty {
                    BallRow(game: draw.gameKey, section: section, values: values, size: size)
                }
            }
        }
    }
}
