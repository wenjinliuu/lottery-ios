import Foundation
import CoreGraphics

/// 号码区在票面上的**位置**，由票面自己印的东西定出来。
///
/// 坐标一律是**归一化、左上角为原点**，相对那张矫正后的正片 ——
/// 和 `TicketQuad` 一致，和 Vision 的左下原点**不一致**，
/// 跨过边界的地方都显式翻一次 y。
///
/// 这个类型是整条新流水线的交接点：
/// 上游（虚线检测 / 文本基准）负责把它填出来，下游（配准 → 网格 → 逐格识别）
/// 只认它，不再去看用户的裁切框。
struct TicketFrame: Equatable {
    /// 基准是从哪儿来的。调试图上要写出来 —— 出问题时第一件事就是分清
    /// 「基准没找对」还是「基准对了但格子划歪了」。
    enum Anchor: String, Equatable {
        /// 体彩数字型：号码区上下那两条长虚线。印得清楚时这个最紧。
        case dashedRules
        /// 票面上那两行文字（体彩：机号行 + 公益行；福彩：哈希行 + 开奖期行）。
        ///
        /// **这个才是主力。** 虚线要同时过五道阈值，其中「横跨 > 80% 宽度」
        /// 的分母（纸宽？文字包络宽？印刷区宽？）本身就没有稳定答案，
        /// 票与票之间差 5–10%，正好在阈值上下横跳 —— 实测五张真票只稳住两张。
        /// 而这两行文字 Vision 每张票都读得出来，给的还是四边形，
        /// 一道阈值都不用过。
        case textLines
    }

    /// 上下两条基准线该去哪儿找。
    ///
    /// 这些正则钉的都是**格式固定**的行，不是内容固定的行 ——
    /// 促销语每期都换（「超级大乐透8.8亿派奖」「理性购买彩票」「扫码参与」），
    /// 拿它当锚点等于没有锚点。
    struct TextAnchors {
        /// 调试图上写出来，好让人知道这张票是靠哪两行定的位。
        let name: String
        /// 上基准：紧贴号码区上方那一行。
        let top: String
        /// 下基准：号码区下方第一行固定内容。
        let bottom: String

        /// 体彩：机号行（`110310-292261-111967-377226`）+ 公益行。
        ///
        /// 四张体彩真票（七星彩 ×2、排列3、排列5、大乐透）票面上都有这两行，
        /// 而且都在号码区的正上方和正下方。
        static let sportsLottery = TextAnchors(
            name: "机号行 + 公益行",
            top: "\\d{6}\\s*-\\s*\\d{6}\\s*-\\s*\\d{6}",
            bottom: "公益")

        /// 福彩：哈希行（`7D92-04AE-1FB5-E411-B960/32798871/C084C`）+ 开奖期行。
        static let welfareLottery = TextAnchors(
            name: "哈希行 + 开奖期行",
            top: "[0-9A-Fa-f]{4}(?:\\s*-\\s*[0-9A-Fa-f]{4}){3,4}\\s*/",
            bottom: "开奖期")

        /// 先试哪一对。认不出彩种时两对都试 —— 正则本来就互不相容，
        /// 拿错了只会一条都匹配不上，不会认错。
        static func ordered(for game: GameKey?) -> [TextAnchors] {
            switch game {
            case .ssq, .qlc, .k8, .fc3d: [welfareLottery, sportsLottery]
            default: [sportsLottery, welfareLottery]
            }
        }
    }

    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
    var anchor: Anchor

    /// 号码区左边界：注序号 / 玩法标签列（`①②③④⑤`、`A.B.C.`、`组六:`）的右侧。
    /// 归一化 x，相对整张票。找不到就是 nil —— 宁可空着，也不能拿个错的去切。
    var leftBoundary: CGFloat?

    /// 号码区右边界：倍数列 `(N)` 的左侧。
    ///
    /// **当前代码缺的就是这一个**：福彩 3D 行尾 `(1)` 里的 `1` 被当成第 4 个号码，
    /// `isBetRow(columns: 3)` 一看 4 > 3 直接把整行拒掉 —— 3D 的矩阵路径
    /// 从来没跑起来过，根因就在这里。
    var rightBoundary: CGFloat?

