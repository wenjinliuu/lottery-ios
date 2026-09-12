import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// **配准**：识别之前先把号码区摆正。
///
/// 这是整次重构补上的那一步。原来的流水线是「用户裁切 → 直接 OCR」，
/// 中间什么都没有，于是所有几何判据（列距、行距、边界）只能从**识别结果**里估，
/// 而裁切框本身是歪的、松的 —— 估出来的东西自然跟着偏。
///
/// 现在中间插进来的是：
///
/// ```
/// 粗裁切 → 基准检测（体彩：虚线 / 福彩：哈希行+开奖期行）
///        → TicketFrame（号码区四角 + 左右边界）
///        → 单应配准 → 号码区摆成标准矩形
/// ```
///
/// 阶段 1 只做到这里，外加把结果画出来给人看。
/// 号码还是走老路认的 —— 先让「摆正没摆正」这件事**肉眼可判**，
/// 再把识别接到标准矩形上（阶段 2）。
enum TicketRegistration {

    struct Result {
        var frame: TicketFrame?
        /// 配准后的号码区正片。复核页贴出来，正没正一眼看得出。
        var rectified: UIImage?
        var debug = ScanDebugReport()
    }

    /// 跑一遍配准。**永远不抛错、永远不改识别结果** ——
    /// 它现在只负责"看见"，看不见就如实说看不见。
    static func run(image: UIImage,
                    fragments: [TicketVisionScanner.TextFragment],
                    game: GameKey?) async -> Result {
        guard let cgImage = image.cgImage else {
            var debug = ScanDebugReport()
            debug.notes.append("图片读不出来，没法量")
            return Result(debug: debug)
        }
        let boundary = TicketVisionScanner.rowLabelBoundary(fragments)
        let contentWidth = TicketVisionScanner.contentBox(fragments)?.width ?? 1
        let expectsRules = game.map { DigitTicketLayout.of($0) != nil && $0 != .fc3d } ?? true
        let region = ticketRegion(fragments)
        let size = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let tilt = TicketVisionScanner.textTilt(fragments, size: size)

        return await Task.detached(priority: .userInitiated) {
            measure(cgImage: cgImage,
                    fragments: fragments,
                    leftBoundary: boundary,
                    contentWidth: contentWidth,
                    expectsRules: expectsRules,
                    region: region,
                    tilt: tilt)
        }.value
    }

