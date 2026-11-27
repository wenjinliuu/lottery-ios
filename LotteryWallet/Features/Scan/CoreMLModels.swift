import Foundation
import CoreML
import CoreGraphics
import UIKit

/// 端侧全离线 CoreML 模型族（v3）：
/// 1. `TicketDetector.mlpackage`   — 全图多票四顶点检测（384×384）
/// 2. `ZoneLayout.mlpackage`       — 拉正票面三区域定位：票头 / 号码区 / 元数据区（256×192）
/// 3. `TicketHeaderMeta.mlpackage` — 票头多头视觉识别：9 类彩种 + 5 类玩法 + 追加 + 快乐8选几（128×256）
/// 4. `LotteryLineOCR.mlpackage`   — 号码区整行 CRNN+CTC 序列识别（32×640）
/// 5. `MetaFieldOCR.mlpackage`     — 元数据行 CRNN+CTC 序列识别：期号/开奖日/合计/倍数/期数/追加（32×512）
///
/// 所有预处理与后处理均与 `lottery-ocr` 训练脚本逐项对齐，并拆出纯 Swift 静态函数供单元测试直接对拍。
enum CoreMLBundle {
    static func load(_ name: String) -> MLModel? {
        let bundles = [Bundle(for: AppDelegate.self), Bundle.main]
        let subdirectories: [String?] = [nil, "Models", "Resources/Models"]
        for bundle in bundles {
            for subdirectory in subdirectories {
                guard let url = bundle.url(forResource: name, withExtension: "mlmodelc", subdirectory: subdirectory) else {
                    continue
                }
                let config = MLModelConfiguration()
                config.computeUnits = .all
                if let model = try? MLModel(contentsOf: url, configuration: config) {
                    return model
                }
            }
        }
        return nil
    }