    /// 票头区的四角：以号码区**上边界那条基准**为底，往上罩住期号、开奖日期
    /// （体彩连中间那行机号一起罩进去）。
    ///
    /// 为什么值得单独框出来：期号和开奖日期是核奖的两个关键字段，
    /// 和号码一样该说得出"它来自票面哪一块"。底边和号码区共用同一条基准，
    /// 两块严丝合缝接在一起 —— 基准找对没有，一眼就看得出来。
    ///
    /// 现在只标不读：标签路按硬约束三一行都不动。
    var headCorners: [CGPoint]?

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// 四个角的包络。调试图和粗略裁剪用。
    var boundingBox: CGRect {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 配准：号码区四边形 → 标准矩形（单位正方形，左上原点）。
    ///
    /// 有了它，「第几行第几列」在标准矩形里是**算得出来的常数**，
    /// 不用再从识别结果里估 —— 所有错位的根都在那个"估"字上。
    var rectifying: Homography? {
        Homography.mapping(corners, to: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                                         CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
    }

    /// 标准矩形里的点映射回票面。**每个号码来自哪个像素格子**就是靠它回答的。
    var restoring: Homography? { rectifying?.inverse }

    // MARK: - 体彩：两条虚线

    /// 上下两条长虚线夹出来的号码区。
    ///
    /// 必须**正好两条**。三张真票（七星彩 24 条候选横带、排列5 18 条、排列3 9 条）
    /// 都是各命中 2 条、零误报；真出现第三条说明判据在这张票上失效了，
    /// 这时候宁可整个退回上一层，也不能随便挑两条凑 —— 挑错一条，
    /// 整个号码区就偏了，而用户完全看不出来。
    static func between(rules: [DashedRule], in mask: InkMask) -> TicketFrame? {
        guard rules.count == 2, mask.width > 0, mask.height > 0 else { return nil }
        let sorted = rules.sorted { $0.midY < $1.midY }
        let top = sorted[0]
        let bottom = sorted[1]

        // 两条线各自量到的横向范围取交集：超出去的那一截没量过，不能拿来外推
        let left = Double(max(top.columns.lowerBound, bottom.columns.lowerBound))
        let right = Double(min(top.columns.upperBound, bottom.columns.upperBound))
        guard right - left > Double(mask.width) * 0.5 else { return nil }

        let middle: Double = (left + right) / 2
        let gap: Double = bottom.y(at: middle) - top.y(at: middle)
        // 号码区总得有几行字那么高。两条挨在一起的线夹出来的"号码区"是假的。
        guard gap > Double(mask.height) * 0.02, gap > 8 else { return nil }

        // 取两条虚线的**内沿**，不是中线 —— 号码区是夹在它们**中间**那一块。
        //
        // 拿中线当边界的话，虚线自己的墨会落进号码区里：最后一注和下面那条
        // 虚线在投影上连成一条带，一行切出几十段，整行的格子就此消失
        // （实测大乐透第③注的格子就是这么丢的）。往里让半条线的厚度加 1px 就好。
        // 顺带把绿色的基准线从蓝框底下露出来了，两条线不再重叠。
        let topInset = Double(top.thickness) / 2 + 1
        let bottomInset = Double(bottom.thickness) / 2 + 1
        guard gap - topInset - bottomInset > 4 else { return nil }

        func point(_ x: Double, _ y: Double) -> CGPoint { mask.imagePoint(x: x, y: y) }
        return TicketFrame(topLeft: point(left, top.y(at: left) + topInset),
                           topRight: point(right, top.y(at: right) + topInset),
                           bottomRight: point(right, bottom.y(at: right) - bottomInset),
                           bottomLeft: point(left, bottom.y(at: left) - bottomInset),
                           anchor: .dashedRules)
    }

    // MARK: - 文本行基准

    /// 两行文字夹出来的号码区。
    ///
    /// 上基准取那一行的**下沿**，下基准取那一行的**上沿** —— 夹出来的正好是
    /// 两行之间那一块，号码全在里面。中间夹着的虚线、玩法/倍数/合计那一行、
    /// 促销语，都留在区里不要紧：哪几行是投注号码，由墨迹投影去分（阶段 2），
    /// 不靠这一层去猜。
    ///
    /// 横向按**上基准那一行**的宽度来 —— 机号行和哈希行都横跨整个印刷区，
    /// 是票面上最宽的一行；下基准（公益行 / 开奖期行）居中而且短，
    /// 拿它定宽度会把号码切掉，所以只取它的**方向**，把线延长过去。
    static func between(top: TicketVisionScanner.TextFragment,
                        bottom: TicketVisionScanner.TextFragment) -> TicketFrame? {
        guard let (topLeft, topRight) = top.bottomEdge,
              let (bottomLeftEdge, bottomRightEdge) = bottom.topEdge else { return nil }
        guard topRight.x - topLeft.x > 0.2 else { return nil }

        // 下基准那条线延长到上基准的左右两端
        func extend(_ a: CGPoint, _ b: CGPoint, to x: CGFloat) -> CGPoint? {
            let span = b.x - a.x
            guard abs(span) > 1e-6 else { return nil }
            return CGPoint(x: x, y: a.y + (x - a.x) / span * (b.y - a.y))
        }
        guard let bottomLeft = extend(bottomLeftEdge, bottomRightEdge, to: topLeft.x),
              let bottomRight = extend(bottomLeftEdge, bottomRightEdge, to: topRight.x)
        else { return nil }

        // 上基准必须在上面，而且中间得装得下几行号码
        let gap = Swift.min(bottomLeft.y, bottomRight.y) - Swift.max(topLeft.y, topRight.y)
        guard gap > 0.02 else { return nil }

        return TicketFrame(topLeft: topLeft, topRight: topRight,
                           bottomRight: bottomRight, bottomLeft: bottomLeft,
                           anchor: .textLines)
    }

    /// 按正则挑出当基准的那一行。
    ///
    /// 同一个模式命中好几块时，上基准取**最靠下**的（离号码区最近），
    /// 下基准取**最靠上**的 —— 中间夹出来的那一块才是号码区。
    static func anchorLine(_ fragments: [TicketVisionScanner.TextFragment],
                           matching pattern: String,
                           lowest: Bool) -> TicketVisionScanner.TextFragment? {
        let matched = fragments.filter {
            $0.text.range(of: pattern, options: .regularExpression) != nil
        }
        // Vision 的 y 向上为正：最靠下 = midY 最小
        return lowest ? matched.min { $0.box.midY < $1.box.midY }
                      : matched.max { $0.box.midY < $1.box.midY }
    }

    /// 用票面上那两行文字当基准，夹出号码区。
    static func betweenTextLines(_ fragments: [TicketVisionScanner.TextFragment],
                                 anchors: TextAnchors) -> TicketFrame? {
        guard let top = anchorLine(fragments, matching: anchors.top, lowest: true),
              let bottom = anchorLine(fragments, matching: anchors.bottom, lowest: false)
        else { return nil }
        return between(top: top, bottom: bottom)
    }

    // MARK: - 票头区

    /// 票头那一行 —— 号码区上方最值得单独框出来的那行。
    ///
    /// 体彩印成 `第26102期 2026年09月07日开奖`（期号 + 开奖日期）；
    /// 福彩印成 `玩法:3D-单式  机号:31130622`（彩种玩法），就在哈希行上面。
    /// 两家都是核奖要用的字段，都该说得出"来自票面哪一块"。
    static let issuePattern =
        "第\\s*\\d{4,7}\\s*期|玩法\\s*[:：]|\\d{4}\\s*年\\s*\\d{1,2}\\s*月"

    /// 期号 / 开奖日期那一行的**顶**在哪儿（归一化，左上原点）。
    ///
    /// 只认号码区**上方**的碎片 —— 票底那行出票时间也带日期，
    /// 拿它当锚点的话票头区会倒着罩下来。
    static func issueTop(_ fragments: [TicketVisionScanner.TextFragment],
                         above zoneTop: CGFloat) -> CGFloat? {
        var best: CGFloat?
        for fragment in fragments {
            // Vision 的 y 向上为正，翻成左上原点
            let top = 1 - fragment.box.maxY
            let bottom = 1 - fragment.box.minY
            guard bottom <= zoneTop else { continue }
            guard fragment.text.range(of: issuePattern, options: .regularExpression) != nil
            else { continue }
            best = Swift.min(best ?? top, top)
        }
        return best
    }

    /// 把票头区接在号码区上面。
    ///
    /// 上边是一条**和号码区上边平行**的线，穿过期号那一行的顶；底边就是
    /// 号码区的上边本身，两块严丝合缝。平行是关键 —— 票斜着的时候，
    /// 横平竖直的框会一边压住字、一边空一大块，反而看不出基准准不准。
    func addingHead(topAt top: CGFloat) -> TicketFrame {
        let edge = Swift.min(topLeft.y, topRight.y)
        let shift = edge - top
        // 期号行得在号码区上面，而且不能一路顶到票外面去
        guard shift > 0.005, topLeft.y - shift >= 0, topRight.y - shift >= 0 else { return self }
        var copy = self
        copy.headCorners = [CGPoint(x: topLeft.x, y: topLeft.y - shift),
                            CGPoint(x: topRight.x, y: topRight.y - shift),
                            topRight,
                            topLeft]
        return copy
    }

    // MARK: - 左右边界

    /// 号码区右边界：倍数列 `(N)` 的左侧。
    ///
    /// 只认**整块就是 `(N)`** 的碎片，而且得在号码区自己那一段高度里。
    /// 不这么卡的话，票面别处的 `(2)`、或者被 Vision 连着号码一起读出来的
    /// 整行，都会被当成边界 —— 那一刀下去切掉的就是真号码。
    ///
    /// 取最靠左的那一个：边界要把**所有**倍数都挡在外面。
    static func multiplierBoundary(_ fragments: [TicketVisionScanner.TextFragment],
                                   within band: ClosedRange<CGFloat>,
                                   contentWidth: CGFloat) -> CGFloat? {
        let pattern = "^[(（]\\s*\\d{1,2}\\s*[)）]$"
        let candidates = fragments.filter { fragment in
            // Vision 的 y 向上为正，翻成左上原点再和号码区比高低
            let center = 1 - fragment.box.midY
            guard band.contains(center) else { return false }
            guard fragment.box.width < contentWidth * 0.2 else { return false }
            let text = fragment.text.trimmingCharacters(in: .whitespaces)
            return text.range(of: pattern, options: .regularExpression) != nil
        }
        return candidates.map(\.box.minX).min()
    }
}

extension TicketFrame {
    /// 票面上一条竖直边界（左边界 / 右边界）在**标准矩形**里的横坐标。
    ///
    /// 单应把票面的直线映射成直线，但竖直线映射过去不一定还是竖直的 ——
    /// 所以取这条线和号码区上下两条边的交点，各映射一次再取平均。
    /// 票只差一两度的时候两者几乎重合；差得多说明透视很强，
    /// 那正是该让用户重裁的信号。
    func rectifiedX(of x: CGFloat) -> CGFloat? {
        guard let rectifying else { return nil }
        func interpolate(_ a: CGPoint, _ b: CGPoint) -> CGPoint? {
            let span = b.x - a.x
            guard abs(span) > 1e-9 else { return nil }
            let t = (x - a.x) / span
            return CGPoint(x: x, y: a.y + t * (b.y - a.y))
        }
        guard let top = interpolate(topLeft, topRight),
              let bottom = interpolate(bottomLeft, bottomRight),
              let mappedTop = rectifying.map(top),
              let mappedBottom = rectifying.map(bottom) else { return nil }
        return (mappedTop.x + mappedBottom.x) / 2
    }

    /// 标准矩形里的一块（0–1 坐标）映射回票面的四个角。
    ///
    /// 调试图上画的每一个格子都是这么画回去的 —— 画得出来，
    /// 就等于「这个号码来自票面哪个像素格子」答得上来。
    func restore(_ rect: CGRect) -> [CGPoint]? {
        guard let restoring else { return nil }
        let corners = [CGPoint(x: rect.minX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY),
                       CGPoint(x: rect.minX, y: rect.maxY)]
        let mapped = corners.compactMap { restoring.map($0) }
        return mapped.count == 4 ? mapped : nil
    }
}
