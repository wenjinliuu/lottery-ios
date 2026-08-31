import SwiftUI

/// 电子票纸张背景。玻璃打底，叠一层彩种色辉光，
/// 左右腰部各盖一个与页面同色的小圆，做出撕票孔，
/// 对应 web 版 `.wallet-ticket::before/::after`。
struct TicketPaper<Content: View>: View {
    let game: GameKey
    /// 缺口在票面高度上的位置比例。
    var notchPosition: CGFloat = 0.5
    @ViewBuilder var content: Content

    private let cornerRadius: CGFloat = 25
    private let notchDiameter: CGFloat = 17

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(.horizontal, 16)
            .padding(.top, 17)
            .padding(.bottom, 13)
            .background {
                ZStack {
                    // 右上角的彩种辉光，对应 web 版的 radial-gradient
                    RadialGradient(
                        colors: [game.tint.opacity(0.20), .clear],
                        center: .init(x: 1, y: 0),
                        startRadius: 0,
                        endRadius: 240
                    )
                    LinearGradient(
                        colors: [game.tint.opacity(0.10), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .clipShape(shape)
            }
            .glassEffect(GlassStyle.card(tint: game.tint), in: shape)
            .overlay {
                shape.stroke(game.tint.opacity(0.20), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) { notches }
            .shadow(color: game.tint.opacity(0.14), radius: 12, y: 5)
    }

    /// 左右两个撕票孔。用 GeometryReader 换算缺口的纵向位置。
    private var notches: some View {
        GeometryReader { proxy in
            let y = proxy.size.height * min(max(notchPosition, 0.08), 0.92)
            ZStack {
                notch.position(x: 0, y: y)
                notch.position(x: proxy.size.width, y: y)
            }
        }
        .allowsHitTesting(false)
    }

    private var notch: some View {
        Circle()
            .fill(Color(.systemGroupedBackground))
            .overlay(Circle().strokeBorder(game.tint.opacity(0.12), lineWidth: 1))
            .frame(width: notchDiameter, height: notchDiameter)
    }
}

/// 票面上的虚线分隔，对应 web 版 `border-bottom: 1px dashed`。
struct TicketDivider: View {
    var tint: Color

    var body: some View {
        Line()
            .stroke(tint.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// 状态胶囊："待核对 / 已中奖 / 未中奖 / 奖金待公布"。
struct StatusChip: View {
    let status: RecordStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
                .font(.caption2.weight(.bold))
            Text(status.label)
                .font(.caption2.weight(.heavy))
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(status.tint.opacity(0.14), in: Capsule())
    }
}

/// 票面上的小字元信息（期号、倍数、录入方式）。
struct TicketMetaText: View {
    let items: [String]

    var body: some View {
        Text(items.filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}
