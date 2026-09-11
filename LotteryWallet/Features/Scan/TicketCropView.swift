import SwiftUI
import UIKit

/// 手动框出票面的四个角。
///
/// 这是这一版扫描流程的核心改动。之前是全自动：矩形检测找票、切图、逐张识别，
/// 用户看不到中间过程。问题是检测本来就不可能一直对 —— 反光、折痕、深色桌面、
/// 几张票叠在一起，任何一样都能让它框错，而**框错之后用户毫不知情**，
/// 只会看到一堆莫名其妙的号码。
///
/// 现在把最后一道判断交回给人：检测结果只作为四个角的**起始位置**，
/// 猜中了一下都不用动，猜不中拖两下就好。之后的透视矫正、放大、识别照旧。
/// 一次一张票 —— 一张照片里有好几张就扫几次，比让机器猜谁是谁可靠得多。
struct TicketCropView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onConfirm: (TicketQuad) -> Void

    @State private var quad = TicketQuad.default
    @State private var isReady = false
    /// 正在拖的那个角，用来放大它的手柄。
    @State private var activeCorner: Int?

    private let handleRadius: CGFloat = 14
    private static let canvasSpace = "ticket-crop-canvas"

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                let frame = displayFrame(in: proxy.size)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    if isReady {
                        mask(in: frame)
                        outline(in: frame)
                        ForEach(0..<4, id: \.self) { index in
                            handle(index: index, in: frame)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .coordinateSpace(.named(Self.canvasSpace))
            }
            footer
        }
        .background(Color.black)
        .task {
            // 检测只是给个起点，慢一点也没关系；拿不到就用默认的内缩框
            if let suggestion = await TicketImagePreprocessor.suggestedQuad(in: image) {
                quad = suggestion
            }
            withAnimation(.easeOut(duration: 0.2)) { isReady = true }
        }
    }

    // MARK: - 头尾

    private var header: some View {
        VStack(spacing: 4) {
            Text("框出这张彩票")
                .font(.headline)
                .foregroundStyle(.white)
            Text("拖动四个角对齐票面边缘，斜着拍的会自动摆正")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            // 裁切页是纯黑底，统一的 DisclaimerNote 用的是次要色，在这里看不清，
            // 所以这一处单独给白色。文案仍然走同一个来源。
            Text(Disclaimer.crop)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            buttons
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("重拍") { onCancel() }
                .buttonStyle(SecondaryGlassButton(tint: .white))
                .fixedSize()

            Button("重置") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    quad = .default
                }
            }
            .buttonStyle(SecondaryGlassButton(tint: .white))
            .fixedSize()

            Button("识别这张") { onConfirm(quad) }
                .buttonStyle(ProminentGlassButton(tint: .accentColor))
        }
    }

    // MARK: - 画布

    /// 图片按 scaledToFit 之后实际占的那块矩形。
    /// 归一化坐标要在这块矩形里换算，不能拿整个画布算。
    private func displayFrame(in canvas: CGSize) -> CGRect {
        let imageRatio = image.size.width / Swift.max(image.size.height, 1)
        let canvasRatio = canvas.width / Swift.max(canvas.height, 1)
        var size = canvas
        if imageRatio > canvasRatio {
            size.height = canvas.width / imageRatio
        } else {
            size.width = canvas.height * imageRatio
        }
        return CGRect(x: (canvas.width - size.width) / 2,
                      y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func viewPoint(_ normalized: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + normalized.x * frame.width,
                y: frame.minY + normalized.y * frame.height)
    }

    private func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: Swift.min(Swift.max((point.x - frame.minX) / frame.width, 0), 1),
                y: Swift.min(Swift.max((point.y - frame.minY) / frame.height, 0), 1))
    }

    /// 框外压暗，注意力落在框里。
    private func mask(in frame: CGRect) -> some View {
        Canvas { context, size in
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addPath(quadPath(in: frame))
            context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    private func outline(in frame: CGRect) -> some View {
        quadPath(in: frame)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .allowsHitTesting(false)
    }

    private func quadPath(in frame: CGRect) -> Path {
        var path = Path()
        let points = quad.corners.map { viewPoint($0, in: frame) }
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// 一个角上的手柄。
    ///
    /// **手势必须挂在 `.position` 之前。** `.position` 返回的视图会占满整个父容器
    /// （它只是把子视图摆到那个点上），手势挂在它后面的话，四个手柄就是四块
    /// 铺满全屏的热区叠在一起 —— 最后画的那个（左下角）压在最上面，
    /// 于是屏幕上点哪儿动的都是它。这就是「只能拖左下角」的原因。
    ///
    /// 另外拖动的坐标要取**画布坐标**：手势挂在 52pt 的小圆上时，
    /// `value.location` 默认是相对这个小圆的，必须指定 `coordinateSpace`。
    private func handle(index: Int, in frame: CGRect) -> some View {
        let center = viewPoint(quad[index], in: frame)
        let isActive = activeCorner == index
        return Circle()
            .fill(Color.accentColor)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .frame(width: handleRadius * 2, height: handleRadius * 2)
            .scaleEffect(isActive ? 1.4 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isActive)
            // 手柄本身 28pt，够不上 44pt 的最小点击区，撑到 56pt 当热区
            .frame(width: 56, height: 56)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.canvasSpace))
                    .onChanged { value in
                        activeCorner = index
                        quad[index] = normalized(value.location, in: frame)
                    }
                    .onEnded { _ in activeCorner = nil }
            )
            .position(center)
    }
}
