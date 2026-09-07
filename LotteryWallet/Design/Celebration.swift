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

/// 中奖彩票卡片上持续的一点光。
///
/// 第一版是六个圆点各自放大淡出，效果很像加载动画 —— 因为圆点放大再消失
/// 正是所有 loading spinner 的语言。烟花之所以是烟花，靠的是**从一点向外
/// 迸开的一簇**，而不是单个点变大。
///
/// 所以这一版改成小而密的一簇：每处四粒火星朝不同方向飞出去，飞的过程中
/// 从亮到暗、从大到小，末尾还带一点下坠。一次只放一处，几处轮着来，
/// 屏幕上永远只有四五粒在动 —— 票夹里同时十几张中奖票也不会拖慢。
///
/// 预算控制得很紧：火星位置是**固定的**（不是每帧随机），动画交给
/// CoreAnimation 的 `repeatForever`，提交一次之后主线程就不再参与。
struct TicketSparkleOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    /// 一簇火星的起爆点。避开卡片正中间 —— 那里压着号码。
    private struct Burst: Identifiable {
        let id: Int
        let x: CGFloat
        let y: CGFloat
        let delay: Double
        let colors: [BallColor]
    }

    private static let bursts: [Burst] = [
        Burst(id: 0, x: 0.10, y: 0.17, delay: 0.0, colors: [.red, .yellow, .k8orange, .plum]),
        Burst(id: 1, x: 0.91, y: 0.30, delay: 1.1, colors: [.blue, .plum, .fc3d, .yellow]),
        Burst(id: 2, x: 0.22, y: 0.85, delay: 2.2, colors: [.yellow, .red, .amber, .blue]),
        Burst(id: 3, x: 0.80, y: 0.80, delay: 3.3, colors: [.plum, .k8orange, .fc3d, .red])
    ]

    /// 四个飞出方向，斜向铺开比正十字更像迸开
    private static let angles: [Double] = [-0.9, -0.25, 0.35, 1.05]
    private static let cycle: Double = 4.4

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Self.bursts) { burst in
                    ForEach(Array(Self.angles.enumerated()), id: \.offset) { index, angle in
                        spark(burst: burst, angle: angle, index: index, in: proxy.size)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // 减弱动效下彻底不画 —— 常驻动画对前庭敏感的人是最难受的一类。
        .opacity(reduceMotion ? 0 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            isAnimating = true
        }
    }

    private func spark(burst: Burst, angle: Double, index: Int, in size: CGSize) -> some View {
        let distance: CGFloat = 13 + CGFloat(index % 2) * 5
        let origin = CGPoint(x: size.width * burst.x, y: size.height * burst.y)
        let color = burst.colors[index % burst.colors.count].accentColor
        return Circle()
            .fill(color)
            .frame(width: 3.4, height: 3.4)
            // 飞出去的同时缩小，末段再往下坠一点点 —— 火星就是这么熄的
            .scaleEffect(isAnimating ? 0.35 : 1.25)
            .opacity(isAnimating ? 0 : 1)
            .offset(x: isAnimating ? cos(angle) * distance : 0,
                    y: isAnimating ? sin(angle) * distance + 5 : 0)
            .position(origin)
            .animation(
                .easeOut(duration: 0.85)
                    .repeatForever(autoreverses: false)
                    // 每处之间隔开一秒多，同一时刻屏幕上只有一簇在飞
                    .delay(burst.delay + Double(index) * 0.05),
                value: isAnimating
            )
    }
}
