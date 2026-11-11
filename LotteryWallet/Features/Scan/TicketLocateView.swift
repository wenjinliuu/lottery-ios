import SwiftUI
import UIKit

/// 预识别：照片里找到了几张票、各是什么，先摆给人看一眼，点头了再去认号码。
///
/// 上一版找完票直接去认，用户看不到中间这一步：两张票丢了一张，要到结果页数注数才发现，
/// 而且没法补救。现在每张票用它彩种的颜色框出来、编上号；框得不准可以拖四个角，
/// 漏掉的可以自己加一个框，多框的可以删。
struct TicketLocateView: View {
    struct Mark: Identifiable, Equatable {
        let id = UUID()
        var quad: TicketQuad
        /// 猜出来的彩种。手动加的框、或者票头没读出来的，是 nil。
        var game: GameKey?
        /// 后台还在认这张票。认完之前不下「没认出彩种」的结论，牌子上转圈。
        var isResolving = false
        /// 用户自己加的框。
        var isManual = false
    }

    let image: UIImage
    @Binding var marks: [Mark]
    /// 上一次识别没成时要说的话（比如「这几个框里都没认出票」）。
    var notice: String?
    var onCancel: () -> Void
    var onConfirm: () -> Void

    @State private var selected: Mark.ID?
    @State private var activeCorner: Int?