    static func makeInput(shape: [Int], values: [Float]) -> MLMultiArray? {
        guard let array = try? MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32) else {
            return nil
        }
        let count = min(array.count, values.count)
        let strides = array.strides.map(\.intValue)
        if isContiguous(shape: shape, strides: strides) {
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            values.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { ptr.update(from: base, count: count) }
            }
            return array
        }
        let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
        var coords = [Int](repeating: 0, count: shape.count)
        for linear in 0..<count {
            var offset = 0
            for dim in 0..<shape.count { offset += coords[dim] * strides[dim] }
            ptr[offset] = values[linear]
            for dim in stride(from: shape.count - 1, through: 0, by: -1) {
                coords[dim] += 1
                if coords[dim] < shape[dim] { break }
                coords[dim] = 0
            }
        }
        return array
    }

    static func readFloats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        guard count > 0 else { return [] }
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        if isContiguous(shape: shape, strides: strides), array.dataType == .float32 {
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }
        var out = [Float](repeating: 0, count: count)
        var coords = [Int](repeating: 0, count: shape.count)
        let f32Ptr = array.dataType == .float32 ? array.dataPointer.assumingMemoryBound(to: Float.self) : nil
        for linear in 0..<count {
            var offset = 0
            for dim in 0..<shape.count { offset += coords[dim] * strides[dim] }
            out[linear] = f32Ptr?[offset] ?? array[offset].floatValue
            for dim in stride(from: shape.count - 1, through: 0, by: -1) {
                coords[dim] += 1
                if coords[dim] < shape[dim] { break }
                coords[dim] = 0
            }
        }
        return out
    }

    private static func isContiguous(shape: [Int], strides: [Int]) -> Bool {
        guard shape.count == strides.count else { return false }
        var expected = 1
        for dim in stride(from: shape.count - 1, through: 0, by: -1) {
            if strides[dim] != expected { return false }
            expected *= max(shape[dim], 1)
        }
        return true
    }

    /// 把 `CGImage` 缩放到 `(width, height)` 并按 RGB `[0, 1]` CHW 排布输出。
    static func rgbCHW(_ cgImage: CGImage, width: Int, height: Int) -> [Float]? {
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let plane = width * height
        var chw = [Float](repeating: 0, count: 3 * plane)
        let scale: Float = 1.0 / 255.0
        for idx in 0..<plane {
            let base = idx * 4
            chw[idx] = Float(rgba[base]) * scale
            chw[plane + idx] = Float(rgba[base + 1]) * scale
            chw[2 * plane + idx] = Float(rgba[base + 2]) * scale
        }
        return chw
    }

    /// 红通道条带 → `(targetHeight, targetWidth)` 归一化墨迹浮点图（墨≈1、纸≈0，左对齐右侧补 0）。
    /// 与 `line_model.py:preprocess_row`、`meta_field_model.py:preprocess_meta_strip` 逐步一致。
    static func preprocessStrip(_ gray: [UInt8], width: Int, height: Int,
                                targetHeight: Int, targetWidth: Int) -> [Float] {
        guard width > 0, height > 0, gray.count == width * height, targetHeight > 0, targetWidth > 0 else {
            return [Float](repeating: 0, count: max(targetHeight * targetWidth, 0))
        }
        let sorted = gray.sorted()
        let p05 = Float(sorted[Int(floor(0.05 * Double(sorted.count - 1)))])
        let p95 = Float(sorted[Int(floor(0.95 * Double(sorted.count - 1)))])
        let denom = (p95 - p05) + 1e-6
        var ink = [Float](repeating: 0, count: width * height)
        for i in 0..<gray.count {
            let v = (p95 - Float(gray[i])) / denom
            ink[i] = min(max(v, 0), 1)
        }
        let scale = Double(targetHeight) / Double(height)
        let newW = max(1, min(targetWidth, Int((Double(width) * scale).rounded())))
        var canvas = [Float](repeating: 0, count: targetHeight * targetWidth)
        let downsample = newW < width || targetHeight < height
        if downsample {
            let stepX = Double(width) / Double(newW)
            let stepY = Double(height) / Double(targetHeight)
            for ty in 0..<targetHeight {
                let sy0 = Double(ty) * stepY
                let sy1 = Double(ty + 1) * stepY
                let iy0 = max(0, Int(floor(sy0)))
                let iy1 = min(height, max(iy0 + 1, Int(ceil(sy1))))
                for tx in 0..<newW {
                    let sx0 = Double(tx) * stepX
                    let sx1 = Double(tx + 1) * stepX
                    let ix0 = max(0, Int(floor(sx0)))
                    let ix1 = min(width, max(ix0 + 1, Int(ceil(sx1))))
                    var sum: Float = 0
                    var weight: Float = 0
                    for y in iy0..<iy1 {
                        let wy = Float(min(Double(y + 1), sy1) - max(Double(y), sy0))
                        guard wy > 0 else { continue }
                        let rowBase = y * width
                        for x in ix0..<ix1 {
                            let wx = Float(min(Double(x + 1), sx1) - max(Double(x), sx0))
                            guard wx > 0 else { continue }
                            let w = wx * wy
                            sum += ink[rowBase + x] * w
                            weight += w
                        }
                    }
                    canvas[ty * targetWidth + tx] = weight > 0 ? (sum / weight) : 0
                }
            }
        } else {
            for ty in 0..<targetHeight {
                let sy = (Double(ty) + 0.5) * Double(height) / Double(targetHeight) - 0.5
                let cy = min(max(sy, 0), Double(height - 1))
                let y0 = Int(cy), y1 = min(y0 + 1, height - 1)
                let fy = Float(cy - Double(y0))
                for tx in 0..<newW {
                    let sx = (Double(tx) + 0.5) * Double(width) / Double(newW) - 0.5
                    let cx = min(max(sx, 0), Double(width - 1))
                    let x0 = Int(cx), x1 = min(x0 + 1, width - 1)
                    let fx = Float(cx - Double(x0))
                    let top = ink[y0 * width + x0] * (1 - fx) + ink[y0 * width + x1] * fx
                    let bot = ink[y1 * width + x0] * (1 - fx) + ink[y1 * width + x1] * fx
                    canvas[ty * targetWidth + tx] = top * (1 - fy) + bot * fy
                }
            }
        }
        return canvas
    }
}

// MARK: - 1. TicketDetector（全图多票四顶点检测）

final class CoreMLTicketDetector {
    static let inputSize = 384
    static let stride = 8
    static let grid = 48

    enum Kind: String, Equatable {
        case welfare, sports, unsupported
    }

    struct LetterboxMeta: Equatable {
        var scale: Double
        var padX: Int
        var padY: Int
        var origWidth: Double
        var origHeight: Double
        var size: Int
    }

    struct Detection: Equatable {
        var kind: Kind
        var score: Float
        /// 原图像素坐标（左上原点），规范顺序 `[TL, TR, BR, BL]`。
        var corners: [CGPoint]
    }

    static let shared: CoreMLTicketDetector? = CoreMLBundle.load("TicketDetector").map(CoreMLTicketDetector.init)
    private let model: MLModel

    private init(model: MLModel) {
        self.model = model
    }

