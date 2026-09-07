import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// 识别之前的预处理。这一步的价值在 OCR 开始之前就决定了上限：
// 用户拍的照片千奇百怪 —— 票是斜的、有透视、只占画面一小角。
// 把原图直接丢给 OCR，等于让它同时对付倾斜的字和糊掉的小字。
//
// 所以先摆正、再放大。而「哪一块是票」这件事交给用户框 ——
// 全自动检测的准确率上不去，错了用户还完全看不见错在哪。

/// 票面的四个角。归一化坐标，**左上角为原点**（和 UI 一致，不是 Vision 的左下角）。
struct TicketQuad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// 找不到票时的默认框：四周留 8% 的边。
    static let `default` = TicketQuad(topLeft: CGPoint(x: 0.08, y: 0.08),
                                      topRight: CGPoint(x: 0.92, y: 0.08),
                                      bottomRight: CGPoint(x: 0.92, y: 0.92),
                                      bottomLeft: CGPoint(x: 0.08, y: 0.92))

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    subscript(index: Int) -> CGPoint {
        get { corners[index] }
        set {
            switch index {
            case 0: topLeft = newValue
            case 1: topRight = newValue
            case 2: bottomRight = newValue
            default: bottomLeft = newValue
            }
        }
    }
}

enum TicketImagePreprocessor {
    /// 矫正后短边至少要有这么多像素。热敏票的字很小，低于这个数 OCR 认不准。
    private static let minimumShortSide: CGFloat = 1500
    /// 上限防止内存爆掉。
    private static let maximumSide: CGFloat = 4400

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// 猜一个票面框，给裁切界面当起点。
    ///
    /// 猜中了用户一下都不用动，猜不中他拖两下就好 —— 关键是**最终由用户说了算**。
    /// 之前那版全自动：检测不到就整图识别，检测错了用户毫不知情，
    /// 一张照片里几张票还得靠版面切分去猜谁是谁。准确率上不去，
    /// 而且错在哪儿完全不可见。
    static func suggestedQuad(in image: UIImage) async -> TicketQuad? {
        guard let cgImage = image.cgImage else { return nil }
        let orientation = cgOrientation(image.imageOrientation)

        let observation: VNRectangleObservation? = await Task.detached(priority: .userInitiated) {
            let request = VNDetectRectanglesRequest()
            request.minimumAspectRatio = 0.25
            request.maximumAspectRatio = 1.0
            request.minimumSize = 0.15
            request.maximumObservations = 6
            request.minimumConfidence = 0.5
            // 手持拍摄几乎不可能正对着，得容忍相当的透视畸变
            request.quadratureTolerance = 40

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try? handler.perform([request])
            // 取面积最大的那个：票总是画面里最大的那张纸
            return (request.results ?? []).max {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
            }
        }.value

        guard let observation else { return nil }
        // Vision 的原点在左下角，翻成左上角
        func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: 1 - point.y) }
        return TicketQuad(topLeft: flip(observation.topLeft),
                          topRight: flip(observation.topRight),
                          bottomRight: flip(observation.bottomRight),
                          bottomLeft: flip(observation.bottomLeft))
    }

    /// 按用户框好的四个角做透视矫正 —— 斜的、带角度的票都被拉成正的矩形 ——
    /// 再按短边补到 OCR 够用的分辨率。
    static func correct(_ image: UIImage, quad: TicketQuad) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let source = CIImage(cgImage: cgImage).oriented(cgOrientation(image.imageOrientation))
        let extent = source.extent

        // 归一化（左上原点）→ CoreImage 坐标（左下原点）
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: extent.origin.x + normalized.x * extent.width,
                    y: extent.origin.y + (1 - normalized.y) * extent.height)
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = source
        filter.topLeft = point(quad.topLeft)
        filter.topRight = point(quad.topRight)
        filter.bottomLeft = point(quad.bottomLeft)
        filter.bottomRight = point(quad.bottomRight)
        filter.crop = true
        guard let corrected = filter.outputImage else { return nil }
        return render(corrected)
    }

    /// 放大到 OCR 够用的分辨率。
    private static func render(_ image: CIImage) -> UIImage? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.width.isFinite, extent.height.isFinite else { return nil }

        let shortSide = Swift.min(extent.width, extent.height)
        let longSide = Swift.max(extent.width, extent.height)
        var scale = Swift.max(1, minimumShortSide / shortSide)
        scale = Swift.min(scale, maximumSide / longSide)

        var output = image
        if scale > 1.01 {
            output = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
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
