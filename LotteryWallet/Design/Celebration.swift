import SwiftUI

/// 中奖庆祝烟花，对齐 web 版核对出中奖时的那一片彩色绽放。
///
/// 动效预算的分配原则（Emil Kowalski / Apple 的说法是同一件事）：
/// 每天要看几百次的东西一律不动效，只有**罕见的、值得庆祝的**时刻才配得上
/// delight。中奖恰好是这一档 —— 一个用户可能几个月才见一次的瞬间。
///
/// 实现上刻意不引第三方粒子库：整个效果就是若干个 `Circle` 在
/// 一次 `withAnimation` 里从中心飞出去，用 `Canvas` 一次性画完，
/// 主线程只提交一次动画。
struct CelebrationView: View {
    /// 每次触发换一个新的 id，用来重启动画。
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bursts: [Burst] = []

    var body: some View {
        ZStack {
            ForEach(bursts) { burst in
                BurstView(burst: burst, reduceMotion: reduceMotion)
            }
        }
        .allowsHitTesting(false)
        .task(id: trigger) {
            guard trigger > 0 else { return }
            bursts = Burst.random()
            // 动画本身 1.5s 左右，留一点余量再清场，避免视图树里挂着死粒子。
            //
            // 这里**不能**用 `try?` 把取消吞掉：两秒内连放两次烟花时，
            // 第一个任务会被取消，但 `try?` 之后它照样往下跑一句 `bursts = []`，
            // 把第二个任务刚摆好的粒子清空 —— 表现就是第二次点了什么都没有。
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            bursts = []
        }
    }
}

/// 一次绽放：一个随机位置、一组随机方向的粒子。
struct Burst: Identifiable {
    let id = UUID()
    /// 相对于容器的位置，0...1。
    let anchor: UnitPoint
    /// 起爆延迟，让几处绽放错开而不是同时炸。
    let delay: Double
    let particles: [Particle]

    struct Particle: Identifiable {
        let id = UUID()
        let color: Color
        /// 飞出的角度（弧度）与距离。
        let angle: Double
        let distance: CGFloat
        let size: CGFloat
    }

    /// 三到四处绽放，位置避开正中间那块通常压着文字的区域。
    static func random() -> [Burst] {
        (0..<Int.random(in: 3...4)).map { index in
            Burst(
                anchor: UnitPoint(x: .random(in: 0.12...0.88),
                                  y: .random(in: 0.14...0.62)),
                // 30–80ms 的错峰，比同时炸开自然得多
                delay: Double(index) * Double.random(in: 0.05...0.13),
                particles: (0..<Int.random(in: 10...14)).map { _ in
                    Particle(
                        color: BallColor.festive.randomElement() ?? .pink,
                        angle: .random(in: 0..<(2 * .pi)),
                        distance: .random(in: 46...104),
                        size: .random(in: 5...9)
                    )
                }
            )
        }
    }
}

private struct BurstView: View {
    let burst: Burst
    let reduceMotion: Bool

    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let origin = CGPoint(x: proxy.size.width * burst.anchor.x,
                                 y: proxy.size.height * burst.anchor.y)
            ZStack {
                ForEach(burst.particles) { particle in
                    Circle()
                        .fill(particle.color)
                        .frame(width: particle.size, height: particle.size)
                        // 从 0.6 起步而不是 0：现实里没有东西是从「无」冒出来的，
                        // 从一个已经看得见的尺寸放大出去才像真的炸开。
                        .scaleEffect(0.6 + progress * 0.4)
                        .opacity(opacity)
                        .position(
                            x: origin.x + cos(particle.angle) * particle.distance * progress,
                            y: origin.y + sin(particle.angle) * particle.distance * progress
                                // 一点点重力，粒子飞到末段会往下坠
                                + 26 * progress * progress
                        )
                }
            }
        }
        .task {
            guard !reduceMotion else {
                // 减弱动效下不做位移，只留一次轻微的淡入淡出
                withAnimation(.easeOut(duration: 0.25)) { progress = 0.12 }
                return
            }
            try? await Task.sleep(for: .seconds(burst.delay))
            // 爆开是一次带冲量的运动：响应快、几乎不回弹，
            // 靠 opacity 收尾而不是让粒子弹回来。
            withAnimation(.spring(duration: 0.9, bounce: 0.18)) { progress = 1 }
        }
    }

    /// 前 20% 全不透明，之后线性淡出。
    private var opacity: Double {
        guard progress > 0.2 else { return 1 }
        return Double(1 - (progress - 0.2) / 0.8)
    }
}