    static func letterboxMeta(width: Double, height: Double, size: Int = inputSize) -> LetterboxMeta {
        let w = max(width, 1), h = max(height, 1)
        let scale = min(Double(size) / w, Double(size) / h)
        let nw = max(1, Int((w * scale).rounded()))
        let nh = max(1, Int((h * scale).rounded()))
        let padX = (size - nw) / 2
        let padY = (size - nh) / 2
        return LetterboxMeta(scale: scale, padX: padX, padY: padY, origWidth: w, origHeight: h, size: size)
    }

    /// 把 4 个点规范排序为 `[TL, TR, BR, BL]`（与 `detector_model.py:order_quad` 一致）。
    static func orderQuad(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count == 4 else { return points }
        let tl = points.min { ($0.x + $0.y) < ($1.x + $1.y) } ?? points[0]
        let br = points.max { ($0.x + $0.y) < ($1.x + $1.y) } ?? points[2]
        let tr = points.min { ($0.y - $0.x) < ($1.y - $1.x) } ?? points[1]
        let bl = points.max { ($0.y - $0.x) < ($1.y - $1.x) } ?? points[3]
        return [tl, tr, br, bl]
    }

    static func polygonArea(_ poly: [CGPoint]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) * 0.5
    }

    /// 凸多边形交并比（Sutherland-Hodgman 裁切），与 `detector_model.py:quad_iou` 一致。
    static func quadIoU(_ q1: [CGPoint], _ q2: [CGPoint]) -> Double {
        let a1 = polygonArea(q1), a2 = polygonArea(q2)
        guard a1 >= 1, a2 >= 1 else { return 0 }
        let inter = polygonArea(clipConvex(subject: q1, clip: q2))
        let union = a1 + a2 - inter
        return union > 1e-6 ? inter / union : 0
    }

    private static func clipConvex(subject: [CGPoint], clip: [CGPoint]) -> [CGPoint] {
        guard subject.count >= 3, clip.count >= 3 else { return [] }
        // 确保裁剪多边形方向一致（屏幕坐标 y 向下，顺时针为正向）
        var clipSigned = 0.0
        for i in 0..<clip.count {
            let a = clip[i], b = clip[(i + 1) % clip.count]
            clipSigned += Double(a.x * b.y - b.x * a.y)
        }
        let clipper = clipSigned >= 0 ? clip : Array(clip.reversed())
        var output = subject
        for i in 0..<clipper.count {
            guard !output.isEmpty else { return [] }
            let cp1 = clipper[i], cp2 = clipper[(i + 1) % clipper.count]
            let input = output
            output = []
            func inside(_ p: CGPoint) -> Bool {
                Double((cp2.x - cp1.x) * (p.y - cp1.y) - (cp2.y - cp1.y) * (p.x - cp1.x)) >= -1e-9
            }
            func intersection(_ s: CGPoint, _ e: CGPoint) -> CGPoint {
                let dcX = Double(cp1.x - cp2.x), dcY = Double(cp1.y - cp2.y)
                let dpX = Double(s.x - e.x), dpY = Double(s.y - e.y)
                let n1 = Double(cp1.x * cp2.y - cp1.y * cp2.x)
                let n2 = Double(s.x * e.y - s.y * e.x)
                let denom = dcX * dpY - dcY * dpX
                guard abs(denom) > 1e-9 else { return e }
                return CGPoint(x: (n1 * dpX - n2 * dcX) / denom, y: (n1 * dpY - n2 * dcY) / denom)
            }
            var s = input.last!
            for e in input {
                if inside(e) {
                    if !inside(s) { output.append(intersection(s, e)) }
                    output.append(e)
                } else if inside(s) {
                    output.append(intersection(s, e))
                }
                s = e
            }
        }
        return output
    }

    static func decodePeaks(heatmap: [Float], corners: [Float], meta: LetterboxMeta,
                            scoreThreshold: Float = 0.38, iouThreshold: Double = 0.35, topK: Int = 12) -> [Detection] {
        let cellCount = grid * grid
        guard heatmap.count >= 3 * cellCount, corners.count >= 8 * cellCount else { return [] }
        let kinds: [Kind] = [.welfare, .sports, .unsupported]
        var peaks: [(cls: Int, gy: Int, gx: Int, score: Float)] = []
        for cls in 0..<3 {
            let base = cls * cellCount
            for gy in 0..<grid {
                for gx in 0..<grid {
                    let score = heatmap[base + gy * grid + gx]
                    guard score >= scoreThreshold else { continue }
                    var isMax = true
                    outer: for dy in -1...1 {
                        let ny = gy + dy
                        guard ny >= 0, ny < grid else { continue }
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            let nx = gx + dx
                            guard nx >= 0, nx < grid else { continue }
                            if heatmap[base + ny * grid + nx] > score {
                                isMax = false
                                break outer
                            }
                        }
                    }
                    if isMax { peaks.append((cls, gy, gx, score)) }
                }
            }
        }
        peaks.sort { $0.score > $1.score }
        var candidates: [Detection] = []
        let sizeF = Double(meta.size)
        for peak in peaks.prefix(topK * 3) {
            let cx = (Double(peak.gx) + 0.5) * Double(stride)
            let cy = (Double(peak.gy) + 0.5) * Double(stride)
            let cell = peak.gy * grid + peak.gx
            var quadLB: [CGPoint] = []
            for corner in 0..<4 {
                let dx = Double(corners[(corner * 2) * cellCount + cell]) * sizeF
                let dy = Double(corners[(corner * 2 + 1) * cellCount + cell]) * sizeF
                let ox = min(max((cx + dx - Double(meta.padX)) / max(meta.scale, 1e-6), 0), meta.origWidth)
                let oy = min(max((cy + dy - Double(meta.padY)) / max(meta.scale, 1e-6), 0), meta.origHeight)
                quadLB.append(CGPoint(x: ox, y: oy))
            }
            let ordered = orderQuad(quadLB)
            guard polygonArea(ordered) >= 400 else { continue }
            candidates.append(Detection(kind: kinds[peak.cls], score: peak.score, corners: ordered))
        }
        var kept: [Detection] = []
        for cand in candidates {
            if kept.allSatisfy({ quadIoU(cand.corners, $0.corners) < iouThreshold }) {
                kept.append(cand)
                if kept.count >= topK { break }
            }
        }
        kept.sort { lhs, rhs in
            let rowL = (Double(lhs.corners[0].y) / 120.0).rounded()
            let rowR = (Double(rhs.corners[0].y) / 120.0).rounded()
            return rowL == rowR ? lhs.corners[0].x < rhs.corners[0].x : rowL < rowR
        }
        return kept
    }

    func detect(in image: UIImage, scoreThreshold: Float = 0.38) -> [Detection] {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return [] }
        let meta = Self.letterboxMeta(width: Double(size.width), height: Double(size.height))
        let nw = max(1, Int((Double(size.width) * meta.scale).rounded()))
        let nh = max(1, Int((Double(size.height) * meta.scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let canvas = UIGraphicsImageRenderer(size: CGSize(width: Self.inputSize, height: Self.inputSize), format: format).image { ctx in
            UIColor(white: 128.0 / 255.0, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: Self.inputSize, height: Self.inputSize))
            image.draw(in: CGRect(x: meta.padX, y: meta.padY, width: nw, height: nh))
        }
        guard let cg = canvas.cgImage,
              let chw = CoreMLBundle.rgbCHW(cg, width: Self.inputSize, height: Self.inputSize),
              let input = CoreMLBundle.makeInput(shape: [1, 3, Self.inputSize, Self.inputSize], values: chw),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": input]),
              let output = try? model.prediction(from: provider),
              let hm = output.featureValue(for: "heatmap")?.multiArrayValue,
              let cn = output.featureValue(for: "corners")?.multiArrayValue else {
            return []
        }
        return Self.decodePeaks(heatmap: CoreMLBundle.readFloats(hm),
                                corners: CoreMLBundle.readFloats(cn),
                                meta: meta,
                                scoreThreshold: scoreThreshold)
    }
}

