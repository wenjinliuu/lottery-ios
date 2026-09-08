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
/// 三版才调对：
/// - 第一版圆点原地放大淡出 —— 那是 loading spinner 的语言，不是烟花。
/// - 第二版改成从一点迸开的一簇，方向对了，但四处同时放、又快又小，
///   看上去像静电噪点。
///
/// 这一版：
/// 1. **有先后**。四朵各自独立，起爆时刻错开，而且每朵的间歇长短不同 ——
///    它们会慢慢互相错开，永远凑不出一个固定的节拍。这就是「随机」的来源，
///    而不是每帧摇一次骰子（那样很贵）。
/// 2. **慢下来、放大**。单朵绽放 1.5 秒（原来 0.85），火星最大 5pt
///    （原来 3.4），飞得也更远。慢和大才看得清是在「绽开」。
/// 3. 一朵放完要静默好几秒。任何时刻屏幕上通常只有一朵在动。
///
/// 时序用 `phaseAnimator` 表达：**等待 → 亮起 → 飞散**三相循环。
/// `repeatForever` 做不到这件事 —— 它的周期就是动画本身的时长，
/// 加 delay 只是推迟第一次，之后每 1.5 秒还是会重放一遍，四朵立刻挤在一起。
struct TicketSparkleOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 一朵烟花：起爆点、起爆时刻、间歇、颜色和五粒火星各自的方向。
    private struct Burst: Identifiable {
        let id: Int
        let x: CGFloat
        let y: CGFloat
        /// 第一次起爆前等多久。
        let delay: Double
        /// 两次起爆之间的静默。刻意各不相同，好让四朵慢慢错开。
        let rest: Double
        let colors: [BallColor]
        /// 五粒火星的角度（弧度）。刻意不均分 —— 均分看着像齿轮。
        let angles: [Double]
        let spread: CGFloat
    }

    private static let burstDuration: Double = 1.5

    private static let bursts: [Burst] = [
        Burst(id: 0, x: 0.11, y: 0.20, delay: 0.2, rest: 4.7,
              colors: [.red, .yellow, .k8orange],
              angles: [-2.5, -1.5, -0.4, 0.7, 2.0], spread: 26),
        Burst(id: 1, x: 0.89, y: 0.30, delay: 1.7, rest: 5.3,
              colors: [.blue, .plum, .fc3d],
              angles: [-2.9, -1.9, -0.8, 0.5, 2.4], spread: 22),
        Burst(id: 2, x: 0.24, y: 0.83, delay: 3.4, rest: 4.9,
              colors: [.yellow, .amber, .red],
              angles: [-2.2, -1.1, 0.2, 1.4, 2.7], spread: 28),
        Burst(id: 3, x: 0.78, y: 0.78, delay: 5.1, rest: 5.8,
              colors: [.plum, .k8orange, .blue],
              angles: [-2.7, -1.3, 0.0, 1.1, 2.2], spread: 24)
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Self.bursts) { burst in
                    BurstCluster(burst: burst, size: proxy.size, duration: Self.burstDuration)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // 减弱动效下彻底不画 —— 常驻动画对前庭敏感的人是最难受的一类。
        .opacity(reduceMotion ? 0 : 1)
    }

    /// 一朵。等到 `delay` 之后才开始循环，四朵的起点因此错开。
    private struct BurstCluster: View {
        let burst: Burst
        let size: CGSize
        let duration: Double

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isLive = false

        var body: some View {
            ZStack {
                if isLive {
                    ForEach(Array(burst.angles.enumerated()), id: \.offset) { index, angle in
                        spark(angle: angle, index: index)
                    }
                }
            }
            .task {
                guard !reduceMotion else { return }
                try? await Task.sleep(for: .seconds(burst.delay))
                isLive = true
            }
        }

        private func spark(angle: Double, index: Int) -> some View {
            // 同一朵里每粒飞得远近不同，看起来才是炸开而不是齐步走
            let distance = burst.spread * (0.62 + CGFloat(index % 3) * 0.19)
            let diameter: CGFloat = 5 - CGFloat(index % 2) * 1.1
            let origin = CGPoint(x: size.width * burst.x, y: size.height * burst.y)
            let color = burst.colors[index % burst.colors.count].accentColor

            return Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .position(origin)
                // 0 = 静默（不可见）、1 = 亮起、2 = 飞散
                .phaseAnimator([0, 1, 2]) { view, phase in
                    view
                        // 从看得见的大小起步再缩小 —— 现实里没有东西是从「无」冒出来的
                        .scaleEffect(phase == 2 ? 0.3 : 1.15)
                        .opacity(phase == 1 ? 1 : 0)
                        .offset(x: phase == 2 ? cos(angle) * distance : 0,
                                // 末段带一点下坠，火星就是这么熄的
                                y: phase == 2 ? sin(angle) * distance + 7 : 0)
                } animation: { phase in
                    switch phase {
                    case 1: .linear(duration: 0.01)      // 亮起：瞬间
                    case 2: .easeOut(duration: duration) // 飞散
                    // 回到静默：这一段全程不可见，长短决定了两朵之间的间歇。
                    // 同一朵里五粒的间歇差一点点，下一轮的形状就会不一样。
                    default: .linear(duration: burst.rest + Double(index) * 0.07)
                    }
                }
        }
    }
}