    /// 票面在照片里占的那一块（归一化，左上原点）。
    ///
    /// **所有像素判据都只在这一块里算。** 拿整张照片当分母的话，
    /// 裁松一点就两头挨打：大津法会把深色桌面当成墨（虚线连候选带都切不出来），
    /// 横跨判据也会误伤（同一条虚线，裁紧时横跨 0.97，四周各留一圈之后只剩 0.69，
    /// 而判据要求 > 0.80）。这正是「裁歪一点、裁松一点就整个没有标注」的来源。
    ///
    /// 边界取的是**认出来的文字**占的那一块，再往外让一点 ——
    /// 虚线比文字印得宽，让出来的这一点正好把它接住；
    /// 让过头的话深色桌面又进来了，所以只让 3%。
    static func ticketRegion(_ fragments: [TicketVisionScanner.TextFragment]) -> CGRect? {
        guard let box = TicketVisionScanner.contentBox(fragments),
              box.width > 0.2, box.height > 0.05 else { return nil }
        let padX = box.width * 0.03
        let padY = box.height * 0.03
        let left = Swift.max(0, box.minX - padX)
        let right = Swift.min(1, box.maxX + padX)
        // Vision 的 y 向上为正，翻成左上原点
        let top = Swift.max(0, 1 - box.maxY - padY)
        let bottom = Swift.min(1, 1 - box.minY + padY)
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    // MARK: - 量

    private static func measure(cgImage: CGImage,
                                fragments: [TicketVisionScanner.TextFragment],
                                leftBoundary: CGFloat?,
                                contentWidth: CGFloat,
                                expectsRules: Bool,
                                region: CGRect?,
                                tilt: Double?) -> Result {
        var debug = ScanDebugReport()
        guard let mask = InkMask.make(cgImage, region: region) else {
            debug.notes.append("这张图量不出墨迹")
            return Result(debug: debug)
        }
        if region == nil {
            debug.notes.append("没框出票面在照片里的位置，只能按整张照片量 —— 判据会偏")
        }
        if let tilt, abs(tilt) > 0.0005 {
            let degrees = atan(tilt) * 180 / .pi
            debug.notes.append(String(format: "票面还歪着 %.2f°（按文字行量的），投影方向跟着斜", degrees))
        }

        let rules = DashedRuleDetector.rules(in: mask, tilt: tilt)
        debug.notes.append("虚线候选：票面 \(mask.rowBands().count) 条横带，命中 \(rules.count) 条")
        debug.baselines = rules.enumerated().map { index, rule in
            baseline(rule, label: index == 0 ? "上虚线" : "下虚线", mask: mask)
        }

        guard var frame = TicketFrame.between(rules: rules, in: mask) else {
            if !expectsRules {
                debug.notes.append("这个彩种票面上没有虚线，基准要用哈希行 + 开奖期行（阶段 3）")
            } else if rules.count < 2 {
                debug.notes.append("没找到上下两条虚线 —— 多半是裁切时把号码区上下那两条线切掉了")
            } else {
                debug.notes.append("找到 \(rules.count) 条虚线，多于两条时不猜是哪两条，整个退回")
            }
            return Result(debug: debug)
        }

        frame.leftBoundary = leftBoundary
        let top: CGFloat = Swift.min(frame.topLeft.y, frame.topRight.y)
        let bottom: CGFloat = Swift.max(frame.bottomLeft.y, frame.bottomRight.y)
        frame.rightBoundary = TicketFrame.multiplierBoundary(fragments, within: top...bottom,
                                                             contentWidth: contentWidth)
        // 票头区：期号 + 开奖日期（体彩连中间那行机号一起）。
        // 底边和号码区共用同一条基准，所以两块严丝合缝。
        if let issue = TicketFrame.issueTop(fragments, above: top) {
            frame = frame.addingHead(topAt: issue)
        }
        debug.anchor = frame.anchor
        debug.zones = [.init(label: "号码区", corners: frame.corners, isPrimary: true)]
        if let head = frame.headCorners {
            debug.zones.append(.init(label: "票头：期号·开奖日期", corners: head))
        } else {
            debug.notes.append("没框出期号那一行，票头区空着")
        }
        if let left = frame.leftBoundary {
            debug.boundaries.append(.init(label: "左：注序号列右侧", x: left))
        } else {
            debug.notes.append("没认出注序号那一列，左边界空着")
        }
        if let right = frame.rightBoundary {
            debug.boundaries.append(.init(label: "右：倍数列左侧", x: right))
        } else {
            debug.notes.append("没认出行尾的倍数 (N)，右边界空着")
        }

        guard let rectified = rectified(cgImage, frame: frame) else {
            debug.notes.append("配准算得出来，但号码区裁不出图")
            return Result(frame: frame, debug: debug)
        }
        debug.cells = cells(in: rectified, frame: frame, notes: &debug.notes)
        return Result(frame: frame,
                      rectified: UIImage(cgImage: rectified),
                      debug: debug)
    }

    private static func baseline(_ rule: DashedRule,
                                 label: String,
                                 mask: InkMask) -> ScanDebugReport.Baseline {
        let left = Double(rule.columns.lowerBound)
        let right = Double(rule.columns.upperBound)
        let start = mask.imagePoint(x: left, y: rule.y(at: left))
        let end = mask.imagePoint(x: right, y: rule.y(at: right))
        var dashes: [ClosedRange<CGFloat>] = []
        for segment in rule.segments {
            let low = mask.imagePoint(x: Double(segment.lowerBound), y: 0).x
            let high = mask.imagePoint(x: Double(segment.upperBound + 1), y: 0).x
            if high > low { dashes.append(low...high) }
        }
        return ScanDebugReport.Baseline(label: label, start: start, end: end, dashes: dashes)
    }

    // MARK: - 配准

    /// 号码区四边形 → 正片。CoreImage 的透视校正做的就是单应变换本身。
    static func rectified(_ cgImage: CGImage, frame: TicketFrame) -> CGImage? {
        let source = CIImage(cgImage: cgImage)
        let extent = source.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        // 归一化（左上原点）→ CoreImage 像素（左下原点）
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: extent.origin.x + normalized.x * extent.width,
                    y: extent.origin.y + (1 - normalized.y) * extent.height)
        }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = source
        filter.topLeft = point(frame.topLeft)
        filter.topRight = point(frame.topRight)
        filter.bottomLeft = point(frame.bottomLeft)
        filter.bottomRight = point(frame.bottomRight)
        filter.crop = true
        guard let output = filter.outputImage, output.extent.width > 1, output.extent.height > 1
        else { return nil }
        return TicketImagePreprocessor.context.createCGImage(output, from: output.extent)
    }

    // MARK: - 格子

    /// 配准之后的号码区里，墨迹自己划出来的格子。
    ///
    /// **这里一个比值都不用。** 行是横向投影切出来的，列是每一行自己的
    /// 纵向投影切出来的 —— 画出来的是"票面上真实的墨在哪儿"，
    /// 不是"按版式该在哪儿"。阶段 1 要先靠这张图确认配准摆正了没有；
    /// 把这些段吸附成规整的栅格（补空列、按列距对齐）是阶段 2 的事。
    static func cells(in rectified: CGImage,
                      frame: TicketFrame,
                      notes: inout [String]) -> [ScanDebugReport.Cell] {
        guard let mask = InkMask.make(rectified), mask.width > 4, mask.height > 4 else {
            notes.append("配准后的号码区量不出墨迹")
            return []
        }
        let columns = zoneColumns(frame: frame, width: mask.width)
        let span = Double(columns.upperBound - columns.lowerBound + 1)
        let profile = mask.rowProfile(rows: 0...(mask.height - 1), columns: columns)
        // 行的下限取宽度的 5%，和 measure.py 量行距时用的是同一个数
        let rows = InkMask.runs(profile, above: span * 0.05)
            .filter { $0.upperBound - $0.lowerBound + 1 >= 3 }
        guard !rows.isEmpty else {
            notes.append("配准后的号码区里没切出任何一行")
            return []
        }

        let width = CGFloat(mask.width)
        let height = CGFloat(mask.height)
        var cells: [ScanDebugReport.Cell] = []
        for (rowIndex, row) in rows.enumerated() {
            let segments = InkMask.runs(mask.columnProfile(rows: row, columns: columns), above: 0)
                .map { (columns.lowerBound + $0.lowerBound)...(columns.lowerBound + $0.upperBound) }
            // 一行切出几十段的多半不是号码行，是虚线之间夹着的合计行或者条码
            guard segments.count <= 20 else { continue }
            for (columnIndex, segment) in segments.enumerated() {
                let rect = CGRect(x: CGFloat(segment.lowerBound) / width,
                                  y: CGFloat(row.lowerBound) / height,
                                  width: CGFloat(segment.upperBound - segment.lowerBound + 1) / width,
                                  height: CGFloat(row.upperBound - row.lowerBound + 1) / height)
                guard let corners = frame.restore(rect) else { continue }
                cells.append(.init(corners: corners, row: rowIndex, column: columnIndex))
            }
        }
        notes.append("配准后切出 \(rows.count) 行、\(cells.count) 格")
        return cells
    }

    /// 号码区在标准矩形里的横向范围：左边界和右边界之间。
    /// 认不出边界就用整块 —— 宁可画宽一点，也不要拿个错的边界去切。
    private static func zoneColumns(frame: TicketFrame, width: Int) -> ClosedRange<Int> {
        /// 标准矩形里的 0–1 → 列号。落在矩形外面（边界本来就不在号码区里）
        /// 或者算出个 NaN 的，一律当没算出来 —— `Int(nan)` 是会当场崩的。
        func column(_ value: CGFloat?) -> Int? {
            guard let value, value.isFinite, value >= 0, value <= 1 else { return nil }
            return Swift.min(width - 1, Swift.max(0, Int(value * CGFloat(width))))
        }
        var low = 0
        var high = width - 1
        if let left = frame.leftBoundary, let mapped = column(frame.rectifiedX(of: left)) {
            low = Swift.min(mapped, width - 2)
        }
        if let right = frame.rightBoundary, let mapped = column(frame.rectifiedX(of: right)) {
            high = Swift.max(mapped, low + 1)
        }
        return low...Swift.min(high, width - 1)
    }
}