// MARK: - 2. ZoneLayout（三区域视觉定位）

final class CoreMLZoneLayout {
    static let inputWidth = 192
    static let inputHeight = 256

    struct Layout: Equatable {
        var header: CGRect
        var number: CGRect
        var meta: CGRect
        var hasZoneProbability: Float
    }

    static let shared: CoreMLZoneLayout? = CoreMLBundle.load("ZoneLayout").map(CoreMLZoneLayout.init)
    private let model: MLModel

    private init(model: MLModel) {
        self.model = model
    }

    func predict(_ cgImage: CGImage) -> Layout? {
        guard let chw = CoreMLBundle.rgbCHW(cgImage, width: Self.inputWidth, height: Self.inputHeight),
              let input = CoreMLBundle.makeInput(shape: [1, 3, Self.inputHeight, Self.inputWidth], values: chw),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["ticket": input]),
              let output = try? model.prediction(from: provider),
              let boxesArr = output.featureValue(for: "boxes")?.multiArrayValue,
              let hzArr = output.featureValue(for: "has_zone")?.multiArrayValue else {
            return nil
        }
        let boxes = CoreMLBundle.readFloats(boxesArr)
        let hz = CoreMLBundle.readFloats(hzArr)
        guard boxes.count >= 12, let prob = hz.first else { return nil }
        func rect(at idx: Int) -> CGRect {
            let x0 = CGFloat(min(max(boxes[idx * 4 + 0], 0), 1))
            let y0 = CGFloat(min(max(boxes[idx * 4 + 1], 0), 1))
            let x1 = CGFloat(min(max(boxes[idx * 4 + 2], 0), 1))
            let y1 = CGFloat(min(max(boxes[idx * 4 + 3], 0), 1))
            return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        }
        return Layout(header: rect(at: 0), number: rect(at: 1), meta: rect(at: 2), hasZoneProbability: prob)
    }
}

