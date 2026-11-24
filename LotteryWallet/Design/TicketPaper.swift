import SwiftUI

/// 电子票纸张。不透明卡片打底，右上角压一层很淡的彩种色，
/// 左右腰部各盖一个与页面同色的小圆做撕票孔，
/// 对应 web 版 `.wallet-ticket` 及其 `::before/::after`。
struct TicketPaper<Content: View>: View {
    let game: GameKey
    /// 缺口在票面高度上的位置比例。
    var notchPosition: CGFloat = 0.5
    @ViewBuilder var content: Content

    private let cornerRadius: CGFloat = 18
    private let notchDiameter: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 13)
            // 票面就是一张白纸。右上角原来有一层彩种辉光，本意是区分彩种，
            // 实际效果是每张卡片都糊着一块颜色，一列卡片刷下来很脏；
            // 而且彩种已经有描边和标题两处在说了，第三处纯属重复。
            // 阴影画在这块纯色底上。直接给整张卡片加 `.shadow` 的话，系统要把里面的号码球、
            // 文字全部离屏渲染一遍再算阴影，票夹一屏十几张卡片，滑动时就掉帧。
            .background {
                shape.fill(Palette.card)
                    .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 3)
            }
            // 原来每张票一圈彩种色的描边：几张叠在一起红紫蓝各一圈，显得花。
            // 现在只留一道极淡的发丝线，靠一层很浅的阴影把卡片托起来；认彩种靠左上角的彩种名。
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
            .overlay(alignment: .topLeading) { notches }
            // 长按弹菜单时，预览按卡片自己的圆角裁，不再闪一块深色的方角
            .contentShape(.contextMenuPreview, shape)
    }

    /// 左右两个撕票孔。
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
            .fill(Palette.canvas)
            .frame(width: notchDiameter, height: notchDiameter)
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