// MARK: - 中奖票上的常驻烟花

/// 中奖彩票卡片上持续绽放的小烟花。
///
/// 前几版都是用 SwiftUI 的视图动画摆圆点：一簇 `Circle` 各自 `offset` 出去再淡出。
/// 结果就是用户说的「像在涂小球」—— 火星匀速滑到终点、同时熄灭，
/// 既没有初速衰减，也没有下坠，读起来是一组滑块而不是一次爆炸。
///
/// 这一版换成 `TimelineView` + `Canvas` 的粒子模拟。差别在于：
///
/// 1. **有物理**。每粒火星带初速，速度按指数阻力衰减，同时叠一个重力加速度 ——
///    所以它是「先冲出去、慢下来、然后往下坠」，这正是真烟花的轮廓。
/// 2. **有拖尾**。同一粒在稍早的两个时刻各画一次、更小更淡，就是拖尾。
/// 3. **每一轮都不一样**。位置、角度、初速、颜色都由
///    （第几朵，第几轮，第几粒）哈希出来，所以第二轮和第一轮长得不同，
///    但完全确定、不需要每帧摇骰子，也不需要任何 @State。
/// 4. **错峰**。三朵的周期是 3.7 / 4.9 / 6.1 秒 —— 刻意取互质的小数，
///    它们的相位永远对不齐，凑不出固定节拍。
///
/// 起爆点允许落在卡片边缘外一点（见 `TicketSparkleOverlay` 的负 padding），
/// 火星可以越出卡片一小截，但幅度控制在十几点以内，不会糊到隔壁卡片上。
struct TicketSparkleOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 允许越出卡片边缘的量。画布比卡片大一圈，火星才能飞出去一点。
    static let overflow: CGFloat = 14

    /// 一朵烟花的静态参数。位置和颜色每一轮再随机，这里只定节拍。
    private struct Shell {
        let period: Double
        /// 首次起爆前的相位偏移，三朵一开始就是错开的。
        let phase: Double
        let count: Int
    }

    private static let shells: [Shell] = [
        Shell(period: 3.7, phase: 0.0, count: 9),
        Shell(period: 4.9, phase: 1.6, count: 8),
        Shell(period: 6.1, phase: 3.1, count: 10)
    ]

    /// 单朵从起爆到熄灭的时长。
    private static let life: Double = 1.35

    var body: some View {
        // 减弱动效下彻底不画。常驻动画对前庭敏感的人是最难受的一类，
        // 这里不是「减小幅度」能解决的，直接不放。
        if reduceMotion {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    draw(in: &context, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Double) {
        // 让不同卡片的烟花也彼此错开：用卡片宽度做一点相位扰动。
        // 否则一屏好几张中奖票会整齐划一地一起炸。
        let skew = Double(size.width).truncatingRemainder(dividingBy: 7.0) * 0.31

        for (shellIndex, shell) in Self.shells.enumerated() {
            let elapsed = now - shell.phase - skew
            let cycle = (elapsed / shell.period).rounded(.down)
            let local = elapsed - cycle * shell.period
            guard local >= 0, local < Self.life else { continue }

            let round = Int(cycle)
            draw(shell: shell,
                 shellIndex: shellIndex,
                 round: round,
                 age: local,
                 in: &context,
                 size: size)
        }
    }

    private func draw(shell: Shell,
                      shellIndex: Int,
                      round: Int,
                      age: Double,
                      in context: inout GraphicsContext,
                      size: CGSize) {
        let pad = Self.overflow
        // 起爆点落在卡片内部靠中间的区域。太贴边的话半朵都在画布外，
        // 看起来像是从旁边飘进来的。
        let origin = CGPoint(
            x: pad + CGFloat(0.14 + 0.72 * rnd(shellIndex, round, 901)) * (size.width - pad * 2),
            y: pad + CGFloat(0.18 + 0.60 * rnd(shellIndex, round, 902)) * (size.height - pad * 2)
        )
        // 整朵的基准半径，让每一轮有大有小
        let power = 0.78 + 0.44 * rnd(shellIndex, round, 903)
        let hueShift = Int(rnd(shellIndex, round, 904) * 8)

        // 起爆瞬间的一点白光。没有这一下，粒子像是凭空出现的。
        if age < 0.10 {
            let flash = 1 - age / 0.10
            let radius = 3.0 + 5.0 * flash
            context.fill(
                Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(0.55 * flash))
            )
        }

        for particle in 0..<shell.count {
            // 角度不均分：均分看着像齿轮
            let base = Double(particle) / Double(shell.count) * 2 * .pi
            let angle = base + (rnd(shellIndex, round, particle) - 0.5) * 0.9
            let speed = (62.0 + 46.0 * rnd(shellIndex, round, particle + 200)) * power
            let color = BallColor.festive[(particle + shellIndex * 3 + hueShift) % BallColor.festive.count]
            let scale = 0.72 + 0.55 * rnd(shellIndex, round, particle + 400)

            // 拖尾：同一粒在稍早的两个时刻再画一次，更小更淡
            for (step, trail) in [(0.0, 1.0), (0.055, 0.42), (0.11, 0.18)] {
                let t = age - step
                guard t > 0 else { continue }
                let point = position(origin: origin, angle: angle, speed: speed, t: t)
                guard let alpha = fade(age: t, particle: particle), alpha > 0.02 else { continue }
                let radius = (1.5 + 2.1 * scale) * (1 - 0.45 * t / Self.life) * (0.55 + 0.45 * trail)
                guard radius > 0.2 else { continue }
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                           width: radius * 2, height: radius * 2)),
                    with: .color(color.opacity(alpha * trail))
                )
            }
        }
    }

    /// 位移 = 初速在指数阻力下的积分 + 重力。
    ///
    /// 阻力项 `v0 * (1 - e^{-kt}) / k` 让火星冲出去之后迅速慢下来，
    /// 而不是匀速滑到终点 —— 这一项是「涂小球」和「炸开」的分界线。
    /// 重力项让末段自然下坠。
    private func position(origin: CGPoint, angle: Double, speed: Double, t: Double) -> CGPoint {
        let drag = 3.1
        let travel = speed * (1 - exp(-drag * t)) / drag
        let gravity = 96.0
        return CGPoint(
            x: origin.x + CGFloat(cos(angle) * travel),
            y: origin.y + CGFloat(sin(angle) * travel + 0.5 * gravity * t * t)
        )
    }

    /// 亮度：整体按寿命淡出，叠一层高频闪烁，火星才有「余烬」的质感。
    private func fade(age: Double, particle: Int) -> Double? {
        guard age < Self.life else { return nil }
        let remain = 1 - age / Self.life
        let base = pow(remain, 1.7)
        let twinkle = 0.78 + 0.22 * sin(age * 19 + Double(particle) * 1.7)
        return base * twinkle
    }

    /// 由「第几朵 / 第几轮 / 第几粒」确定地哈希出一个 0..<1 的数。
    ///
    /// 用哈希而不是 `Double.random`：Canvas 每帧都会重画，随机数必须
    /// 对同一粒火星在整段寿命里保持一致，否则它每帧都会跳到别处。
    private func rnd(_ a: Int, _ b: Int, _ c: Int) -> Double {
        var x = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663 ^ c &* 83_492_791))
        x ^= x >> 33
        x = x &* 0xFF51_AFD7_ED55_8CCD
        x ^= x >> 33
        x = x &* 0xC4CE_B9FE_1A85_EC53
        x ^= x >> 33
        return Double(x % 100_000) / 100_000.0
    }
}