// MARK: - 3. TicketHeaderMeta（票头多头视觉分类）

final class CoreMLHeaderClassifier {
    static let inputWidth = 256
    static let inputHeight = 128
    static let headerGames: [GameKey?] = [.ssq, .dlt, .qlc, .k8, .pl3, .pl5, .qxc, .fc3d, nil]

    struct Prediction: Equatable {
        var game: GameKey?
        var isUnsupported: Bool
        var gameConfidence: Float
        var play: ScanPlay?
        var isPackage: Bool
        var playConfidence: Float
        var addOnProbability: Float
        var k8Pick: Int
        var k8Confidence: Float
    }

    static let shared: CoreMLHeaderClassifier? = CoreMLBundle.load("TicketHeaderMeta").map(CoreMLHeaderClassifier.init)
    private let model: MLModel

    private init(model: MLModel) {
        self.model = model
    }

    static func decode(gameProbs: [Float], playProbs: [Float], addOnProb: Float, k8Probs: [Float]) -> Prediction? {
        guard gameProbs.count == 9, playProbs.count == 5, k8Probs.count == 11 else { return nil }
        let gIdx = gameProbs.indices.max { gameProbs[$0] < gameProbs[$1] } ?? 8
        let pIdx = playProbs.indices.max { playProbs[$0] < playProbs[$1] } ?? 4
        let kIdx = k8Probs.indices.max { k8Probs[$0] < k8Probs[$1] } ?? 0
        let play: ScanPlay?
        let isPackage: Bool
        switch pIdx {
        case 0: (play, isPackage) = (.single, false)
        case 1: (play, isPackage) = (.system, false)
        case 2: (play, isPackage) = (.dantuo, false)
        case 3: (play, isPackage) = (.single, true)
        default: (play, isPackage) = (nil, false)
        }
        return Prediction(
            game: headerGames[gIdx],
            isUnsupported: gIdx == 8,
            gameConfidence: gameProbs[gIdx],
            play: play,
            isPackage: isPackage,
            playConfidence: playProbs[pIdx],
            addOnProbability: addOnProb,
            k8Pick: kIdx,
            k8Confidence: k8Probs[kIdx]
        )
    }

    func classify(_ cgImage: CGImage, topFraction: Double = 0.52) -> Prediction? {
        let cutH = max(24, Int((Double(cgImage.height) * topFraction).rounded()))
        let cropRect = CGRect(x: 0, y: 0, width: cgImage.width, height: min(cutH, cgImage.height))
        guard let header = cgImage.cropping(to: cropRect),
              let chw = CoreMLBundle.rgbCHW(header, width: Self.inputWidth, height: Self.inputHeight),
              let input = CoreMLBundle.makeInput(shape: [1, 3, Self.inputHeight, Self.inputWidth], values: chw),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["header": input]),
              let output = try? model.prediction(from: provider),
              let gArr = output.featureValue(for: "game")?.multiArrayValue,
              let pArr = output.featureValue(for: "play")?.multiArrayValue,
              let aoArr = output.featureValue(for: "add_on")?.multiArrayValue,
              let kArr = output.featureValue(for: "k8_pick")?.multiArrayValue else {
            return nil
        }
        let ao = CoreMLBundle.readFloats(aoArr).first ?? 0
        return Self.decode(
            gameProbs: CoreMLBundle.readFloats(gArr),
            playProbs: CoreMLBundle.readFloats(pArr),
            addOnProb: ao,
            k8Probs: CoreMLBundle.readFloats(kArr)
        )
    }
}

// MARK: - 4. LotteryLineOCR（整行 CRNN+CTC 号码读取）

