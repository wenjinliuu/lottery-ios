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
        var result = TicketTextParser.parse(blocks: LayoutSegmenter.blocks(from: fragments))
        if result.tickets.isEmpty {
            // 再放大一遍重试。裁切之后还认不出，多半是原图本身就糊。
            if let upscaled = upscale(image, factor: 1.6),
               let retry = try? await recognizeFragments(in: upscaled) {
                let second = TicketTextParser.parse(blocks: LayoutSegmenter.blocks(from: retry))
                if !second.tickets.isEmpty { result = second }
            }
        }
        page.result = result
        for ticket in result.tickets { page.images[ticket.id] = image }
        return page
    }

    // MARK: - 文字识别

    /// 一块识别出来的文字及其在画面里的位置。
    struct TextFragment: Sendable {
        let text: String
        /// Vision 归一化坐标，原点在**左下角**。
        let box: CGRect
    }

    static func recognizeFragments(in image: UIImage) async throws -> [TextFragment] {
        guard let cgImage = image.cgImage else { throw ScanError.invalidImage }
        let orientation = cgOrientation(image.imageOrientation)

        // Vision 的 perform 是同步的，放到后台线程跑，避免阻塞主线程。
        let observations: [VNRecognizedTextObservation] = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
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
        guard !fragments.isEmpty else { return "" }
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
            .map { row in
                row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
            }
            .joined(separator: "\n")
    }
}
