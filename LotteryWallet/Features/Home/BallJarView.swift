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
    private static let corner: CGFloat = 22
    private var isActive: Bool { isVisible && scenePhase == .active && !jar.colors.isEmpty }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner)
        VStack(alignment: .leading, spacing: 8) {
            JarBallLayer(scene: scene)
                .frame(height: Self.height)
                .clipShape(shape)
                .background {
                    Color.clear.glassJar(in: shape).background {
                        shape.fill(LinearGradient(
                            colors: [Color(light: 0xECF3F8, dark: 0x26323B),
                                     Color(light: 0xFAFCFD, dark: 0x181F26),
                                     Color(light: 0xE8F0F7, dark: 0x283640)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                    }
                }
                .overlay {
                    JarGlassWall(shape: shape)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
                .accessibilityElement()
                .accessibilityLabel("号码球罐")
                .accessibilityValue("\(range.label)\(summary)")
                .overlay(alignment: .topTrailing) {
                    Button {
                        scene.shake()
                        shakes += 1
                    } label: {
                        Label("摇一摇", systemImage: "wind")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(jar.colors.isEmpty)
                    .accessibilityIdentifier("home.jar.shake")
                    .padding(8)
                }
                .overlay {
                    if jar.colors.isEmpty {
                        Text("这段时间没有命中的号码")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }

            Text(jar.isSampled ? "\(summary) · 示意展示 \(jar.colors.count.formatted()) 颗" : summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("home.jar.total")
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
        scene.load(jar.colors, size: size, corner: Self.corner)
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

/// 玻璃壁用两道间隔的边缘和斜向高光表现厚度。
private struct JarGlassWall: View {
    let shape: RoundedRectangle

    var body: some View {
        shape
            .strokeBorder(LinearGradient(
                colors: [Color(light: 0x99ACC0, dark: 0x607689).opacity(0.60),
                         .white.opacity(0.72), Color(light: 0x8DA5BB, dark: 0x435B71).opacity(0.44)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ), lineWidth: 1)
            .overlay {
                shape.inset(by: 2).strokeBorder(LinearGradient(
                    stops: [.init(color: .white.opacity(0.9), location: 0),
                            .init(color: .white.opacity(0.5), location: 0.25),
                            .init(color: .clear, location: 0.53),
                            .init(color: .white.opacity(0.62), location: 0.95)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 3)
            }
            .overlay {
                shape.inset(by: 5).strokeBorder(Color.primary.opacity(0.055), lineWidth: 1)
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