final class CoreMLLineReader {
    static let inputHeight = 32
    static let inputWidth = 640
    static let timeSteps = 160
    static let numClasses = 13
    private static let alphabet: [Character] = Array("0123456789()")

    static let shared: CoreMLLineReader? = CoreMLBundle.load("LotteryLineOCR").map(CoreMLLineReader.init)
    private let model: MLModel

    private init(model: MLModel) {
        self.model = model
    }

    static func decodeCTC(probs: [Float], timeSteps: Int = timeSteps, numClasses: Int = numClasses) -> (text: String, peaks: [Float], means: [Float]) {
        guard probs.count >= timeSteps * numClasses else { return ("", [], []) }
        var chars: [Character] = []
        var peaks: [Float] = []
        var means: [Float] = []
        var prev = 0
        var run: [Float] = []
        for t in 0..<timeSteps {
            let base = t * numClasses
            var bestIdx = 0
            var bestProb = probs[base]
            for c in 1..<numClasses {
                let p = probs[base + c]
                if p > bestProb {
                    bestProb = p
                    bestIdx = c
                }
            }
            if bestIdx == prev {
                if bestIdx != 0 { run.append(bestProb) }
                continue
            }
            if prev != 0, !run.isEmpty, prev - 1 < alphabet.count {
                chars.append(alphabet[prev - 1])
                peaks.append(run.max() ?? 0)
                means.append(run.reduce(0, +) / Float(run.count))
            }
            prev = bestIdx
            run = bestIdx != 0 ? [bestProb] : []
        }
        if prev != 0, !run.isEmpty, prev - 1 < alphabet.count {
            chars.append(alphabet[prev - 1])
            peaks.append(run.max() ?? 0)
            means.append(run.reduce(0, +) / Float(run.count))
        }
        return (String(chars), peaks, means)
    }

    /// 剥离福彩行尾 `(n)` / `(n` 括号倍数，与 `line_model.py:strip_multiple` 一致。
    static func stripMultiple(text: String, confs: [Float]) -> (digits: [Int], confs: [Float], multiple: Int?) {
        let chars = Array(text)
        guard chars.count == confs.count else { return ([], [], nil) }
        var limit = chars.count
        var multiple: Int?
        if let range = text.range(of: #"\((\d{1,2})\)?$"#, options: .regularExpression) {
            let matched = String(text[range])
            let numStr = matched.filter(\.isNumber)
            if let value = Int(numStr), value > 0 { multiple = value }
            limit = text.distance(from: text.startIndex, to: range.lowerBound)
        }
        var digits: [Int] = []
        var digitConfs: [Float] = []
        for i in 0..<limit {
            if let v = chars[i].wholeNumberValue, (0...9).contains(v) {
                digits.append(v)
                digitConfs.append(confs[i])
            }
        }
        return (digits, digitConfs, multiple)
    }

    /// 把整行序列读数包装成 `[GlyphRows.Token]`，无缝对接 `ModelFusion` 的全部校验与重建门闸。
    static func makeTokens(digits: [Int], confs: [Float], multiple: Int?, top: Int, bottom: Int) -> [GlyphRows.Token] {
        guard !digits.isEmpty, digits.count == confs.count else { return [] }
        var tokens: [GlyphRows.Token] = []
        tokens.reserveCapacity(digits.count + 3)
        for i in 0..<digits.count {
            let x0 = 40 + i * 26
            tokens.append(.init(digit: digits[i], confidence: confs[i],
                                segment: .init(x0: x0, x1: x0 + 18, y0: top, y1: bottom)))
        }
        if let mult = multiple, (1...9).contains(mult) {
            let base = max(840, 40 + digits.count * 26 + 80)
            tokens.append(.init(digit: DigitClassifier.reject, confidence: 0.99,
                                segment: .init(x0: base, x1: base + 12, y0: top, y1: bottom)))
            tokens.append(.init(digit: mult, confidence: 0.99,
                                segment: .init(x0: base + 16, x1: base + 34, y0: top, y1: bottom)))
            tokens.append(.init(digit: DigitClassifier.reject, confidence: 0.99,
                                segment: .init(x0: base + 38, x1: base + 50, y0: top, y1: bottom)))
        }
        return tokens
    }

