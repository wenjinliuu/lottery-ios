import CoreMotion
import Observation
import SwiftUI

struct BallJarView: View {
    let jar: JarBuilder.Jar
    let range: ProfitRange

    @State private var scene = JarScene()
    @State private var size = CGSize.zero
    @State private var isVisible = false
    @State private var shakes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    static let height: CGFloat = 230
    private static let corner: CGFloat = 28
    private static let wallWidth: CGFloat = 6
    private static let rimInset: CGFloat = 11
    private static let baseInset: CGFloat = 7
    private static let innerCorner = corner - wallWidth
    private var isActive: Bool { isVisible && scenePhase == .active && !jar.colors.isEmpty }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner)
        VStack(alignment: .leading, spacing: 8) {
            JarBallLayer(scene: scene)
                .frame(height: Self.height - Self.rimInset - Self.baseInset)
                .clipShape(RoundedRectangle(cornerRadius: Self.innerCorner))
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
                .padding(.horizontal, Self.wallWidth)
                .padding(.top, Self.rimInset)
                .padding(.bottom, Self.baseInset)
                .clipShape(shape)
                .background {
                    shape.fill(LinearGradient(
                        stops: [.init(color: Color(light: 0xDDE9F1, dark: 0x273744), location: 0),
                                .init(color: Color(light: 0xF8FAFB, dark: 0x172129), location: 0.56),
                                .init(color: Color(light: 0xCBDCE8, dark: 0x344652), location: 1)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                }
                .overlay {
                    JarGlassWall(shape: shape)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .accessibilityElement()
                .accessibilityLabel("号码球罐")
                .accessibilityValue("\(range.label)\(summary)")
                .overlay {
                    if jar.colors.isEmpty {
                        Text("这段时间没有命中的号码")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                Text(jar.isSampled ? "\(summary) · 示意展示 \(jar.colors.count.formatted()) 颗" : summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("home.jar.total")
                Button {
                    scene.shake()
                    shakes += 1
                } label: {
                    Label("摇一摇", systemImage: "wind")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassPill()
                }
                .buttonStyle(.plain)
                .disabled(jar.colors.isEmpty)
                .accessibilityIdentifier("home.jar.shake")
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: shakes)
        .onChange(of: jar, initial: true) { _, _ in load() }
        .onChange(of: size) { _, _ in load() }
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
        .onChange(of: isActive && !reduceMotion, initial: true) { _, active in
            if active && !DemoData.isEnabled { scene.startMotion() }
            else { scene.stopMotion() }
        }
        .onDisappear { scene.stopMotion() }
        .task(id: isActive && scene.isAnimating) {
            guard isActive, scene.isAnimating else { return }
            let clock = ContinuousClock()
            var nextFrame = clock.now
            while !Task.isCancelled && scene.isAnimating {
                scene.advance()
                nextFrame = max(nextFrame + .microseconds(16_667), clock.now)
                try? await clock.sleep(until: nextFrame)
            }
        }
    }

    private var summary: String { "命中 \(jar.hits.formatted()) 个号码" }

    private func load() {
        scene.load(jar.colors, size: size, corner: Self.innerCorner)
    }
}

private struct JarBallLayer: View {
    let scene: JarScene

    var body: some View {
        let frame = scene.frame
        return Canvas { context, _ in
            scene.draw(in: &context, frame: frame)
        }
    }
}

/// 罐口、前壁和厚底都在号码球前面。
private struct JarGlassWall: View {
    let shape: RoundedRectangle

    var body: some View {
        ZStack {
            shape.strokeBorder(Color(light: 0x8CA3B5, dark: 0x647F93).opacity(0.62), lineWidth: 1)
            shape.inset(by: 2).strokeBorder(LinearGradient(
                stops: [.init(color: .white.opacity(0.9), location: 0),
                        .init(color: .white.opacity(0.5), location: 0.28),
                        .init(color: .clear, location: 0.52),
                        .init(color: .white.opacity(0.65), location: 1)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ), lineWidth: 4)
            shape.inset(by: 5).strokeBorder(Color(light: 0x7892A6, dark: 0x9DB7CA).opacity(0.22), lineWidth: 2)

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 13)
                    .glassJarRim()
                    .overlay {
                        Ellipse().strokeBorder(LinearGradient(
                            colors: [.white.opacity(0.94), Color(light: 0x7F98AC, dark: 0x9FB6C8).opacity(0.7)],
                            startPoint: .top, endPoint: .bottom
                        ), lineWidth: 1)
                    }
                    .padding(.horizontal, 15)
                    .padding(.top, 3)
                Spacer(minLength: 0)
                Capsule()
                    .fill(LinearGradient(
                        stops: [.init(color: .clear, location: 0),
                                .init(color: Color(light: 0xA9C1D2, dark: 0x648296).opacity(0.42), location: 0.47),
                                .init(color: .white.opacity(0.72), location: 0.72),
                                .init(color: Color(light: 0x7494AC, dark: 0x486379).opacity(0.55), location: 1)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(height: 16)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
            }
        }
    }
}

@MainActor @Observable
final class JarScene {
    private(set) var frame = 0
    private(set) var isAnimating = false
    @ObservationIgnored private var physics = JarPhysics()
    @ObservationIgnored private var colors: [BallColor] = []
    @ObservationIgnored private var sprites: [BallColor: Image] = [:]
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var restGravity = (x: 0.0, y: 1.0)

    func load(_ colors: [BallColor], size: CGSize, corner: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        self.colors = colors
        for color in Set(colors) where sprites[color] == nil {
            let renderer = ImageRenderer(content: BallSurface(color: color).frame(width: 24, height: 24))
            renderer.scale = 3
            if let image = renderer.uiImage { sprites[color] = Image(uiImage: image) }
        }
        physics.corner = corner
        let radius = JarBuilder.radius(count: colors.count, width: size.width, height: size.height)
        physics.fillPacked(count: colors.count, radius: radius, width: size.width, height: size.height)
        restGravity = (0, 1)
        physics.gravityX = 0
        physics.gravityY = 1400
        isAnimating = false
        frame &+= 1
    }

    func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            guard let gravity = sample?.gravity else { return }
            let x = gravity.x
            let y = -gravity.y
            Task { @MainActor in self?.updateGravity(x: x, y: y) }
        }
    }

    func stopMotion() { motion.stopDeviceMotionUpdates() }

    private func updateGravity(x: Double, y: Double) {
        guard motion.isDeviceMotionActive, !colors.isEmpty else { return }
        physics.gravityX = x * 1400
        physics.gravityY = y * 1400
        if !isAnimating && abs(x - restGravity.x) + abs(y - restGravity.y) > 0.12 {
            physics.wake()
            isAnimating = true
        }
    }

    func shake() {
        guard !colors.isEmpty else { return }
        physics.blow()
        isAnimating = true
    }

    func advance() {
        if !physics.isResting { physics.step(1.0 / 60) }
        if physics.isResting {
            restGravity = (physics.gravityX / 1400, physics.gravityY / 1400)
            isAnimating = false
        }
        frame &+= 1
    }

    func draw(in context: inout GraphicsContext, frame _: Int) {
        let resolved = sprites.mapValues { context.resolve($0) }
        for (color, ball) in zip(colors, physics.balls) {
            let diameter = ball.radius * 2
            let rect = CGRect(x: ball.x - ball.radius, y: ball.y - ball.radius,
                              width: diameter, height: diameter).insetBy(dx: 0.25, dy: 0.25)
            if let sprite = resolved[color] {
                context.draw(sprite, in: rect)
            } else {
                context.fill(Path(ellipseIn: rect), with: .linearGradient(
                    Gradient(colors: [color.light, color.deep]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                ))
            }
        }
    }
}
