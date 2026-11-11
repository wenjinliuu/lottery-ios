import Foundation

/// 把找票得到的框贴到票纸的边上。
///
/// `TicketLocator` 的框是按**文字**算出来的：左右留两个字距、上面留够票头、下面留两三行。
/// 认号码够用，但摆在预识别页上看着别扭 —— 有的边切进票里，有的边伸到垫子上。
/// 这里再看一眼像素：纸是亮的、背景是暗的，每条边从票里面往外走，走到「不再是纸」的地方停下。
///
/// 规矩：
/// - **找到明确的纸边才动**。两张票连着没撕开、或者挨着放，中间没有暗缝，那条边就留在原处。
/// - 每条边分两半各量一次，所以拍歪了、有透视的票，框也跟着歪；两半差得太远的边不动。
/// - 贴完的框面积变化太大就整个作废，用原来的。
///
/// 输入是红色通道：体彩票右边那条红色的边在红色通道里是亮的，算纸。
enum PaperEdge {
    struct Point: Equatable {
        var x: Double, y: Double
    }

    /// 往外最多找多远、往里从哪儿起（都是框自己宽高的比例）。
    static let outward: (side: Double, top: Double, bottom: Double) = (0.28, 0.16, 0.32)
    static let inward = 0.22

    /// - Parameter corners: 左上、右上、右下、左下，像素坐标。
    static func fit(_ gray: [UInt8], width: Int, height: Int, corners: [Point]) -> [Point] {
        guard corners.count == 4, width > 4, height > 4, gray.count == width * height else { return corners }
        let (topLeft, topRight, bottomRight, bottomLeft) = (corners[0], corners[1], corners[2], corners[3])
        // 框里的点：s 从左到右、t 从上到下，0…1 之外就是框外
        func at(_ s: Double, _ t: Double) -> Point {
            let upper = Point(x: topLeft.x + (topRight.x - topLeft.x) * s, y: topLeft.y + (topRight.y - topLeft.y) * s)
            let lower = Point(x: bottomLeft.x + (bottomRight.x - bottomLeft.x) * s,
                              y: bottomLeft.y + (bottomRight.y - bottomLeft.y) * s)
            return Point(x: upper.x + (lower.x - upper.x) * t, y: upper.y + (lower.y - upper.y) * t)
        }
        func value(_ point: Point) -> Int? {
            let x = Int(point.x.rounded()), y = Int(point.y.rounded())
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            return Int(gray[y * width + x])
        }
        // 纸有多亮：框中间那一片里偏亮的那些点
        var inside: [Int] = []
        for row in 0..<24 {
            for column in 0..<24 {
                if let found = value(at(0.2 + 0.6 * Double(column) / 23, 0.15 + 0.7 * Double(row) / 23)) {
                    inside.append(found)
                }
            }
        }
        guard inside.count >= 100 else { return corners }
        inside.sort()
        let paper = inside[inside.count * 8 / 10]
        let floor = paper * 78 / 100
        guard paper >= 90 else { return corners }       // 整张都暗：分不出纸和背景

        let spanX = hypot(topRight.x - topLeft.x, topRight.y - topLeft.y)
        let spanY = hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y)
        guard spanX > 8, spanY > 8 else { return corners }

        /// 一条边的一半：从里往外走，返回纸边所在的位置（s 或 t），找不到是 nil。
        /// `sample(offset, along)` 给出这条扫描线上的一个点。
        func edge(from start: Double, to end: Double, steps: Int, alongRange: ClosedRange<Double>,
                  minimum: Double, sample: (Double, Double) -> Point) -> Double? {
            var last: Double?
            var misses = 0
            var seenPaper = false
            for step in 0...steps {
                let offset = start + (end - start) * Double(step) / Double(steps)
                var bright = 0, total = 0
                for index in 0..<28 {
                    let along = alongRange.lowerBound
                        + (alongRange.upperBound - alongRange.lowerBound) * Double(index) / 27
                    guard let found = value(sample(offset, along)) else { continue }
                    total += 1
                    if found >= floor { bright += 1 }
                }
                // 走出照片了：照片的边不是纸边
                guard total >= 14 else { return nil }
                if Double(bright) >= minimum * Double(total) {
                    seenPaper = true
                    last = offset
                    misses = 0
                } else if seenPaper {
                    misses += 1
                    // 连着几条线都不是纸，才算真的出了纸（一条暗线可能是折痕、虚线）
                    if misses >= max(steps / 40, 3) { return last }
                }
            }
            return nil
        }

