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

    static func scan(_ image: UIImage) async throws -> ScanResult {
        let text = try await recognizeText(in: image)
        var result = TicketTextParser.parse(text)
        if result.tickets.isEmpty {
            // 一次没认出来就把图片放大再来一遍，热敏票小字很吃分辨率
            if let upscaled = upscale(image, factor: 2),
               let retryText = try? await recognizeText(in: upscaled) {
                let retry = TicketTextParser.parse(retryText)
                if !retry.tickets.isEmpty { result = retry }
            }
        }
        return result
    }

    /// 逐行还原文本：Vision 返回的是散块，按纵向分行、横向排序后再拼。
    static func recognizeText(in image: UIImage) async throws -> String {
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

        guard !observations.isEmpty else { throw ScanError.recognitionFailed }

        struct Fragment {
            let text: String
            let midY: CGFloat
            let minX: CGFloat
            let height: CGFloat
        }

        let fragments = observations.compactMap { observation -> Fragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return Fragment(text: candidate.string,
                            midY: box.midY,
                            minX: box.minX,
                            height: box.height)
        }
        guard !fragments.isEmpty else { throw ScanError.recognitionFailed }

        // Vision 的坐标原点在左下角，纵坐标要倒过来排
        let sorted = fragments.sorted { $0.midY > $1.midY }
        let averageHeight = fragments.map(\.height).reduce(0, +) / CGFloat(fragments.count)
        let lineTolerance = Swift.max(averageHeight * 0.6, 0.008)

        var lines: [[Fragment]] = []
        for fragment in sorted {
            if var last = lines.last, let anchor = last.first, abs(anchor.midY - fragment.midY) <= lineTolerance {
                last.append(fragment)
                lines[lines.count - 1] = last
            } else {
                lines.append([fragment])
            }
        }

        return lines
            .map { line in
                line.sorted { $0.minX < $1.minX }
                    .map(\.text)
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
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
