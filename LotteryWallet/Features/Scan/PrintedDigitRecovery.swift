import UIKit

/// Last pass for missing single digits. Use connected ink so that a slanted
/// baseline cannot cause a horizontal projection to slice a digit in half.
enum PrintedDigitRecovery {
    private struct Glyph {
        let digit: Int
        let confidence: Float
        let ink: [Float]   // unit length, for comparing type on the same ticket
    }

    static func fill(_ ticket: inout ScannedTicket, image: CGImage, zone: CGRect) -> Int {
        guard ticket.play == .single, [.pl5, .qxc].contains(ticket.game),
              let classifier = DigitClassifier.shared else { return 0 }
        let key: SectionKey = ticket.game == .pl5 ? .nums5 : .nums6
        let lines = ticket.lines.map { $0[key] }
        let count = ticket.game == .pl5 ? 5 : 6
        guard lines.contains(where: { $0.contains(NumberSet.unknown) }),
              lines.allSatisfy({ $0.count == count }) else { return 0 }
        let area = zone.applying(CGAffineTransform(scaleX: CGFloat(image.width), y: CGFloat(image.height)))
        guard let crop = image.cropping(to: area.integral) else { return 0 }
        let width = min(480, crop.width)
        let height = Int((Double(width) * Double(crop.height) / Double(crop.width)).rounded())
        guard height > 0, height <= 2 * width,
              let red = ZoneRaster.red(crop, width: width, height: height) else { return 0 }
        let boxes = components(red, width: width, height: height)
        guard boxes.count >= count, boxes.count <= 120 else { return 0 }
        let windows = alignedWindows(boxes, count: count)
        var glyphs: [Int: Glyph] = [:]
        for index in Set(windows.flatMap { $0 }) {
            let box = boxes[index]
            let segment = GlyphRows.Segment(x0: Int(box.minX), x1: Int(box.maxX), y0: Int(box.minY), y1: Int(box.maxY))
            let patch = GlyphRows.crop(red, width: width, height: height, segment: segment)
            let verdict = classifier.classify(pixels: patch.pixels, width: patch.width, height: patch.height)
            let ink = DigitClassifier.preprocess(pixels: patch.pixels, width: patch.width, height: patch.height)
            let norm = sqrt(ink.reduce(Float(0)) { $0 + $1 * $1 })
            guard norm > 0 else { continue }
            glyphs[index] = Glyph(digit: verdict.digit, confidence: verdict.confidence, ink: ink.map { $0 / norm })
        }

        // Identify the printed row using at least three existing readings.
        // A second plausible window or two ticket lines claiming the same ink
        // makes the association ambiguous.
        let matches: [[Int]?] = lines.map { line in
            let known = line.indices.filter { line[$0] >= 0 }
            guard known.count >= 3 else { return nil }
            let hits = windows.filter { window in
                known.allSatisfy { position in
                    guard let glyph = glyphs[window[position]] else { return false }
                    return glyph.digit == line[position] && glyph.confidence >= ModelFusion.threshold
                }
            }
            return hits.count == 1 ? hits.first : nil
        }
        let usable = matches.indices.filter { i in
            guard let row = matches[i] else { return false }
            return !matches.indices.contains { j in j != i && matches[j].map { !Set(row).isDisjoint(with: $0) } == true }
        }
        let references = usable.flatMap { row in
            lines[row].indices.compactMap { col -> Glyph? in
                guard lines[row][col] >= 0, let window = matches[row] else { return nil }
                return glyphs[window[col]]
            }
        }
        var filled = 0
        for row in usable {
            guard let window = matches[row] else { continue }
            for col in lines[row].indices where lines[row][col] == NumberSet.unknown {
                guard let glyph = glyphs[window[col]], (0...9).contains(glyph.digit),
                      glyph.confidence >= ModelFusion.threshold else { continue }
                var agreeing: Float = 0, competing: Float = 0
                for reference in references {
                    let similarity = zip(glyph.ink, reference.ink).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    if reference.digit == glyph.digit { agreeing = max(agreeing, similarity) }
                    else { competing = max(competing, similarity) }
                }
                guard agreeing >= 0.84, agreeing > competing + 0.005 else { continue }
                ticket.lines[row][key][col] = glyph.digit
                filled += 1
            }
        }
        if filled > 0 { ModelFusion.refreshWarnings(&ticket) }
        return filled
    }

    private static func alignedWindows(_ boxes: [CGRect], count: Int) -> Set<[Int]> {
        var windows = Set<[Int]>()
        for anchor in boxes {
            let band = boxes.indices.filter {
                let box = boxes[$0]
                return abs(box.midY - anchor.midY) < anchor.height * 0.62
                    && (0.65...1.5).contains(box.height / anchor.height)
            }.sorted { boxes[$0].midX < boxes[$1].midX }
            guard band.count >= count else { continue }
            for offset in 0...(band.count - count) {
                let row = Array(band[offset..<(offset + count)])
                let gaps = zip(row, row.dropFirst()).map { boxes[$1].midX - boxes[$0].midX }
                guard let low = gaps.min(), let high = gaps.max(), low >= anchor.height,
                      high <= 1.25 * low, high <= 5 * anchor.height else { continue }
                windows.insert(row)
            }
        }
        return windows
    }

    private static func components(_ gray: [UInt8], width: Int, height: Int) -> [CGRect] {
        let threshold = InkMask.otsu(gray)
        var ink = gray.map { $0 <= threshold }
        var result: [CGRect] = []
        var stack: [Int] = []
        for start in ink.indices where ink[start] {
            stack.append(start)
            ink[start] = false
            var left = start % width, right = left, top = start / width, bottom = top
            while let p = stack.popLast() {
                let x = p % width, y = p / width
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
                for j in max(0, y - 1)...min(height - 1, y + 1) {
                    for i in max(0, x - 1)...min(width - 1, x + 1) {
                        let next = j * width + i
                        if ink[next] { ink[next] = false; stack.append(next) }
                    }
                }
            }
            let w = right - left + 1, h = bottom - top + 1
            if h >= 5, h <= width / 7, w >= 2, (0.16...1.3).contains(Double(w) / Double(h)) {
                result.append(CGRect(x: left, y: top, width: w, height: h))
            }
        }
        return result
    }
}