    func readStrip(_ gray: [UInt8], width: Int, height: Int) -> (digits: [Int], confs: [Float], multiple: Int?)? {
        let strip = CoreMLBundle.preprocessStrip(gray, width: width, height: height,
                                                 targetHeight: Self.inputHeight, targetWidth: Self.inputWidth)
        guard let input = CoreMLBundle.makeInput(shape: [1, 1, Self.inputHeight, Self.inputWidth], values: strip),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["strip": input]),
              let output = try? model.prediction(from: provider),
              let probsArr = output.featureValue(for: "probs")?.multiArrayValue else {
            return nil
        }
        let decoded = Self.decodeCTC(probs: CoreMLBundle.readFloats(probsArr))
        return Self.stripMultiple(text: decoded.text, confs: decoded.peaks)
    }

    func readZone(_ gray: [UInt8], width: Int, height: Int, rowColumns: Double) -> [[GlyphRows.Token]] {
        guard width > 0, height > 0, gray.count == width * height else { return [] }
        let ink = GlyphRows.inkMask(gray, width: width, height: height)
        let bands = GlyphRows.rowBands(ink, width: width, height: height, rowColumns: rowColumns)
        var out: [[GlyphRows.Token]] = []
        for (top, bottom) in bands {
            let pad = max(3, Int(Double(bottom - top) * 0.14))
            let y0 = max(0, top - pad), y1 = min(height, bottom + pad)
            let sh = y1 - y0
            guard sh >= 4 else { continue }
            var slice = [UInt8](repeating: 255, count: width * sh)
            for y in 0..<sh {
                let srcOff = (y0 + y) * width
                let dstOff = y * width
                for x in 0..<width { slice[dstOff + x] = gray[srcOff + x] }
            }
            if let read = readStrip(slice, width: width, height: sh), !read.digits.isEmpty {
                out.append(Self.makeTokens(digits: read.digits, confs: read.confs,
                                           multiple: read.multiple, top: top, bottom: bottom))
            }
        }
        return out
    }
}

// MARK: - 5. MetaFieldOCR（元数据行 CRNN+CTC 读取）

final class CoreMLMetaReader {
    static let inputHeight = 32
    static let inputWidth = 512
    static let timeSteps = 128
    static let alphabet: [Character] = Array("0123456789-/:.()年月日期倍元合计追加单复胆拖式票套选餐开奖销第注直组一二三四五六七八九十")
    static let numClasses = alphabet.count + 1 // 53

    struct Fields: Equatable {
        var issue: String = ""
        var drawDate: String = ""
        var totalAmount: Double?
        var multiple: Int?
        var periods: Int = 1
        var addOn: Bool = false
    }

    static let shared: CoreMLMetaReader? = CoreMLBundle.load("MetaFieldOCR").map(CoreMLMetaReader.init)
    private let model: MLModel

    private init(model: MLModel) {
        self.model = model
    }

    static func decodeCTC(probs: [Float], timeSteps: Int = timeSteps, numClasses: Int = numClasses) -> (text: String, peaks: [Float]) {
        guard probs.count >= timeSteps * numClasses else { return ("", []) }
        var chars: [Character] = []
        var peaks: [Float] = []
        var prev = 0
        var run: [Float] = []
        for t in 0..<timeSteps {
            let base = t * numClasses
            var bestIdx = 0
            var bestProb = probs[base]
            for c in 1..<numClasses {
                let p = probs[base + c]
                if p > bestProb {
                    bestProb = p
                    bestIdx = c
                }
            }
            if bestIdx == prev {
                if bestIdx != 0 { run.append(bestProb) }
                continue
            }
            if prev != 0, !run.isEmpty, prev - 1 < alphabet.count {
                chars.append(alphabet[prev - 1])
                peaks.append(run.max() ?? 0)
            }
            prev = bestIdx
            run = bestIdx != 0 ? [bestProb] : []
        }
        if prev != 0, !run.isEmpty, prev - 1 < alphabet.count {
            chars.append(alphabet[prev - 1])
            peaks.append(run.max() ?? 0)
        }
        return (String(chars), peaks)
    }

