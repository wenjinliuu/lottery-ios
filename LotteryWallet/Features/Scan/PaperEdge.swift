import Foundation

/// 把找票得到的框贴到票纸的边上。
///
/// `TicketLocator` 的框是按**文字**算出来的：左右留两个字距、上面留够票头、下面留两三行。
/// 认号码够用，但摆在预识别页上看着别扭 —— 有的边切进票里，有的边伸到垫子上。
/// 这里再看一眼像素：纸是亮的、背景是暗的，每条边从票里面往外走，走到「不再是纸」的地方停下。
///
/// 规矩：
/// - **找到明确的纸边才动**。两张票连着没撕开、或者挨着放，中间没有暗缝，那条边就留在原处。
/// - 每条边量一排点、拟合成一条直线，所以框是贴着纸的四边形（梯形、歪的都行），不一定是矩形。
/// - 一排点落不到一条线上的边不动。
/// - 贴完的框面积变化太大就整个作废，用原来的。
///
/// 输入是红色通道：体彩票右边那条红色的边在红色通道里是亮的，算纸。
enum PaperEdge {
    struct Point: Equatable {
        var x: Double, y: Double
    }

    /// 往外最多找多远、往里从哪儿起（都是框自己宽高的比例）。
    static let outward: (side: Double, top: Double, bottom: Double) = (0.35, 0.30, 0.50)
    static let inward = 0.40
    /// 每条边上量多少个点。
    static let probes = 21

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

        /// 一个点上从里往外走，返回纸边的位置（s 或 t）。
        ///
        /// 连着暗了 `need` 这么长才算出了纸 —— 字的笔画、虚线、二维码都比它短。
        /// 走到头还没出纸（旁边连着另一张票）、或者走出了照片，都是 nil。
        func probe(from start: Double, to end: Double, span: Double, need: Double,
                   sample: (Double) -> Point) -> Double? {
            let steps = max(Int(abs(end - start) * span), 4)
            let needSteps = max(Int(need.rounded()), 3)
            var seenPaper = false
            var dark = 0
            var edge = start
            for step in 0...steps {
                let offset = start + (end - start) * Double(step) / Double(steps)
                guard let found = value(sample(offset)) else { return nil }
                if found >= floor {
                    seenPaper = true
                    dark = 0
                    edge = offset
                } else if seenPaper {
                    dark += 1
                    if dark >= needSteps { return edge }
                }
            }
            return nil
        }

        /// 一条边：量一排点，拟合成一条直线。返回这条线在两端（along = 0 和 1）的位置。
        ///
        /// 一排点里大多数落在同一条直线上才算数。落不到一条线上，说明这条边没有明确的纸边
        /// （两张票连着、被别的票压着），这条边不动。
        func side(_ measure: (Double) -> Double?, tolerance: Double) -> (Double, Double)? {
            var points: [(along: Double, offset: Double)] = []
            for index in 0..<probes {
                let along = 0.05 + 0.9 * Double(index) / Double(probes - 1)
                if let offset = measure(along) { points.append((along, offset)) }
            }
            guard points.count * 2 >= probes else { return nil }
            // 先用「任意两点连线的斜率的中位数」定方向，不怕个别点量歪
            var slopes: [Double] = []
            for first in points.indices {
                for second in points.indices where second > first {
                    let run = points[second].along - points[first].along
                    if run > 0.15 { slopes.append((points[second].offset - points[first].offset) / run) }
                }
            }
            guard !slopes.isEmpty else { return nil }
            slopes.sort()
            let slope = slopes[slopes.count / 2]
            let intercepts = points.map { $0.offset - slope * $0.along }.sorted()
            let intercept = intercepts[intercepts.count / 2]
            let inliers = points.filter { abs($0.offset - (slope * $0.along + intercept)) <= tolerance }
            guard inliers.count * 20 >= probes * 11 else { return nil }
            // 再拿落在线上的那些点做一次最小二乘
            let count = Double(inliers.count)
            let meanAlong = inliers.reduce(0) { $0 + $1.along } / count
            let meanOffset = inliers.reduce(0) { $0 + $1.offset } / count
            var numerator = 0.0, denominator = 0.0
            for point in inliers {
                numerator += (point.along - meanAlong) * (point.offset - meanOffset)
                denominator += (point.along - meanAlong) * (point.along - meanAlong)
            }
            let fitted = denominator > 1e-9 ? numerator / denominator : 0
            let base = meanOffset - fitted * meanAlong
            return (base, base + fitted)
        }

        let shortRun = max(min(spanX, spanY) * 0.025, 3)
        let toleranceX = max(3 / spanX, 0.012), toleranceY = max(3 / spanY, 0.012)
        let left = side({ along in
            probe(from: inward, to: -outward.side, span: spanX, need: shortRun) { at($0, along) }
        }, tolerance: toleranceX)
        let right = side({ along in
            probe(from: 1 - inward, to: 1 + outward.side, span: spanX, need: shortRun) { at($0, along) }
        }, tolerance: toleranceX)
        let top = side({ along in
            probe(from: inward, to: -outward.top, span: spanY, need: shortRun) { at(along, $0) }
        }, tolerance: toleranceY)
        // 下边要穿过条码。条码是黑白相间的竖条，背景是一整片暗：
        // 所以往下走的时候每一步都往左右看一点，旁边有亮的就还算在纸上。
        let bottom = side({ along in
            probe(from: 1 - inward, to: 1 + outward.bottom, span: spanY, need: shortRun) { offset in
                // 左右各看出去半个条码定位条那么宽，取最亮的一点
                var best = at(along, offset), brightest = -1
                for shift in -3...3 {
                    let candidate = at(along + Double(shift) * 0.018, offset)
                    if let found = value(candidate), found > brightest { brightest = found; best = candidate }
                }
                return best
            }
        }, tolerance: toleranceY)

        // 四条线两两相交就是新的四个角。量不出来的边用原来的位置。
        func line(_ values: (Double, Double)?, fallback: Double, vertical: Bool) -> (Point, Point) {
            let (first, second) = values ?? (fallback, fallback)
            return vertical ? (at(first, 0), at(second, 1)) : (at(0, first), at(1, second))
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
        guard before > 0, after >= before * 0.45, after <= before * 2.4 else { return corners }
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
