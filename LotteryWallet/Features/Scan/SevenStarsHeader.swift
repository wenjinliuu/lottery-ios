import Accelerate
import UIKit

/// Detects the Seven Stars wordmark in a single perspective-corrected ticket.
/// Weights and the decision threshold are exported by lottery-ocr.
struct SevenStarsHeader: Decodable {
    let weights: [Float]
    let bias: Float
    let threshold: Float

    static let shared: Self? = {
        guard let url = Bundle(for: AppDelegate.self).url(forResource: "SevenStarsHeader", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let model = try? JSONDecoder().decode(Self.self, from: data), model.weights.count == 240 else { return nil }
        return model
    }()

    func matches(_ image: CGImage) -> Bool {
        let top = min(image.height, max(1, Int((Double(image.width) * 0.45).rounded())))
        guard let strip = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: top)) else { return false }
        for width in [60, 70, 81, 94, 109, 126] {
            for stretch in [0.85, 1.0, 1.18] {
                let height = max(10, Int((Double(top * width) / Double(image.width) * stretch).rounded()))
                var pixels = [UInt8](repeating: 0, count: width * height)
                let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                    guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                    ctx.interpolationQuality = .high
                    ctx.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: height))
                    return true
                }
                if drawn && containsLogo(pixels.map(Float.init), width: width, height: height) { return true }
            }
        }
        return false
    }

    private func containsLogo(_ pixels: [Float], width: Int, height: Int) -> Bool {
        let count = width - 24 + 1
        return pixels.withUnsafeBufferPointer { input in
            weights.withUnsafeBufferPointer { kernel in
                guard let base = input.baseAddress, let filter = kernel.baseAddress else { return false }
                var products = [Float](repeating: 0, count: count)
                for y in 0...(height - 10) {
                    var scores = [Float](repeating: 0, count: count)
                    var sums = [Float](repeating: 0, count: width)
                    var squares = sums
                    for row in 0..<10 {
                        let line = base + (y + row) * width
                        vDSP_conv(line, 1, filter + row * 24, 1, &products, 1, vDSP_Length(count), 24)
                        for x in scores.indices { scores[x] += products[x] }
                        for x in sums.indices {
                            sums[x] += line[x]
                            squares[x] += line[x] * line[x]
                        }
                    }
                    var sum = sums.prefix(24).reduce(0, +)
                    var square = squares.prefix(24).reduce(0, +)
                    for x in scores.indices {
                        let mean = sum / 240
                        let scale = sqrt(max(64, square / 240 - mean * mean))
                        if scores[x] / scale + bias >= threshold { return true }
                        if x + 24 < width {
                            sum += sums[x + 24] - sums[x]
                            square += squares[x + 24] - squares[x]
                        }
                    }
                }
                return false
            }
        }
    }
}
