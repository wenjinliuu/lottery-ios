import Accelerate
import UIKit

/// Shared grayscale filters trained on cropped ticket headers. The welfare logo
/// is an issuer label: the printed play field identifies the individual game.
struct TicketHeaderModel {
    enum Label: String, CaseIterable {
        case qxc, dlt, pl5, welfare

        func identifiesGame(in text: String) -> GameKey? {
            let lines = text.components(separatedBy: .newlines)
            let welfare = text.contains("福利彩票") || lines.contains { $0.contains("/") && TicketTextParser.isSerialLine($0) }
            let sports = text.contains("体彩") || text.contains("体育彩票")
            switch self {
            case .welfare:
                // “玩法” on welfare tickets often follows a line containing “期”.
                // Exclude the footer and require an actual game name.
                for line in lines.prefix(while: { !TicketTextParser.isSerialLine($0) }) where line.contains("玩法") {
                    if let game = TicketTextParser.namedGame(line), [.fc3d, .ssq, .qlc, .k8].contains(game) { return game }
                }
                return nil
            case .qxc:
                return welfare ? nil : .qxc
            case .pl5:
                let textGame = TicketTextParser.detectGame(text, guess: false)
                guard sports, !welfare, textGame == .pl5 || (textGame == nil && text.contains("排列")) else { return nil }
                return .pl5
            case .dlt:
                guard sports, !welfare, text.contains("+") || text.contains("＋") || text.contains("前区") || text.contains("后区") else { return nil }
                return .dlt
            }
        }
    }

    struct Filter: Decodable {
        let weights: [Float]
        let bias: Float
        let threshold: Float
    }
    let filters: [Label: Filter]

    static let shared: Self? = {
        guard let url = Bundle(for: AppDelegate.self).url(forResource: "TicketHeaders", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Filter].self, from: data) else { return nil }
        var filters: [Label: Filter] = [:]
        for label in Label.allCases {
            guard let filter = raw[label.rawValue], filter.weights.count == 240 else { return nil }
            filters[label] = filter
        }
        return Self(filters: filters)
    }()

    func classify(_ image: CGImage) -> Label? {
        var hits: Set<Label> = []
        let top = min(image.height, max(1, Int((Double(image.width) * 0.45).rounded())))
        guard let strip = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: top)) else { return nil }
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
                guard drawn else { continue }
                let values = pixels.map(Float.init)
                for (label, filter) in filters where !hits.contains(label) {
                    if containsLogo(values, width: width, height: height, filter: filter) {
                        hits.insert(label)
                        if label == .qxc { return .qxc }
                    }
                }
            }
        }
        return hits.count == 1 ? hits.first : nil
    }

    private func containsLogo(_ pixels: [Float], width: Int, height: Int, filter model: Filter) -> Bool {
        let count = width - 24 + 1
        return pixels.withUnsafeBufferPointer { input in
            model.weights.withUnsafeBufferPointer { kernel in
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
                        if scores[x] / scale + model.bias >= model.threshold { return true }
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