    /// 从 MetaFieldOCR 解码出的多行文本解析结构化字段，与 `meta_field_model.py:parse_meta_fields` 一致。
    static func parseFields(_ lines: [String], sports: Bool) -> Fields {
        let joined = lines.joined(separator: "\n")
        var fields = Fields()
        func capture(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)) else {
                return nil
            }
            return (1..<match.numberOfRanges).compactMap { idx in
                let nsRange = match.range(at: idx)
                guard nsRange.location != NSNotFound, let range = Range(nsRange, in: joined) else { return nil }
                return String(joined[range])
            }
        }
        if sports {
            if let hit = capture(#"第(\d{5})期"#) ?? capture(#"(?:^|\D)(2\d{4})期"#), let v = hit.first {
                fields.issue = v
            }
        } else {
            if let hit = capture(#"开奖期:?(\d{7})"#) ?? capture(#"销售期:?(\d{7})"#) ?? capture(#"(20\d{5})"#), let v = hit.first {
                fields.issue = v
            }
        }
        if let d = capture(#"(20\d{2})年(\d{1,2})月(\d{1,2})日"#), d.count == 3,
           let y = Int(d[0]), let m = Int(d[1]), let day = Int(d[2]),
           (1...12).contains(m), (1...31).contains(day) {
            fields.drawDate = String(format: "%04d-%02d-%02d", y, m, day)
        } else if let d = capture(#"(2\d)[-/](\d{2})[-/](\d{2})(?!\d*:)"#), d.count == 3,
                  let y = Int(d[0]), let m = Int(d[1]), let day = Int(d[2]),
                  (1...12).contains(m), (1...31).contains(day) {
            fields.drawDate = String(format: "20%02d-%02d-%02d", y, m, day)
        }
        if let t = capture(#"合计(\d{1,6})(?:\.\d{1,2})?元"#)?.first, let v = Double(t), v > 0 {
            fields.totalAmount = v
        }
        fields.addOn = joined.contains("追加")
        if let p = capture(#"(?:追加|单式|复式|胆拖|套餐|投注)[^\n]{0,6}?(?<![第0-9])(\d{1,2})期"#)?.first,
           let v = Int(p), (2...20).contains(v) {
            fields.periods = v
        }
        if let m = (capture(#"倍数:?(\d{1,2})"#) ?? capture(#"(\d{1,2})倍"#))?.first,
           let v = Int(m), v > 0 {
            fields.multiple = v
        }
        return fields
    }

    func readStrip(_ gray: [UInt8], width: Int, height: Int) -> String? {
        let strip = CoreMLBundle.preprocessStrip(gray, width: width, height: height,
                                                 targetHeight: Self.inputHeight, targetWidth: Self.inputWidth)
        guard let input = CoreMLBundle.makeInput(shape: [1, 1, Self.inputHeight, Self.inputWidth], values: strip),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["strip": input]),
              let output = try? model.prediction(from: provider),
              let probsArr = output.featureValue(for: "probs")?.multiArrayValue else {
            return nil
        }
        let decoded = Self.decodeCTC(probs: CoreMLBundle.readFloats(probsArr))
        return decoded.text.isEmpty ? nil : decoded.text
    }

    func readRegion(_ cgImage: CGImage, normalizedBoxes: [CGRect], sports: Bool) -> (lines: [String], fields: Fields) {
        var decodedLines: [String] = []
        let imgW = CGFloat(cgImage.width), imgH = CGFloat(cgImage.height)
        for box in normalizedBoxes where box.width > 0.05 && box.height > 0.02 {
            let padded = CGRect(
                x: max(0, box.minX - 0.015),
                y: max(0, box.minY - 0.015),
                width: min(1, box.maxX + 0.015) - max(0, box.minX - 0.015),
                height: min(1, box.maxY + 0.015) - max(0, box.minY - 0.015)
            )
            let cropRect = CGRect(x: padded.minX * imgW, y: padded.minY * imgH,
                                  width: padded.width * imgW, height: padded.height * imgH).integral
            guard cropRect.width >= 40, cropRect.height >= 16,
                  let cropped = cgImage.cropping(to: cropRect) else { continue }
            let targetW = min(cropped.width, 1000)
            let targetH = max(12, Int((Double(cropped.height) * Double(targetW) / Double(cropped.width)).rounded()))
            guard let red = ZoneRaster.red(cropped, width: targetW, height: targetH) else { continue }
            let ink = GlyphRows.inkMask(red, width: targetW, height: targetH)
            let bands = GlyphRows.rowBands(ink, width: targetW, height: targetH, rowColumns: 1.0)
            for (top, bottom) in bands {
                let pad = max(3, Int(Double(bottom - top) * 0.16))
                let y0 = max(0, top - pad), y1 = min(targetH, bottom + pad)
                let sh = y1 - y0
                guard sh >= 4 else { continue }
                var slice = [UInt8](repeating: 255, count: targetW * sh)
                for y in 0..<sh {
                    let srcOff = (y0 + y) * targetW
                    let dstOff = y * targetW
                    for x in 0..<targetW { slice[dstOff + x] = red[srcOff + x] }
                }
                if let text = readStrip(slice, width: targetW, height: sh) {
                    decodedLines.append(text)
                }
            }
        }
        return (decodedLines, Self.parseFields(decodedLines, sports: sports))
    }
}