    private static let canvasSpace = "ticket-locate-canvas"

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
                        .onTapGesture { selected = nil }

                    ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                        outline(mark, number: index + 1, in: frame)
                    }
                    if let index = marks.firstIndex(where: { $0.id == selected }) {
                        ForEach(0..<4, id: \.self) { corner in
                            handle(mark: index, corner: corner, in: frame)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .coordinateSpace(.named(Self.canvasSpace))
            }
            footer
        }
        .background(Color.black)
        .onAppear {
            // 只有一个框的时候直接选中它，四个角马上能拖
            if marks.count == 1 { selected = marks.first?.id }
        }
    }

    // MARK: - 头尾

    private var header: some View {
        VStack(spacing: 4) {
            Text(marks.isEmpty ? "没有自动找到票" : "找到 \(marks.count) 张票")
                .font(.headline)
                .foregroundStyle(.white)
            Text(notice ?? (marks.isEmpty
                            ? "点「加一个框」，把框拖到票面四个角上"
                            : marks.contains(where: \.isResolving)
                                ? "正在逐张识别，框上的彩种稍后会更新"
                                : "框得不准就点那个框、拖四个角；漏了的票点「加一个框」"))
                .font(.caption)
                .foregroundStyle(notice == nil ? .white.opacity(0.7) : Color.orange)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let index = marks.firstIndex(where: { $0.id == selected }) {
                Button(role: .destructive) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        marks.remove(at: index)
                        selected = nil
                    }
                } label: {
                    Label("删掉第 \(index + 1) 个框", systemImage: "trash")
                        .font(.footnote.weight(.semibold))
                }
                .tint(.red)
                .accessibilityIdentifier("locate.remove")
            } else {
                Text(Disclaimer.crop)
                    .scaledFont(10)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("重拍") { onCancel() }
                    .buttonStyle(SecondaryGlassButton(tint: .white))
                    .fixedSize()

                Button("加一个框") { add() }
                    .buttonStyle(SecondaryGlassButton(tint: .white))
                    .fixedSize()
                    .accessibilityIdentifier("locate.add")

                Button(marks.count > 1 ? "识别这 \(marks.count) 张" : "识别这张") { onConfirm() }
                    .buttonStyle(ProminentGlassButton(tint: .accentColor))
                    .disabled(marks.isEmpty)
                    .accessibilityIdentifier("locate.confirm")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    /// 新框放在照片正中，占四成宽、五成高，并且直接选中。
    private func add() {
        let mark = Mark(quad: TicketQuad(topLeft: CGPoint(x: 0.3, y: 0.25), topRight: CGPoint(x: 0.7, y: 0.25),
                                         bottomRight: CGPoint(x: 0.7, y: 0.75), bottomLeft: CGPoint(x: 0.3, y: 0.75)),
                        isManual: true)
        withAnimation(.easeOut(duration: 0.15)) {
            marks.append(mark)
            selected = mark.id
        }
    }

    // MARK: - 画布

    static func color(for game: GameKey?) -> Color {
        game?.accent.accentColor ?? .white
    }

    static func title(number: Int, game: GameKey?) -> String {
        game.map { "\(number) \($0.label)" } ?? "\(number) 没认出彩种"
    }

    /// 牌子上写什么：认出来了写彩种；还在认写「识别中」；自己加的框写「手动框」。
    static func title(number: Int, mark: Mark) -> String {
        if let game = mark.game { return "\(number) \(game.label)" }
        if mark.isResolving { return "\(number) 识别中" }
        return mark.isManual ? "\(number) 手动框" : "\(number) 没认出彩种"
    }

    private func displayFrame(in canvas: CGSize) -> CGRect {
        let imageRatio = image.size.width / Swift.max(image.size.height, 1)
        let canvasRatio = canvas.width / Swift.max(canvas.height, 1)
        var size = canvas
        if imageRatio > canvasRatio {
            size.height = canvas.width / imageRatio
        } else {
            size.width = canvas.height * imageRatio
        }
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func viewPoint(_ normalized: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + normalized.x * frame.width, y: frame.minY + normalized.y * frame.height)
    }

    private func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: Swift.min(Swift.max((point.x - frame.minX) / frame.width, 0), 1),
                y: Swift.min(Swift.max((point.y - frame.minY) / frame.height, 0), 1))
    }

    private func path(_ quad: TicketQuad, in frame: CGRect) -> Path {
        var path = Path()
        let points = quad.corners.map { viewPoint($0, in: frame) }
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// 一张票的框：彩种颜色的描边、淡淡的填充、左上角一块「序号 + 彩种」的牌子。点一下选中。
    private func outline(_ mark: Mark, number: Int, in frame: CGRect) -> some View {
        let shape = path(mark.quad, in: frame)
        let color = Self.color(for: mark.game)
        let isSelected = mark.id == selected
        let corner = viewPoint(mark.quad.topLeft, in: frame)
        return ZStack {
            shape.fill(color.opacity(isSelected ? 0.22 : 0.12))
            shape.stroke(color, style: StrokeStyle(lineWidth: isSelected ? 3 : 2, lineJoin: .round))
            HStack(spacing: 5) {
                if mark.isResolving, mark.game == nil {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.black)
                }
                Text(Self.title(number: number, mark: mark))
                    .font(.caption.weight(.bold))
            }
                .foregroundStyle(mark.game == nil ? Color.black : Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color, in: Capsule())
                .fixedSize()
                .position(x: corner.x + 44, y: Swift.max(corner.y - 14, 14))
        }
        .contentShape(shape)
        .onTapGesture { selected = mark.id }
        .accessibilityElement()
        .accessibilityLabel("第 \(number) 张票，\(mark.game?.label ?? (mark.isResolving ? "识别中" : "没认出彩种"))")
        .accessibilityAddTraits(.isButton)
    }

    /// 选中那个框的一个角。手势挂在 `.position` 之前、坐标取画布坐标 —— 原因见 `TicketCropView.handle`。
    private func handle(mark: Int, corner: Int, in frame: CGRect) -> some View {
        let center = viewPoint(marks[mark].quad[corner], in: frame)
        let isActive = activeCorner == corner
        return Circle()
            .fill(Self.color(for: marks[mark].game))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .frame(width: 26, height: 26)
            .scaleEffect(isActive ? 1.4 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isActive)
            .frame(width: 52, height: 52)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.canvasSpace))
                    .onChanged { value in
                        activeCorner = corner
                        guard marks.indices.contains(mark) else { return }
                        marks[mark].quad[corner] = normalized(value.location, in: frame)
                    }
                    .onEnded { _ in activeCorner = nil }
            )
            .position(center)
    }
}