        let stepsX = max(Int(spanX * (inward + outward.side)), 8)
        let halves: [ClosedRange<Double>] = [0.08...0.45, 0.55...0.92]
        // 每条边两个量出来的位置；量不出来的用原来的（0 或 1）
        func pair(_ measure: (ClosedRange<Double>) -> Double?, fallback: Double) -> (Double, Double)? {
            let first = measure(halves[0]), second = measure(halves[1])
            if first == nil, second == nil { return nil }
            // 两半量出来差得太远：一半停在了纸边、另一半穿过去了（两张票连着没撕开时就是这样），
            // 哪一半都不可信，这条边不动。
            if let first, let second, abs(first - second) > 0.07 { return nil }
            // 只量出一半：整条边平移
            return (first ?? second ?? fallback, second ?? first ?? fallback)
        }
        let left = pair({ range in
            edge(from: inward, to: -outward.side, steps: stepsX, alongRange: range, minimum: 0.5) { at($0, $1) }
        }, fallback: 0)
        let right = pair({ range in
            edge(from: 1 - inward, to: 1 + outward.side, steps: stepsX, alongRange: range, minimum: 0.5) { at($0, $1) }
        }, fallback: 1)
        let top = pair({ range in
            edge(from: inward, to: -outward.top, steps: max(Int(spanY * (inward + outward.top)), 8),
                 alongRange: range, minimum: 0.5) { at($1, $0) }
        }, fallback: 0)
        // 下边要穿过条码：条码那几行只有两头和缝里是亮的，所以门槛低得多
        let bottom = pair({ range in
            edge(from: 1 - inward, to: 1 + outward.bottom, steps: max(Int(spanY * (inward + outward.bottom)), 8),
                 alongRange: range, minimum: 0.15) { at($1, $0) }
        }, fallback: 1)

        // 每条边变成一条线（过两个半段中点处的点），四条线两两相交就是新的四个角
        let near = 0.265, far = 0.735
        func line(_ values: (Double, Double)?, fallback: Double, vertical: Bool) -> (Point, Point) {
            let (first, second) = values ?? (fallback, fallback)
            return vertical ? (at(first, near), at(second, far)) : (at(near, first), at(far, second))
        }
        let leftLine = line(left, fallback: 0, vertical: true)
        let rightLine = line(right, fallback: 1, vertical: true)
        let topLine = line(top, fallback: 0, vertical: false)
        let bottomLine = line(bottom, fallback: 1, vertical: false)
        guard let newTopLeft = cross(topLine, leftLine), let newTopRight = cross(topLine, rightLine),
              let newBottomRight = cross(bottomLine, rightLine), let newBottomLeft = cross(bottomLine, leftLine)
        else { return corners }
        let fitted = [newTopLeft, newTopRight, newBottomRight, newBottomLeft].map {
            Point(x: min(max($0.x, 0), Double(width - 1)), y: min(max($0.y, 0), Double(height - 1)))
        }
        let before = area(corners), after = area(fitted)
        guard before > 0, after >= before * 0.55, after <= before * 1.9 else { return corners }
        return fitted
    }

    /// 两条直线的交点。平行就是 nil。
    static func cross(_ first: (Point, Point), _ second: (Point, Point)) -> Point? {
        let dx1 = first.1.x - first.0.x, dy1 = first.1.y - first.0.y
        let dx2 = second.1.x - second.0.x, dy2 = second.1.y - second.0.y
        let denominator = dx1 * dy2 - dy1 * dx2
        guard abs(denominator) > 1e-9 else { return nil }
        let t = ((second.0.x - first.0.x) * dy2 - (second.0.y - first.0.y) * dx2) / denominator
        return Point(x: first.0.x + dx1 * t, y: first.0.y + dy1 * t)
    }

    /// 四边形的面积（带符号的鞋带公式取绝对值）。
    static func area(_ corners: [Point]) -> Double {
        var sum = 0.0
        for index in corners.indices {
            let next = corners[(index + 1) % corners.count]
            sum += corners[index].x * next.y - next.x * corners[index].y
        }
        return abs(sum) / 2
    }
}
