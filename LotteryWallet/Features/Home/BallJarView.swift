import CoreMotion
import Observation
import SwiftUI

struct BallJarView: View {
    let jar: JarBuilder.Jar
    let periodLabel: String
    var height: CGFloat = BallJarView.defaultHeight

    @State private var scene = JarScene()
    @State private var size = CGSize.zero
    @State private var isVisible = false
    @State private var shakes = 0
    @State private var touches = 0
    @State private var fingerPoint: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var hasDragged = false
    @State private var lastDragSample: (point: CGPoint, time: Date)?
    @State private var isBreakdownPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    static let height: CGFloat = 220
    static let defaultHeight: CGFloat = 220
    static let minHeight: CGFloat = 180
    static let maxHeight: CGFloat = 236
    private static let corner: CGFloat = 28
    private static let frameWidth: CGFloat = 7
    private var isActive: Bool { isVisible && scenePhase == .active && jar.hits > 0 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            jarHeaderBar

            JarBallLayer(scene: scene)
                .frame(height: height)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
                // 罐内完全透明，直接透出 App 主画布，只保留清透玻璃边框与罐口镜面高光。
                .background(Color.clear)
                .clipShape(shape)
                .overlay {
                    if let point = fingerPoint {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.14),
                                        .clear
                                    ],
                                    center: .center,
                                    startRadius: 2,
                                    endRadius: 42
                                )
                            )
                            .frame(width: 84, height: 84)
                            .position(point)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    // 玻璃罐口一道轻盈的镜面高光弧，增强通透器皿感。
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(colorScheme == .dark ? 0.16 : 0.72),
                                    .white.opacity(0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: 4)
                        .padding(.horizontal, 28)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay {
                    Color.clear
                        .ballGlassFrame(cornerRadius: Self.corner, width: Self.frameWidth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [Color.white.opacity(0.20), Color.white.opacity(0.08)]
                                    : [Color.black.opacity(0.07), Color.black.opacity(0.11)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .contentShape(shape)
                // 无需长按等待：手指轻点立刻激起波纹弹跳，手指滑入罐内直接 0 延迟跟手拨动小球。
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard jar.hits > 0 else { return }
                            let now = Date()
                            let location = value.location
                            if dragStart == nil {
                                dragStart = location
                                hasDragged = false
                                lastDragSample = (location, now)
                                fingerPoint = location
                                return
                            }
                            fingerPoint = location
                            if let start = dragStart, !hasDragged {
                                let distance = hypot(location.x - start.x, location.y - start.y)
                                if distance > 4 {
                                    hasDragged = true
                                    touches += 1
                                }
                            }
                            if hasDragged, let previous = lastDragSample {
                                let dt = max(now.timeIntervalSince(previous.time), 1.0 / 120.0)
                                let vx = (location.x - previous.point.x) / dt
                                let vy = (location.y - previous.point.y) / dt
                                scene.stir(at: location, velocity: CGSize(width: vx, height: vy))
                            }
                            lastDragSample = (location, now)
                        }
                        .onEnded { value in
                            if jar.hits > 0 && !hasDragged {
                                scene.poke(at: value.location)
                                touches += 1
                            }
                            withAnimation(.easeOut(duration: 0.18)) {
                                fingerPoint = nil
                            }
                            dragStart = nil
                            hasDragged = false
                            lastDragSample = nil
                        }
                )
                .accessibilityElement()
                .accessibilityLabel("号码球罐")
                .accessibilityIdentifier("home.jar.frame")
                .accessibilityValue("\(periodLabel)\(summary)")
                .overlay {
                    if jar.hits == 0 {
                        Text("这段时间没有命中的号码")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: shakes)
        .sensoryFeedback(.impact(weight: .light), trigger: touches)
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

    /// 罐口正上方的一行液态玻璃控制条：左为可点击的命中统计胶囊（弹出彩种/球区分布玻璃卡），
    /// 右为悬浮液态玻璃「摇一摇」按钮。
    private var jarHeaderBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    isBreakdownPresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        colorDots
                        Text(totalCaption)
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        if jar.hits > 0 {
                            Image(systemName: "chevron.down")
                                .scaledFont(9, weight: .bold)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .frame(minHeight: 32)
                    .glassPill(interactive: jar.hits > 0)
                    .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(PressableIcon())
                .disabled(jar.hits == 0)
                .accessibilityIdentifier("home.jar.total")
                .accessibilityLabel(totalCaption)
                .accessibilityHint(jar.hits > 0 ? "轻点查看各彩种与号码球命中分布" : "")
                .popover(isPresented: $isBreakdownPresented,
                         attachmentAnchor: .rect(.bounds),
                         arrowEdge: .top) {
                    JarBreakdownCard(jar: jar, visibleCount: visibleCount, periodLabel: periodLabel)
                        .presentationCompactAdaptation(.popover)
                }

                Spacer(minLength: 4)

                Button {
                    scene.shake()
                    shakes += 1
                } label: {
                    Label("摇一摇", systemImage: "wind")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(jar.hits > 0 ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .frame(minHeight: 32)
                        .glassPill(tint: jar.hits > 0 ? Color.accentColor : nil, interactive: jar.hits > 0)
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(PressableIcon())
                .disabled(jar.hits == 0)
                .accessibilityIdentifier("home.jar.shake")
            }
        }
    }

    @ViewBuilder
    private var colorDots: some View {
        let top = jar.topColors(limit: 3)
        if !top.isEmpty {
            HStack(spacing: -3) {
                ForEach(top, id: \.self) { color in
                    BallSurface(color: color)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Palette.canvas, lineWidth: 1))
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var summary: String { "命中 \(jar.hits.formatted()) 个号码" }

    /// 胶囊只显示真实命中总数，保持整洁不拥挤；超过 1,000 颗的按比例示意说明收进点击弹出的分布明细卡中。
    private var totalCaption: String { summary }

    private var visibleCount: Int { min(jar.hits, JarBuilder.capacity(width: size.width, height: size.height)) }

    private func load() {
        scene.load(jar.colors(limit: visibleCount), size: size, corner: Self.corner)
    }
}

/// 点击命中数胶囊弹出的液态玻璃分布明细卡：按彩种和号码球区（红球/蓝球/前区/后区等）展示真实命中数。
struct JarBreakdownCard: View {
    let jar: JarBuilder.Jar
    let visibleCount: Int
    let periodLabel: String

    @Environment(\.dismiss) private var dismiss

    private var isScaled: Bool { visibleCount > 0 && visibleCount < jar.hits }
    private var scaledByZone: [String: Int] {
        isScaled ? jar.scaledZoneCounts(limit: visibleCount) : [:]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("命中号码分布")
                        .font(.headline)
                    Text(isScaled
                         ? "\(periodLabel) · 共 \(jar.hits.formatted()) 颗 · 示意 \(visibleCount.formatted()) 颗"
                         : "\(periodLabel) · 共 \(jar.hits.formatted()) 颗")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭分布")
                .accessibilityIdentifier("home.jar.breakdown.close")
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if jar.breakdown.isEmpty {
                        fallbackColorRows
                    } else {
                        ForEach(jar.breakdown) { group in
                            gameSection(group)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(16)
        .frame(width: 292)
    }

    private func gameSection(_ group: JarBuilder.GameBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(group.game.tint)
                    .frame(width: 7, height: 7)
                Text(group.game.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(group.game.accent.accentColor)
                Spacer(minLength: 8)
                Text("\(group.hits.formatted()) 颗")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(group.zones) { zone in
                    zoneRow(zone)
                }
            }
        }
    }

    private func zoneRow(_ zone: JarBuilder.ZoneBreakdown) -> some View {
        let share = jar.hits > 0 ? Double(zone.hits) / Double(jar.hits) : 0
        let shown = scaledByZone[zone.id]
        return HStack(spacing: 8) {
            BallSurface(color: zone.color)
                .frame(width: 14, height: 14)
            Text(zone.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 42, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(zone.color.gradient)
                        .frame(width: zone.hits > 0 ? max(proxy.size.width * share, 4) : 0)
                }
            }
            .frame(height: 6)

            HStack(spacing: 4) {
                Text("\(zone.hits.formatted())")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if let shown, isScaled {
                    Text("(\(shown))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: "%.0f%%", share * 100))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                }
            }
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(zone.game.label)\(zone.label)，命中 \(zone.hits) 颗")
    }

    private var fallbackColorRows: some View {
        let ordered = jar.counts.sorted { $0.value > $1.value }
        return VStack(spacing: 8) {
            ForEach(ordered, id: \.key) { color, count in
                HStack(spacing: 8) {
                    BallSurface(color: color)
                        .frame(width: 14, height: 14)
                    Text(color.rawValue)
                        .font(.caption)
                    Spacer()
                    Text("\(count.formatted()) 颗")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
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

    func poke(at point: CGPoint) {
        guard !colors.isEmpty else { return }
        physics.poke(at: point.x, y: point.y)
        isAnimating = true
    }

    func stir(at point: CGPoint, velocity: CGSize) {
        guard !colors.isEmpty else { return }
        physics.stir(at: point.x, y: point.y, vx: velocity.width, vy: velocity.height)
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
