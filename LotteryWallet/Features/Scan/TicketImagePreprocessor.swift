import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// 拍照后的预处理：找出画面里的每一张票，摆正、裁下来、放大。
///
/// 这一步的价值在识别之前就决定了上限。用户拍的照片千奇百怪：
/// 票是斜的、有透视、几张票横着竖着乱摆、票只占画面一小块。
/// 把整张原图直接丢给 OCR，等于让它同时对付倾斜的字、糊掉的小字、
/// 还有几张票串在一起的版面 —— 每一样都会掉准确率。
///
/// 所以先做三件事：
/// 1. **找票**：矩形检测把每张票的四个角找出来；
/// 2. **摆正**：按那四个角做透视矫正，斜的、带角度的票都被拉成正的矩形；
/// 3. **放大**：矫正之后按短边补到足够分辨率，小票上的热敏小字才认得清。
///
/// 找不到票就退回整张图 —— 宁可少做，不能把唯一一张票裁没了。
enum TicketImagePreprocessor {

    /// 一张裁切矫正后的票。
    struct Region {
        let image: UIImage
        /// 矩形检测给的置信度，用来排序。
        let confidence: Float
        /// 在原图里的位置（归一化，左上原点），用来把多张票按阅读顺序排。
        let frame: CGRect
    }

    /// 矫正后短边至少要有这么多像素。热敏票的字很小，低于这个数 OCR 认不准。
    private static let minimumShortSide: CGFloat = 1400
    /// 上限防止内存爆掉。
    private static let maximumSide: CGFloat = 4200

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func regions(in image: UIImage) async -> [Region] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = cgOrientation(image.imageOrientation)

        let observations: [VNRectangleObservation] = await Task.detached(priority: .userInitiated) {
            let request = VNDetectRectanglesRequest()
            // 彩票基本都是竖长条，但照片里可能横着放，所以两个方向都要覆盖。
            request.minimumAspectRatio = 0.28
            request.maximumAspectRatio = 1.0
            // 一张票至少要占画面的这个比例，太小的多半是二维码、条码或者背景里的纸片
            request.minimumSize = 0.14
            request.maximumObservations = 8
            request.minimumConfidence = 0.55
            // 允许一定的透视畸变 —— 手持拍摄几乎不可能是正对着的
            request.quadratureTolerance = 38

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try? handler.perform([request])
            return request.results ?? []
        }.value

        guard !observations.isEmpty else { return [] }

        let source = CIImage(cgImage: cgImage).oriented(orientation)
        let extent = source.extent

        var regions: [Region] = []
        for observation in observations {
            guard let corrected = rectify(source, observation: observation, extent: extent),
                  let output = render(corrected) else { continue }
            // Vision 的原点在左下角，换成左上角好按阅读顺序排
            let box = observation.boundingBox
            let frame = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            regions.append(Region(image: output, confidence: observation.confidence, frame: frame))
        }

        // 只留下互不重叠的那些：矩形检测经常把同一张票和它内部的某一块
        // 都报上来，不去重就会把同一张票识别两遍。
        return readingOrder(deduplicate(regions))
    }

    // MARK: - 摆正

    private static func rectify(_ source: CIImage,
                                observation: VNRectangleObservation,
                                extent: CGRect) -> CIImage? {
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: extent.origin.x + normalized.x * extent.width,
                    y: extent.origin.y + normalized.y * extent.height)
        }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = source
        filter.topLeft = point(observation.topLeft)
        filter.topRight = point(observation.topRight)
        filter.bottomLeft = point(observation.bottomLeft)
        filter.bottomRight = point(observation.bottomRight)
        // crop 打开之后输出就是矫正后的那块矩形，不带原图其余部分
        filter.crop = true
        return filter.outputImage
    }

    /// 放大到 OCR 够用的分辨率。
    private static func render(_ image: CIImage) -> UIImage? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.width.isFinite, extent.height.isFinite else { return nil }

        let shortSide = Swift.min(extent.width, extent.height)
        var scale = Swift.max(1, minimumShortSide / shortSide)
        // 别把长边顶爆
        let longSide = Swift.max(extent.width, extent.height)
        scale = Swift.min(scale, maximumSide / longSide)

        var output = image
        if scale > 1.01 {
            output = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - 去重与排序

    /// 面积大的优先；和已选区域重叠超过一半的丢掉。
    private static func deduplicate(_ regions: [Region]) -> [Region] {
        let sorted = regions.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        var kept: [Region] = []
        for region in sorted {
            let overlaps = kept.contains { existing in
                let intersection = existing.frame.intersection(region.frame)
                guard !intersection.isNull else { return false }
                let area = intersection.width * intersection.height
                let smaller = Swift.min(existing.frame.width * existing.frame.height,
                                        region.frame.width * region.frame.height)
                return smaller > 0 && area / smaller > 0.5
            }
            if !overlaps { kept.append(region) }
        }
        return kept
    }

    /// 按阅读顺序：先上后下，同一"行"里先左后右。
    /// 用户拍两张并排的票时，期望的顺序就是从左到右。
    private static func readingOrder(_ regions: [Region]) -> [Region] {
        regions.sorted { lhs, rhs in
            // 纵向重叠过半就算同一行
            let sameRow = abs(lhs.frame.midY - rhs.frame.midY) < Swift.max(lhs.frame.height, rhs.frame.height) * 0.5
            if sameRow { return lhs.frame.minX < rhs.frame.minX }
            return lhs.frame.minY < rhs.frame.minY
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
