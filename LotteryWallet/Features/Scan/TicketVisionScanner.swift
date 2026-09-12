import Foundation
import Vision
import UIKit

/// 用 Apple Vision 在本机识别票面文字。
/// 图片不上传、不写入数据库，识别完即释放。
enum TicketVisionScanner {

    enum ScanError: LocalizedError {
        case invalidImage
        case recognitionFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "这张图片无法读取，请重新拍摄"
            case .recognitionFailed: return "识别失败，请换一张更清晰的照片"
            }
        }
    }

    /// 一次扫描的产物：识别结果 + 那张票裁切矫正后的正片。
    struct ScannedPage {
        var result = ScanResult()
        /// 按票的 id 存正片，复核和改号的时候贴出来。
        /// 一次只扫一张票，所以这些指向的是同一张图。
        var images: [ScannedTicket.ID: UIImage] = [:]
    }

    /// 识别一张**已经裁切矫正过**的票。
    ///
    /// 找票、摆正这两步在这之前由 `TicketCropView` + `TicketImagePreprocessor`
    /// 完成，而且最终的框是用户点头的。到这里图已经是正的、放大过的，
    /// OCR 只需要认字。
    static func scan(_ image: UIImage) async throws -> ScannedPage {
        var page = ScannedPage()
        let fragments = try await recognizeFragments(in: image)
        // **不再做版面切分。**
        //
        // 递归 XY 切分是为「一张照片里几张票」写的，现在一次只认一张，
        // 它变成了纯粹的风险：一张票内部同样有整列的空白 ——
        // 右边那一竖排的机号、每注的 (3) 倍数、合计金额，正好能凑够
        // 切分要求的碎片数，于是一张完整的票被从中间劈开：
        // 左半边只剩号码没有彩种名（认不出彩种），右半边只有几个金额。
        // 两半都解析不出票，用户看到的就是「没有识别到彩票」——
        // 而且他明明裁得很准。
        //
        // 现在整块文本一起交给解析器，同一张纸上连着打两张票的情况
        // 由 `splitBlocks` 按「玩法:」这类票头来切，那是按内容切的，不会误伤。
        var result = TicketTextParser.parse(await mergedText(image: image, base: fragments))
        if result.tickets.isEmpty {
            // 再放大一遍重试。裁切之后还认不出，多半是原图本身就糊。
            if let upscaled = upscale(image, factor: 1.6),
               let retry = try? await recognizeFragments(in: upscaled) {
                let second = TicketTextParser.parse(LayoutSegmenter.lines(retry))
                if !second.tickets.isEmpty { result = second }
            }
        }
        // 一个字都没认出来和「认出字但拼不成票」是两回事，
        // 复核页要能把原文摆出来，否则用户只能干瞪眼。
        if result.rawText.isEmpty { result.rawText = LayoutSegmenter.lines(fragments) }
        page.result = result
        // 复核页每张票下面贴的那张图，裁到**有字的那一块**再给出去。
        //
        // 整张票面上下常有大片空白、底部还有一长条码 —— 原图塞进一个
        // 132pt 高的预览框里，真正要核对的彩种名、期号、号码球全被压成一条。
        // 裁掉没信息的边缘之后，同样的框里这些东西能大好几倍。
        let content = contentCrop(image, fragments: fragments) ?? image
        for ticket in result.tickets { page.images[ticket.id] = content }
        return page
    }

    // MARK: - 号码行的二次识别

    /// 中文模型 + 拉丁数字混在一起时，**间距很宽的单个数字最容易被并掉或漏掉**。
    ///
    /// 双色球和大乐透之所以准，是因为它们印的是两位数、还带 `-` `+` 分隔符，
    /// 整体是一团紧凑的字符；而排列3/5、七星彩印的是一个个孤零零的个位数，
    /// 中间空好几个字符宽 —— 这正是中文识别模型最容易把它们当成排版空白、
    /// 或者干脆并成一个 token 的地方。真实识别结果里
    /// `8 4 4 1 5` 认成 `8 4 1`、`3 6 7` 认成 `3 6`，都是这个原因。
    ///
    /// 所以号码行单独再认一遍：图放大两倍、**只挂英数模型**。
    /// 非号码行（彩种名、玩法、期号、金额）仍然用中文那一遍的结果。
    static func mergedText(image: UIImage, base: [TextFragment]) async -> String {
        let baseRows = LayoutSegmenter.rows(base)
        guard let upscaled = upscale(image, factor: 2),
              let digitFragments = try? await recognizeFragments(in: upscaled, languages: ["en-US"]) else {
            return LayoutSegmenter.lines(base)
        }
        let digitRows = LayoutSegmenter.rows(digitFragments)

        return baseRows.map { row -> String in
            let original = LayoutSegmenter.join(row)
            guard looksLikeNumberRow(original) else { return original }
            let band = LayoutSegmenter.band(row)
            // 放大不改变归一化坐标，所以两遍的纵向位置可以直接比
            let overlapping = digitRows.filter { LayoutSegmenter.band($0).overlaps(band) }
            guard let better = overlapping
                .map(LayoutSegmenter.join)
                .max(by: { digitCount($0) < digitCount($1) }),
                digitCount(better) > digitCount(original) else { return original }
            return graft(prefix: original, digits: better)
        }
        .joined(separator: "\n")
    }

    /// 这一行看着像不像一排号码：数字占了绝大多数。
    ///
    /// 判松了会把「开奖期:2026091 26-04-11 合计10元」也送去数字识别 ——
    /// 那一行恰恰需要中文才能读出「合计」和「开奖期」。
    static func looksLikeNumberRow(_ text: String) -> Bool {
        let meaningful = text.filter { !$0.isWhitespace }
        guard meaningful.count >= 3 else { return false }
        let digits = meaningful.filter(\.isNumber).count
        return Double(digits) / Double(meaningful.count) >= 0.6
    }

    private static func digitCount(_ text: String) -> Int {
        text.filter(\.isNumber).count
    }

    /// 保留原行开头的非数字部分（`A.`、`组六:`、`①`），号码换成数字那一遍的。
    ///
    /// 前缀必须留着 —— 玩法和注序号都在那里，而只认英数的那一遍读不出中文。
    private static func graft(prefix original: String, digits: String) -> String {
        guard let firstDigit = original.firstIndex(where: { $0.isNumber || $0 == "-" }) else {
            return digits
        }
        let head = original[original.startIndex..<firstDigit]
        // 纯空白的前缀没有意义，别在行首留一串空格
        let trimmedHead = head.trimmingCharacters(in: .whitespaces)
        guard !trimmedHead.isEmpty else { return digits }
        return "\(trimmedHead) \(digits.trimmingCharacters(in: .whitespaces))"
    }

    /// 票面最后一行**有意义的内容**通常带着这些词。
    ///
    /// 它们下面那一截 —— 条形码、以及「XX市福利彩票发行中心承销」这类落款 ——
    /// 核对时一点用都没有，却占掉预览框近一半高度。福彩票尤其明显：
    /// 落款那行字也会被 OCR 认出来，于是"所有文字的并集"把条码整个圈了进去。
    private static let footerAnchors = ["公益", "合计", "开奖期", "销售期", "兑奖", "有效期"]

    /// 丢掉落款行以下的碎片。
    ///
    /// 认不出任何锚点时原样返回 —— 宁可裁得松一点，也不能因为一条启发式规则
    /// 把号码那几行切掉。
    static func fragmentsAboveFooter(_ fragments: [TextFragment]) -> [TextFragment] {
        // Vision 的 y 向上为正，所以「更靠下」= minY 更小
        let anchors = fragments.filter { fragment in
            footerAnchors.contains { fragment.text.contains($0) }
        }
        guard let bottom = anchors.map(\.box.minY).min() else { return fragments }
        let kept = fragments.filter { $0.box.minY >= bottom - 0.005 }
        guard let full = span(of: fragments), let trimmed = span(of: kept) else { return fragments }
        // 砍掉一多半就不对劲了，多半是锚点认错了位置，退回原样更安全
        guard trimmed >= full * 0.5 else { return fragments }
        return kept
    }

    private static func span(of fragments: [TextFragment]) -> CGFloat? {
        guard let low = fragments.map(\.box.minY).min(),
              let high = fragments.map(\.box.maxY).max() else { return nil }
        return high - low
    }

    /// 按识别到的文字把图裁到内容区。
    ///
    /// Vision 的框是归一化坐标、原点在**左下角**，UIImage 是左上角，
    /// 所以 y 要翻过来。四周各留一点余量，免得贴着字边切、看着发憋。
    static func contentCrop(_ image: UIImage, fragments: [TextFragment]) -> UIImage? {
        guard !fragments.isEmpty, let cgImage = image.cgImage else { return nil }
        let kept = fragmentsAboveFooter(fragments)
        guard let first = kept.first else { return nil }
        let union = kept.dropFirst().reduce(first.box) { $0.union($1.box) }
        // 几乎占满整张图就没必要裁了，白费一次重绘
        guard union.width < 0.97 || union.height < 0.94 else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let padX = width * 0.02
        let padY = height * 0.02
        var rect = CGRect(x: union.minX * width - padX,
                          // 归一化 y 向上，位图 y 向下
                          y: (1 - union.maxY) * height - padY,
                          width: union.width * width + padX * 2,
                          height: union.height * height + padY * 2)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width > 40, rect.height > 40,
              let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - 文字识别

    /// 一块识别出来的文字及其在画面里的位置。
    struct TextFragment: Sendable {
        let text: String
        /// Vision 归一化坐标，原点在**左下角**。
        let box: CGRect
    }

    static func recognizeFragments(in image: UIImage,
                                   languages: [String] = ["zh-Hans", "en-US"]) async throws -> [TextFragment] {
        guard let cgImage = image.cgImage else { throw ScanError.invalidImage }
        let orientation = cgOrientation(image.imageOrientation)

        // Vision 的 perform 是同步的，放到后台线程跑，避免阻塞主线程。
        let observations: [VNRecognizedTextObservation] = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            // 彩票号码不是自然语言，语言纠正只会把号码改坏
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.008

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try handler.perform([request])
            return request.results ?? []
        }.value

        let fragments = observations.compactMap { observation -> TextFragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return TextFragment(text: text, box: observation.boundingBox)
        }
        guard !fragments.isEmpty else { throw ScanError.recognitionFailed }
        return fragments
    }

    /// 兼容旧调用：整张图当成一块，拼成逐行文本。
    static func recognizeText(in image: UIImage) async throws -> String {
        LayoutSegmenter.lines(try await recognizeFragments(in: image))
    }

    private static func upscale(_ image: UIImage, factor: CGFloat) -> UIImage? {
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        guard size.width < 8000, size.height < 8000 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

/// 把识别出来的文字块按版面切成「一张票一块」。
///
/// 一张照片里放两三张票是很常见的（用户就是这么拍的）。如果先把所有文字块
/// 按纵坐标拼成一整篇文本，并排的两张票会被拼进**同一行** ——
/// 「红单:12 14 …」和另一张的「红复: 4 8 …」串在一起，两张票都读不出来。
///
/// 这里用的是版面分析里最经典的**递归 XY 切分**：先找横向上完全空白的
/// 竖直缝把左右分开，再找纵向上完全空白的横缝把上下分开，如此递归。
/// 「完全空白」这个条件很关键 —— 票面内部虽然也有大段留白（比如
/// 「玩法:双色球-复式」和右边的机号之间），但总有别的行横跨那个位置，
/// 所以不会被误切。
enum LayoutSegmenter {
    /// 缝隙要有多宽才算「两张票之间」，按当前这块的尺寸取比例。
    private static let columnGap: CGFloat = 0.055
    private static let rowGap: CGFloat = 0.045
    /// 一张票至少要有这么多块文字，否则不值得再切。
    private static let minimumFragments = 6
    private static let maximumDepth = 4

    static func blocks(from fragments: [TicketVisionScanner.TextFragment]) -> [String] {
        let groups = split(fragments, depth: 0)
        let texts = groups.map { lines($0) }.filter { $0.contains(where: \.isNumber) }
        return texts.isEmpty ? [lines(fragments)] : texts
    }

    private static func split(_ fragments: [TicketVisionScanner.TextFragment], depth: Int) -> [[TicketVisionScanner.TextFragment]] {
        guard depth < maximumDepth, fragments.count >= minimumFragments * 2 else { return [fragments] }
        if let parts = cut(fragments, vertical: true) ?? cut(fragments, vertical: false) {
            return parts.flatMap { split($0, depth: depth + 1) }
        }
        return [fragments]
    }

    /// 找一条把这组文字一分为二的空白缝。`vertical` 为真时找竖缝（左右分栏）。
    private static func cut(_ fragments: [TicketVisionScanner.TextFragment],
                            vertical: Bool) -> [[TicketVisionScanner.TextFragment]]? {
        let intervals = fragments.map { fragment -> (lower: CGFloat, upper: CGFloat) in
            vertical ? (fragment.box.minX, fragment.box.maxX)
                     : (fragment.box.minY, fragment.box.maxY)
        }.sorted { $0.lower < $1.lower }
        // 注意取的是所有区间里最大的 upper，不是最后一个区间的 —— 排序按的是 lower，
        // 最后一个区间未必伸得最远。
        guard let span = intervals.map(\.upper).max(),
              let start = intervals.first?.lower, span > start else { return nil }
        let threshold = (span - start) * (vertical ? columnGap : rowGap)
        guard threshold > 0 else { return nil }

        var reach = intervals[0].upper
        var bestCut: CGFloat?
        var widestGap: CGFloat = threshold
        for interval in intervals.dropFirst() {
            let gap = interval.lower - reach
            if gap > widestGap {
                widestGap = gap
                bestCut = reach + gap / 2
            }
            reach = Swift.max(reach, interval.upper)
        }
        guard let cut = bestCut else { return nil }

        let low = fragments.filter { (vertical ? $0.box.midX : $0.box.midY) < cut }
        let high = fragments.filter { (vertical ? $0.box.midX : $0.box.midY) >= cut }
        // 切出来两边都得像一张票，否则宁可不切
        guard low.count >= minimumFragments, high.count >= minimumFragments else { return nil }
        return [low, high]
    }

    /// 把一组文字块按纵坐标聚成行、行内按横坐标排序，拼成逐行文本。
    static func lines(_ fragments: [TicketVisionScanner.TextFragment]) -> String {
        rows(fragments).map(join).joined(separator: "\n")
    }

    /// 一行里的碎片按 x 排好拼成文本。
    static func join(_ row: [TicketVisionScanner.TextFragment]) -> String {
        row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
    }

    /// 这一行占的纵向区间。两遍识别靠它对齐同一行。
    static func band(_ row: [TicketVisionScanner.TextFragment]) -> ClosedRange<CGFloat> {
        let lower = row.map(\.box.minY).min() ?? 0
        let upper = row.map(\.box.maxY).max() ?? 0
        return Swift.min(lower, upper)...Swift.max(lower, upper)
    }

    /// 把碎片按纵向位置聚成一行一行。
    static func rows(_ fragments: [TicketVisionScanner.TextFragment]) -> [[TicketVisionScanner.TextFragment]] {
        guard !fragments.isEmpty else { return [] }
        // Vision 的坐标原点在左下角，纵坐标要倒过来排
        let sorted = fragments.sorted { $0.box.midY > $1.box.midY }
        let averageHeight = fragments.map(\.box.height).reduce(0, +) / CGFloat(fragments.count)
        let tolerance = Swift.max(averageHeight * 0.6, 0.006)

        var rows: [[TicketVisionScanner.TextFragment]] = []
        for fragment in sorted {
            if var last = rows.last, let anchor = last.first,
               abs(anchor.box.midY - fragment.box.midY) <= tolerance {
                last.append(fragment)
                rows[rows.count - 1] = last
            } else {
                rows.append([fragment])
            }
        }
        return rows
    }
}
