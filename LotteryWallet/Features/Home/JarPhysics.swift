import Foundation

/// 号码球罐里的小球怎么动。纯计算，不碰界面。
///
/// 做法是「先挪位置、再解约束」（position based dynamics）：每一步先按速度和重力把球挪过去，
/// 然后反复把叠在一起的球推开、把出了罐子的球推回来，最后用挪动的距离反推速度。
/// 这种做法不会越算越炸，三四百个球堆在一起也稳。
struct JarPhysics {
    struct Ball {
        var x: Double, y: Double
        var vx = 0.0, vy = 0.0
        var radius: Double
    }

    private(set) var balls: [Ball] = []
    private(set) var width = 0.0
    private(set) var height = 0.0
    /// 罐子四个角的圆角半径。
    var corner = 22.0
    /// 重力，点 / 秒²。方向跟着手机怎么拿。
    var gravityX = 0.0
    var gravityY = 1400.0
    /// 还要吹多久（秒）。摇号机那样从底下往上吹。
    private(set) var blowing = 0.0
    /// 连着多少步几乎没动。
    private(set) var quietSteps = 0
    private var previousPositions: [(x: Double, y: Double)] = []
    private var heads: [Int] = []
    private var next: [Int] = []
    private var largestRadius = 0.0
    private var seed: UInt64 = 0x9E3779B97F4A7C15

    /// 都停稳了，不用再算。
    var isResting: Bool { blowing <= 0 && quietSteps >= 30 }

