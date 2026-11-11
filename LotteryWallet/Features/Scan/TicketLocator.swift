import UIKit

/// 在一张照片里找出每一张票，只靠识别出来的文字行。
///
/// 每张票上有且只有一行「锚」：
/// - 福彩：票面哈希 `7692-3402-B25E-4034-AF48/11402378/22513`
/// - 体彩：流水号 `110310-309661-112089-342471 562783 rCVxQg`
///
/// 锚行的走向就是票的走向，字距就是票的比例尺。其余文字行按位置归到各自的锚下面，
/// 归完之后这些行的外接框就是这张票。
///
/// **不依赖条码。** 条码会被别的票压住、被手指挡住，外省的票底甚至不是这种条码；
/// 而锚行在票的上半截，几乎总是露着的。
///
/// 这套规则先在 `lottery-ocr` 仓库的 `tools/locate_tickets.py` 里拿真票照片量过：
/// 28 张照片、40 张票（并排、叠放、连体没撕开、手指遮挡、外省版式）定位到 39 张。
/// 两边的常数必须一起改。
enum TicketLocator {

    /// 一行识别出来的文字。四个角是**像素坐标、左上原点**，顺序：左上、右上、右下、左下。
    struct Line: Equatable {
        var text: String
        var corners: [CGPoint]
    }

    enum Kind: Equatable {
        case welfare, sports
    }

    struct Found: Equatable {
        var kind: Kind
        /// 这张票的四个角，像素坐标，顺序同上。
        var corners: [CGPoint]
        /// 找到了票底（福彩的「…发行中心承销」、体彩的站号行）。
        /// 没找到多半是下半截被压住或裁掉了 —— 票还是会交出去，但只到看得见的地方为止。
        var complete: Bool
    }

    // 版式常数，单位都是「锚行的字距」或「锚行的行高」，和拍摄距离无关。
    private static let welfareChars = 39.0, sportsChars = 27.0   // 锚自己有多少个字符
    private static let welfareSpan = 54.0, sportsSpan = 47.0     // 锚行左端到票面文字右沿，约多少个字距
    private static let leftSlack = 4.0                           // 票面文字左沿最多比锚行靠左几个字距
    private static let headLines: [Kind: Double] = [.welfare: 7, .sports: 10]
    private static let minimumHead: [Kind: Double] = [.welfare: 4.5, .sports: 6.5]
    private static let tailLines = 2.5

    /// 票头里才会出现的字。锚行上方的文字只有带这些字才归这张票 ——
    /// 否则叠着放的时候，上一张票的下半截会被下一张票当成自己的票头吞掉。
    private static let headWords: [Kind: [String]] = [
        .welfare: ["福利", "彩票", "WELFARE", "LOTTERY", "CHINA", "玩法", "机号"],
        .sports: ["体彩", "乐透", "排列", "星彩", "开奖", "期"]
    ]

    private struct Anchor {
        var kind: Kind
        var origin: CGPoint
        var u: CGPoint
        var v: CGPoint
        var pitch: Double
        var height: Double

        /// 图上一点在这张票自己的坐标系里的位置：u 沿文字方向，v 向票的下方。
        func local(_ point: CGPoint) -> (u: Double, v: Double) {
            let dx = Double(point.x - origin.x), dy = Double(point.y - origin.y)
            return (dx * Double(u.x) + dy * Double(u.y), dx * Double(v.x) + dy * Double(v.y))
        }

        func point(u offsetU: Double, v offsetV: Double) -> CGPoint {
            CGPoint(x: Double(origin.x) + offsetU * Double(u.x) + offsetV * Double(v.x),
                    y: Double(origin.y) + offsetU * Double(u.y) + offsetV * Double(v.y))
        }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func anchor(for line: Line) -> Anchor? {
        guard line.corners.count == 4 else { return nil }
        let compact = line.text.replacingOccurrences(of: " ", with: "").uppercased()
        let kind: Kind
        let chars: Double
        if matches(compact, "[0-9A-Z]{3,5}-[0-9A-Z]{3,5}-[0-9A-Z]{3,5}-[0-9A-Z]{3,5}-[0-9A-Z]{3,5}"), compact.contains("/") {
            kind = .welfare
            chars = welfareChars
        } else if matches(compact, "[0-9]{5,7}-[0-9]{5,7}-[0-9]{5,7}-[0-9]{5,7}") {
            kind = .sports
            chars = sportsChars
        } else {
            return nil
        }
        let along = CGPoint(x: line.corners[1].x - line.corners[0].x, y: line.corners[1].y - line.corners[0].y)
        let length = Double(hypot(along.x, along.y))
        guard length > 0 else { return nil }
        let u = CGPoint(x: Double(along.x) / length, y: Double(along.y) / length)
        let height = Double(hypot(line.corners[3].x - line.corners[0].x, line.corners[3].y - line.corners[0].y))
        // 识别有时把锚后面的校验码并进同一行，所以按这一行实际有多少个字来算字距。
        let count = Double(line.text.trimmingCharacters(in: .whitespaces).count)
        return Anchor(kind: kind, origin: line.corners[0], u: u, v: CGPoint(x: -u.y, y: u.x),
                      pitch: length / max(count, chars), height: max(height, 1))
    }

