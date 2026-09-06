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
/// 和 `CelebrationView` 的区别是「一次性」对「常驻」：那个是核出中奖的
/// 那一瞬间放一次的大场面，这个是留在票上的一点持续的光。
///
/// 预算控制得很紧，因为票夹里可能同时有十几张中奖票在画：
/// 粒子位置是**固定的**（不是每帧随机），动画交给 CoreAnimation 的
/// `repeatForever`，提交一次之后主线程就不再参与。
struct TicketSparkleOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    /// 固定的绽放点。避开卡片正中间 —— 那里压着号码。
    private struct Spark: Identifiable {
        let id: Int
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let delay: Double
        let color: BallColor
    }

    private static let sparks: [Spark] = [
        Spark(id: 0, x: 0.09, y: 0.16, size: 6, delay: 0.00, color: .red),
        Spark(id: 1, x: 0.93, y: 0.24, size: 5, delay: 0.45, color: .yellow),
        Spark(id: 2, x: 0.24, y: 0.86, size: 5, delay: 0.90, color: .blue),
        Spark(id: 3, x: 0.78, y: 0.78, size: 7, delay: 1.35, color: .plum),
        Spark(id: 4, x: 0.52, y: 0.07, size: 5, delay: 1.80, color: .k8orange),
        Spark(id: 5, x: 0.05, y: 0.55, size: 5, delay: 2.25, color: .amber)
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Self.sparks) { spark in
                    Circle()
                        .fill(spark.color.accentColor)
                        .frame(width: spark.size, height: spark.size)
                        .scaleEffect(isAnimating ? 1.9 : 0.35)
                        .opacity(isAnimating ? 0 : 0.95)
                        .position(x: proxy.size.width * spark.x,
                                  y: proxy.size.height * spark.y)
                        .animation(
                            .easeOut(duration: 1.5)
                                .repeatForever(autoreverses: false)
                                .delay(spark.delay),
                            value: isAnimating
                        )
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
}