    private mutating func random() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 33) & 0xFFFFFF) / Double(0x1000000)
    }

    /// 把球放进罐子。`settled` 为真时直接算到停稳（减弱动态效果、截图时用），否则从上面掉下来。
    mutating func fill(radii: [Double], width: Double, height: Double, settled: Bool) {
        self.width = width
        self.height = height
        seed = 0x9E3779B97F4A7C15
        blowing = 0
        quietSteps = 0
        largestRadius = radii.max() ?? 0
        balls = radii.map { radius in
            Ball(x: radius + random() * max(width - radius * 2, 1),
                 y: radius + random() * max(height - radius * 2, 1),
                 radius: radius)
        }
        // 随手撒的位置会叠在一起，先只挪位置把它们推开，不然第一步的速度会很大
        for _ in 0..<12 { separate() }
        for index in balls.indices { balls[index].vx = 0; balls[index].vy = 0 }
        if settled {
            var steps = 0
            while !isResting && steps < 900 {
                step(1.0 / 60)
                steps += 1
            }
        }
    }

    /// 同半径的球直接从底部六角排布，打开罐子时无需在主线程上模拟落稳。
    mutating func fillPacked(count: Int, radius: Double, width: Double, height: Double) {
        self.width = width
        self.height = height
        seed = 0x9E3779B97F4A7C15
        blowing = 0
        quietSteps = 30
        largestRadius = radius
        balls.removeAll(keepingCapacity: true)
        guard count > 0, radius > 0 else { return }

        let diameter = radius * 2
        var y = height - radius
        var row = 0
        let c = min(corner, min(width, height) / 2)
        while y >= radius && balls.count < count {
            let dy = max(c - y, y - (height - c), 0)
            let left: Double
            if c > radius && dy > 0 {
                left = c - max(0, (c - radius) * (c - radius) - dy * dy).squareRoot()
            } else {
                left = radius
            }
            // 固定网格的奇偶错列保持相邻行的球互不重叠。最后一行对称地铺开。
            let columns = max(1, Int((width / diameter).rounded(.down)))
            let firstX = (width - Double(columns - 1) * diameter) / 2
            let offset = row.isMultiple(of: 2) ? 0 : radius
            let xs = (0..<columns).map { firstX + Double($0) * diameter - offset }
                .filter { $0 >= left && $0 <= width - left }
            let take = min(xs.count, count - balls.count)
            for x in xs.dropFirst((xs.count - take) / 2).prefix(take) {
                balls.append(Ball(x: x, y: y, radius: radius))
            }
            y -= radius * Double(3).squareRoot()
            row += 1
        }
        // 几何容量低于预期时稍缩球径，保持一次命中仍对应一颗球。
        if balls.count < count {
            fillPacked(count: count, radius: radius * 0.9, width: width, height: height)
        }
    }

    /// 吹一阵：罐子里的球被从下往上吹起来翻滚。
    mutating func blow(seconds: Double = 1.6) {
        blowing = seconds
        quietSteps = 0
    }

    mutating func wake() { quietSteps = 0 }

    mutating func step(_ dt: Double) {
        guard !balls.isEmpty, width > 0, height > 0 else { return }
        let substeps = 2
        let h = dt / Double(substeps)
        let jetCentre = blowing > 0 ? width * (0.5 + 0.18 * sin(blowing * 9)) : 0
        var moving = 0
        if previousPositions.count != balls.count {
            previousPositions = Array(repeating: (0, 0), count: balls.count)
        }
        for _ in 0..<substeps {
            for index in balls.indices {
                var ball = balls[index]
                previousPositions[index] = (ball.x, ball.y)
                var ax = gravityX, ay = gravityY
                if blowing > 0 {
                    // 摇号机：中间一股气流往上喷，球被顶到上面再从两边落下来，整罐翻滚。
                    // 气流的位置左右晃，不然会喷成一根不动的柱子。
                    let offset = (ball.x - jetCentre) / (width * 0.2)
                    let jet = exp(-offset * offset)
                    let depth = 0.35 + 0.65 * ball.y / height
                    ay -= 9000 * jet * depth * (0.7 + random() * 0.6)
                    // 喷上去的球往两边散
                    ax += (ball.x < jetCentre ? -1 : 1) * 1500 * jet * (1 - ball.y / height)
                    ax += (random() - 0.5) * 2400
                }
                ball.vx += ax * h
                ball.vy += ay * h
                // 一步最多挪大半个半径，免得穿过别的球
                let limit = ball.radius * 0.8 / h
                let speedSquared = ball.vx * ball.vx + ball.vy * ball.vy
                if speedSquared > limit * limit {
                    let speed = speedSquared.squareRoot()
                    ball.vx *= limit / speed
                    ball.vy *= limit / speed
                }
                ball.x += ball.vx * h
                ball.y += ball.vy * h
                balls[index] = ball
            }
            for _ in 0..<3 { separate() }
            for index in balls.indices {
                // 稍微损耗一点，球才停得下来
                balls[index].vx = (balls[index].x - previousPositions[index].x) / h * 0.985
                balls[index].vy = (balls[index].y - previousPositions[index].y) / h * 0.985
            }
        }
        for ball in balls where abs(ball.vx) + abs(ball.vy) > 14 { moving += 1 }
        if blowing > 0 { blowing = max(blowing - dt, 0) }
        // 堆在一起的球里总有一两颗被挤得微微发抖，不能等它们全停：绝大多数不动了就算停稳
        quietSteps = moving * 50 <= balls.count ? quietSteps + 1 : 0
    }

    /// 把叠着的球推开，把出界的推回来。
    private mutating func separate() {
        let count = balls.count
        guard count > 0 else { return }
        let cell = max(largestRadius * 2, 1)
        let columns = Int(width / cell) + 1, rows = Int(height / cell) + 1
        let cellCount = columns * rows
        if heads.count != cellCount { heads = Array(repeating: -1, count: cellCount) }
        else { for index in heads.indices { heads[index] = -1 } }
        if next.count != count { next = Array(repeating: -1, count: count) }
        func slot(_ ball: Ball) -> (Int, Int) {
            (min(max(Int(ball.x / cell), 0), columns - 1), min(max(Int(ball.y / cell), 0), rows - 1))
        }
        for index in 0..<count {
            let (cx, cy) = slot(balls[index])
            next[index] = heads[cy * columns + cx]
            heads[cy * columns + cx] = index
        }
        for index in 0..<count {
            let (cx, cy) = slot(balls[index])
            for ny in max(cy - 1, 0)...min(cy + 1, rows - 1) {
                for nx in max(cx - 1, 0)...min(cx + 1, columns - 1) {
                    var other = heads[ny * columns + nx]
                    while other >= 0 {
                        if other > index {
                            let dx = balls[other].x - balls[index].x, dy = balls[other].y - balls[index].y
                            let reach = balls[other].radius + balls[index].radius
                            let squared = dx * dx + dy * dy
                            if squared < reach * reach {
                                let distance = max(squared.squareRoot(), 0.0001)
                                let overlap = reach - distance
                                // 大球重，小球让得多
                                let mine = balls[index].radius * balls[index].radius
                                let theirs = balls[other].radius * balls[other].radius
                                let share = theirs / (mine + theirs)
                                let ux = squared > 0 ? dx / distance : 1, uy = squared > 0 ? dy / distance : 0
                                balls[index].x -= ux * overlap * share
                                balls[index].y -= uy * overlap * share
                                balls[other].x += ux * overlap * (1 - share)
                                balls[other].y += uy * overlap * (1 - share)
                            }
                        }
                        other = next[other]
                    }
                }
            }
        }
        for index in 0..<count { contain(&balls[index]) }
    }

    /// 罐子是圆角矩形：四条边直接夹住，四个角按圆弧算。
    private func contain(_ ball: inout Ball) {
        let r = ball.radius
        ball.x = min(max(ball.x, r), width - r)
        ball.y = min(max(ball.y, r), height - r)
        let c = min(corner, min(width, height) / 2)
        guard c > r else { return }
        let cx = ball.x < c ? c : (ball.x > width - c ? width - c : ball.x)
        let cy = ball.y < c ? c : (ball.y > height - c ? height - c : ball.y)
        guard cx != ball.x, cy != ball.y else { return }
        let dx = ball.x - cx, dy = ball.y - cy
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > c - r, distance > 0 {
            ball.x = cx + dx / distance * (c - r)
            ball.y = cy + dy / distance * (c - r)
        }
    }
}
