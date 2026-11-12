import CoreMotion
import SwiftUI

/// 号码球罐：买过的号码装在一个罐子里，跟着手机的重力滚。
///
/// - 颜色跟彩种（号码区）走。**淡色**是买了没开出的，**实心**是开出了的。
/// - 中奖那一注里命中的号单独一颗、写着号码、带金圈；按那一注的奖金分三档，档越高圈越亮、球越大。
/// - 右上角的按钮像摇号机那样从底下吹一阵。
///
/// 放什么球见 `JarBuilder`，球怎么动见 `JarPhysics`。
struct BallJarView: View {
    let jar: JarBuilder.Jar
    @Binding var scope: JarScope
    /// 有数据的年份，新的在前。
    let years: [Int]

    @State private var scene = JarScene()
    @State private var shakes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    static let height: CGFloat = 230

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .top) {
                TimelineView(.animation(paused: scenePhase != .active)) { timeline in
                    Canvas { context, size in
                        scene.load(jar, size: size, settled: reduceMotion || DemoData.isEnabled)
                        scene.advance(to: timeline.date)
                        scene.draw(in: &context, time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
                .frame(height: Self.height)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityElement()
                .accessibilityLabel("号码球罐")
                .accessibilityValue(summary)

                HStack {
                    scopeMenu
                    Spacer(minLength: 0)
                    Button {
                        scene.physics.blow()
                        shakes += 1
                    } label: {
                        Label("摇一摇", systemImage: "wind")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(jar.beads.isEmpty)
                    .accessibilityIdentifier("home.jar.shake")
                }
                .padding(8)

                if jar.beads.isEmpty {
                    Text("这一段还没有开过奖的号码")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.height)
                }
            }
            legend
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: shakes)
        .onAppear { scene.startMotion() }
        .onDisappear { scene.stopMotion() }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: "全部"
        case .year(let year): "\(String(year)) 年"
        }
    }

    private var scopeMenu: some View {
        Menu {
            Picker("看哪一罐", selection: $scope) {
                Text("全部").tag(JarScope.all)
                ForEach(years, id: \.self) { year in
                    Text("\(String(year)) 年").tag(JarScope.year(year))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(scopeTitle)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.jar.scope")
    }

    private var summary: String {
        var text = "\(scopeTitle)共 \(jar.total) 个号码"
        if jar.wins > 0 { text += "，中奖球 \(jar.wins) 颗" }
        return text
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                sample("没开出", fill: Color.accentColor.opacity(0.22), stroke: Color.accentColor.opacity(0.45))
                sample("开出了", fill: Color.accentColor, stroke: .clear)
                sample("中奖的号", fill: Color.accentColor, stroke: JarScene.gold)
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        var parts = ["共 \(jar.total) 个号码"]
        if jar.per > 1 { parts.append("一颗小珠 ≈ \(jar.per) 个") }
        if jar.wins > 0 { parts.append("中奖球 \(jar.wins) 颗，奖金越高越大越亮") }
        return parts.joined(separator: " · ")
    }

    private func sample(_ title: String, fill: Color, stroke: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(stroke, lineWidth: 1.5))
                .frame(width: 10, height: 10)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// 罐子的现场：球、物理、重力感应。放在类里是因为每一帧都要改它，而画面不需要为此重排。
final class JarScene {
    static let gold = Color(hex: 0xF5B82E)

    var physics = JarPhysics()
    private var beads: [JarBead] = []
    private var loaded: JarBuilder.Jar?
    private var size = CGSize.zero
    private var last: Date?
    private let motion = CMMotionManager()
    /// 停稳时的重力方向。手机动了才把球叫醒。
    private var restGravity = (x: 0.0, y: 1.0)

    /// 小珠子的半径：罐子装满（容量颗小珠加上限颗中奖球）时正好铺满。
    static func beadRadius(size: CGSize) -> Double {
        let slots = Double(JarBuilder.capacity) + Double(JarBuilder.winLimit) * 3
        return (Double(size.width * size.height) * 0.8 / (Double.pi * slots)).squareRoot()
    }

    static func scale(_ kind: JarBead.Kind) -> Double {
        switch kind {
        case .miss, .hit: 1
        case .win(.small): 1.7
        case .win(.medium): 2.0
        case .win(.big): 2.4
        }
    }

    func load(_ jar: JarBuilder.Jar, size: CGSize, settled: Bool) {
        guard jar != loaded || size != self.size, size.width > 0, size.height > 0 else { return }
        loaded = jar
        self.size = size
        beads = jar.beads
        let base = Self.beadRadius(size: size)
        physics.fill(radii: beads.map { base * Self.scale($0.kind) },
                     width: size.width, height: size.height, settled: settled)
        last = nil
    }

    func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates()
    }

    func stopMotion() {
        motion.stopDeviceMotionUpdates()
    }

    func advance(to date: Date) {
        defer { last = date }
        if let gravity = motion.deviceMotion?.gravity {
            // 设备坐标：x 向右、y 向上；画布的 y 向下
            physics.gravityX = gravity.x * 1400
            physics.gravityY = -gravity.y * 1400
            if abs(gravity.x - restGravity.x) + abs(-gravity.y - restGravity.y) > 0.12 { physics.wake() }
            if !physics.isResting { restGravity = (gravity.x, -gravity.y) }
        }
        guard let last, !physics.isResting else { return }
        // 掉帧时不追着补算：最多补两步
        let steps = min(max(Int((date.timeIntervalSince(last) * 60).rounded()), 1), 2)
        for _ in 0..<steps { physics.step(1.0 / 60) }
    }

    func draw(in context: inout GraphicsContext, time: Double) {
        let balls = physics.balls
        guard balls.count == beads.count else { return }
        // 先画小珠子，中奖球压在上面
        for pass in 0..<2 {
            for (index, bead) in beads.enumerated() {
                let ball = balls[index]
                let rect = CGRect(x: ball.x - ball.radius, y: ball.y - ball.radius,
                                  width: ball.radius * 2, height: ball.radius * 2)
                switch bead.kind {
                case .miss where pass == 0:
                    let path = Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5))
                    context.fill(path, with: .color(bead.color.accentColor.opacity(0.2)))
                    context.stroke(path, with: .color(bead.color.accentColor.opacity(0.42)), lineWidth: 0.8)
                case .hit where pass == 0:
                    context.fill(Path(ellipseIn: rect.insetBy(dx: 0.3, dy: 0.3)), with: shading(bead.color, rect))
                case .win(let tier) where pass == 1:
                    drawWinner(bead, tier: tier, rect: rect, phase: Double(index) * 0.9, time: time, in: &context)
                default:
                    break
                }
            }
        }
    }

    private func shading(_ color: BallColor, _ rect: CGRect) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [color.light, color.deep]),
                        startPoint: CGPoint(x: rect.minX, y: rect.minY),
                        endPoint: CGPoint(x: rect.maxX, y: rect.maxY))
    }

    /// 中奖球：彩种色的球面、白色号码，外面一圈会转的金色光泽。
    /// 三档的区别在圈的粗细、有没有光晕、带几颗闪烁的星。
    private func drawWinner(_ bead: JarBead, tier: JarTier, rect: CGRect, phase: Double, time: Double,
                            in context: inout GraphicsContext) {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = Double(rect.width / 2)
        let ring: Double = tier == .big ? 3 : (tier == .medium ? 2.3 : 1.7)

        if tier == .big {
            // 光晕一呼一吸
            let breath = 0.45 + 0.25 * sin(time * 2.2 + phase)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 5))
                layer.fill(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(Self.gold.opacity(breath)))
            }
        }
        context.fill(Path(ellipseIn: rect.insetBy(dx: ring * 0.6, dy: ring * 0.6)), with: shading(bead.color, rect))

        // 金圈：一圈深浅相间的金色绕着转，亮的那一段扫过去就是「闪」
        let speed = tier == .small ? 0.7 : 1.5
        let sheen = Gradient(colors: [Color(hex: 0xFFF6D6), Self.gold, Color(hex: 0xC98A12), Self.gold,
                                      Color(hex: 0xFFFBEA), Self.gold, Color(hex: 0xC98A12), Color(hex: 0xFFF6D6)])
        context.stroke(Path(ellipseIn: rect.insetBy(dx: ring / 2, dy: ring / 2)),
                       with: .conicGradient(sheen, center: centre, angle: .radians(time * speed + phase)),
                       lineWidth: ring)

        if let label = bead.label {
            let text = Text(label)
                .font(.system(size: radius * 0.92, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            context.draw(text, at: centre)
        }

        // 星：中档一颗，高档两颗，各闪各的
        let stars = tier == .big ? 2 : (tier == .medium ? 1 : 0)
        for star in 0..<stars {
            let angle = star == 0 ? -Double.pi / 4 : Double.pi * 0.8
            let twinkle = 0.5 + 0.5 * sin(time * 3.1 + phase + Double(star) * 2.1)
            let at = CGPoint(x: centre.x + cos(angle) * radius * 0.92, y: centre.y + sin(angle) * radius * 0.92)
            let reach = radius * (star == 0 ? 0.5 : 0.36) * (0.55 + 0.45 * twinkle)
            context.fill(Self.sparkle(at: at, reach: reach), with: .color(.white.opacity(0.55 + 0.45 * twinkle)))
        }
    }

    /// 四角星。
    static func sparkle(at point: CGPoint, reach: Double) -> Path {
        var path = Path()
        let waist = reach * 0.22
        for corner in 0..<4 {
            let angle = Double(corner) * .pi / 2
            let tip = CGPoint(x: point.x + cos(angle) * reach, y: point.y + sin(angle) * reach)
            let side = CGPoint(x: point.x + cos(angle + .pi / 4) * waist, y: point.y + sin(angle + .pi / 4) * waist)
            if corner == 0 { path.move(to: tip) } else { path.addLine(to: tip) }
            path.addLine(to: side)
        }
        path.closeSubpath()
        return path
    }
}
