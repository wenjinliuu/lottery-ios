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

    static let context = CIContext(options: [.useSoftwareRenderer: false])

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

    /// 裁切 → 摆正 → 拉平 → 放大，一条龙。
    static func prepare(_ image: UIImage, quad: TicketQuad) async -> UIImage {
        let corrected = correct(image, quad: quad) ?? image
        return await deskewed(corrected)
    }

    /// 二次水平矫正：把票面上的文字基线拉平。
    ///
    /// 透视矫正只保证**四个角**落在矩形的四个角上，不保证**文字是平的**。
    /// 用户框的时候手一抖框成个梯形，或者票本身是斜着印在纸上的，
    /// 矫正完四个角是正的，里面的字仍然带着一两度的倾斜。
    ///
    /// 一两度看着不明显，对 OCR 却是实打实的损失：一行号码横跨大半张票，
    /// 1.5° 的倾斜在行尾就是十几个像素的落差，够让识别把一行拆成两段、
    /// 或者把上下两行的数字串到一起 —— 这就是「明明裁得很准却识别错位」。
    ///
    /// 做法是先做一次**廉价的**文字区域检测（不识别内容，只找位置），
    /// 量出所有文字行基线角度的中位数，再反向转回来。用中位数而不是平均值：
    /// 票上总有几个歪的印章、手写字，平均值会被它们拽跑。
    static func deskewed(_ image: UIImage) async -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let angles: [Double] = await Task.detached(priority: .userInitiated) {
            let request = VNDetectTextRectanglesRequest()
            request.reportCharacterBoxes = false
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            try? handler.perform([request])
            let width = Double(cgImage.width)
            let height = Double(cgImage.height)
            return (request.results ?? []).compactMap { observation -> Double? in
                // 归一化坐标是各向异性的（x 除以宽、y 除以高），
                // 直接拿它算角度在非正方形的图上会算错，必须先换回像素。
                let dx = Double(observation.topRight.x - observation.topLeft.x) * width
                let dy = Double(observation.topRight.y - observation.topLeft.y) * height
                // 太短的文字块量出来的角度噪声太大，丢掉
                guard hypot(dx, dy) > width * 0.08 else { return nil }
                return atan2(dy, dx)
            }
        }.value

        guard angles.count >= 3 else { return image }
        let sorted = angles.sorted()
        let median = sorted[sorted.count / 2]

        // 超过 12° 基本不是「有点歪」，而是检测本身出了问题，别乱转
        let degrees = median * 180 / .pi
        guard abs(degrees) > 0.35, abs(degrees) < 12 else { return image }

        // Vision 的 y 轴向上，图像的 y 轴向下，所以这里**不用**再取负号：
        // 正的 median（文字向右上走）在 CoreImage 里正好也是逆时针转正。
        let source = CIImage(cgImage: cgImage)
        let rotated = source.transformed(by: CGAffineTransform(rotationAngle: -median))
        return render(rotated) ?? image
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