    /// 找票。返回的顺序是从上到下、从左到右。
    static func locate(_ lines: [Line]) -> [Found] {
        let anchors = lines.compactMap(anchor(for:))
        guard !anchors.isEmpty else { return [] }

        // 每一行文字归给哪个锚。
        var members = Array(repeating: [Int](), count: anchors.count)
        for (index, line) in lines.enumerated() where line.corners.count == 4 {
            let center = CGPoint(x: line.corners.map(\.x).reduce(0, +) / 4, y: line.corners.map(\.y).reduce(0, +) / 4)
            let upper = line.text.uppercased()
            var best: (rank: (Int, Double), anchor: Int)?
            for (number, anchor) in anchors.enumerated() {
                let position = anchor.local(center)
                let span = anchor.kind == .welfare ? welfareSpan : sportsSpan
                guard position.u >= -leftSlack * anchor.pitch, position.u <= span * anchor.pitch else { continue }
                guard position.v >= -(headLines[anchor.kind] ?? 7) * anchor.height else { continue }
                if position.v < 0 {
                    // 票底那行「××市福利彩票发行中心承销」也带着「福利」「彩票」两个词。
                    // 上下挨着放的时候，上面那张的票底正好落在下面那张的票头范围里 ——
                    // 不排除它，上面那张就丢了票底，下面那张的框还会被撑宽。
                    let isFooter = upper.contains("承销") || upper.contains("发行中心")
                    if isFooter || !(headWords[anchor.kind] ?? []).contains(where: { upper.contains($0) }) { continue }
                }
                // 落在某个锚的票头范围里（锚的上方）而且长得像票头，优先归它；
                // 否则归正上方最近的那个锚。
                let rank = position.v < 0 ? (0, -position.v) : (1, position.v)
                if best == nil || rank < best!.rank { best = (rank, number) }
            }
            if let best { members[best.anchor].append(index) }
        }

        var found: [Found] = []
        for (number, anchor) in anchors.enumerated() {
            struct Row { var text: String; var u0: Double; var u1: Double; var v0: Double; var v1: Double }
            var rows: [Row] = members[number].map { index in
                let points = lines[index].corners.map { anchor.local($0) }
                let us = points.map { $0.u }, vs = points.map { $0.v }
                return Row(text: lines[index].text,
                           u0: us.min() ?? 0, u1: us.max() ?? 0, v0: vs.min() ?? 0, v1: vs.max() ?? 0)
            }
            // 票底：找到了就在它下面收口，垫子上印的字、压在下面的另一张票都带不进来。
            var end: Double?
            for row in rows {
                let compact = row.text.replacingOccurrences(of: " ", with: "")
                let isEnd = anchor.kind == .welfare
                    ? compact.contains("承销") || compact.contains("发行中心")
                    : row.v0 > 0 && matches(compact, "[0-9]{2}-[0-9]{6}-[0-9]{3}")
                if isEnd { end = max(end ?? 0, row.v1) }
            }
            let complete = end != nil
            if end == nil {
                // 退一步：公益金那一行也在票的最下面，往下再留两三行。
                for row in rows where row.text.contains("公益") {
                    end = max(end ?? 0, row.v1 + anchor.height * (anchor.kind == .welfare ? 2 : 3))
                }
            }
            if let end { rows.removeAll { $0.v0 > end + anchor.height * 0.5 } }
            guard !rows.isEmpty else { continue }

            let u0 = (rows.map { $0.u0 }.min() ?? 0) - 2 * anchor.pitch
            let u1 = (rows.map { $0.u1 }.max() ?? 0) + 2 * anchor.pitch
            // 锚行上方至少留够票头的高度：标志、标题就算没认出来也要裁进去，
            // 彩种名就印在那儿。
            let v0 = min((rows.map { $0.v0 }.min() ?? 0) - 1.5 * anchor.height,
                         -(minimumHead[anchor.kind] ?? 5) * anchor.height)
            let v1 = (rows.map { $0.v1 }.max() ?? 0) + tailLines * anchor.height
            found.append(Found(kind: anchor.kind,
                               corners: [anchor.point(u: u0, v: v0), anchor.point(u: u1, v: v0),
                                         anchor.point(u: u1, v: v1), anchor.point(u: u0, v: v1)],
                               complete: complete))
        }

        // 同一排的票（上沿相差不到几行高）按从左到右，排与排之间从上到下。
        let band = (anchors.map(\.height).sorted()[anchors.count / 2]) * 6
        return found.sorted { lhs, rhs in
            let left = (Double(lhs.corners[0].y) / band).rounded(), right = (Double(rhs.corners[0].y) / band).rounded()
            return left == right ? lhs.corners[0].x < rhs.corners[0].x : left < right
        }
    }

    /// 在照片里找票，返回每张票的归一化四角（可以直接交给 `TicketImagePreprocessor.prepare`）。
    /// 一张都没找到返回空数组 —— 调用方退回手动框选。
    static func find(in image: UIImage) async -> [TicketQuad] {
        // 整张照片里票可能很小，字高门槛要比认单张票时低。
        guard let fragments = try? await TicketVisionScanner.recognizeFragments(in: image, minimumTextHeight: 0.004) else {
            return []
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return [] }
        func pixel(_ point: CGPoint) -> CGPoint {
            // Vision 归一化坐标原点在左下，翻成左上原点的像素。
            CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
        }
        let lines: [Line] = fragments.compactMap { fragment in
            guard let topLeft = fragment.topLeft, let topRight = fragment.topRight,
                  let bottomRight = fragment.bottomRight, let bottomLeft = fragment.bottomLeft else { return nil }
            return Line(text: fragment.text,
                        corners: [pixel(topLeft), pixel(topRight), pixel(bottomRight), pixel(bottomLeft)])
        }
        return locate(lines).map { ticket in
            func unit(_ point: CGPoint) -> CGPoint {
                CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
            }
            return TicketQuad(topLeft: unit(ticket.corners[0]), topRight: unit(ticket.corners[1]),
                              bottomRight: unit(ticket.corners[2]), bottomLeft: unit(ticket.corners[3]))
        }
    }
}
