import SwiftUI

/// 电子票纸张。在纯白画布上呈现象牙白纸面、极轻彩种微染与柔和桌面投影，
/// 左右腰部用真几何路径镂空撕票孔，轮廓描边和阴影一并贴合缺口弧线。
struct TicketPaper<Content: View>: View {
    let game: GameKey
    /// 缺口在票面高度上的位置比例。
    var notchPosition: CGFloat = 0.5
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme
    private let cornerRadius: CGFloat = 20
    private let notchRadius: CGFloat = 8

    var body: some View {
        let shape = TicketOutlineShape(cornerRadius: cornerRadius,
                                       notchPosition: notchPosition,
                                       notchRadius: notchRadius)
        content
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 13)
            // 阴影只画在背景矢量路径上，不让里面的号码球和文字触发离屏渲染。
            .background {
                ZStack {
                    shape.fill(Palette.paper)
                    shape.fill(
                        LinearGradient(
                            colors: [game.tint.opacity(colorScheme == .dark ? 0.08 : 0.035), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.065),
                        radius: 12, x: 0, y: 4)
            }
            .overlay {
                shape.stroke(game.tint.opacity(colorScheme == .dark ? 0.28 : 0.22), lineWidth: 1)
            }
            // 长按弹菜单时，预览按卡片自己的圆角裁，不再闪一块深色的方角
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 带左右半圆撕票缺口的圆角票面路径。
struct TicketOutlineShape: Shape {
    var cornerRadius: CGFloat = 20
    var notchPosition: CGFloat = 0.5
    var notchRadius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        guard w > 0, h > 0 else { return Path() }

        let r = min(cornerRadius, w / 2, h / 2)
        let nr = min(notchRadius, max(0, (h - r * 2 - 4) / 2))
        let minY = r + nr + 2
        let maxY = max(minY, h - r - nr - 2)
        let notchY = min(max(h * notchPosition, minY), maxY)
        let hasNotches = nr >= 2 && h >= (r + nr) * 2 + 4

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addRelativeArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                            radius: r, startAngle: .degrees(270), delta: .degrees(90))
        if hasNotches {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + notchY - nr))
            path.addRelativeArc(center: CGPoint(x: rect.maxX, y: rect.minY + notchY),
                                radius: nr, startAngle: .degrees(270), delta: .degrees(-180))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addRelativeArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                            radius: r, startAngle: .degrees(0), delta: .degrees(90))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addRelativeArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                            radius: r, startAngle: .degrees(90), delta: .degrees(90))
        if hasNotches {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + notchY + nr))
            path.addRelativeArc(center: CGPoint(x: rect.minX, y: rect.minY + notchY),
                                radius: nr, startAngle: .degrees(90), delta: .degrees(-180))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addRelativeArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                            radius: r, startAngle: .degrees(180), delta: .degrees(90))
        path.closeSubpath()
        return path
    }
}

/// 票面上的虚线分隔。
struct TicketDivider: View {
    var tint: Color

    var body: some View {
        Line()
            .stroke(tint.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
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
        HStack(spacing: 3) {
            Image(systemName: status.symbol)
                .scaledFont(9, weight: .bold)
            Text(status.label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(status.tint.opacity(0.13), in: Capsule())
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
