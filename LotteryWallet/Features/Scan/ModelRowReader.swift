import UIKit

/// 一张摆正的票 → 模型按行读出来的号码。`TicketVisionScanner.scan` 拿它和 Vision 的结果对。
///
/// 这里只做和 UIKit 有关的那一点：取像素、把 Vision 的坐标换成像素。
/// 找号码区在 `NumberZone`，切行切字在 `GlyphRows`，两个读数怎么合在 `ModelFusion`。
enum ModelRowReader {
    /// 取像素时最宽用这么多。再宽对认字没有帮助，只是慢。
    static let workingWidth = 2000

    struct Reading {
        var rows: [[GlyphRows.Token]]
        /// 号码区在正片上的位置（归一化，左上原点），画在调试图上。
        var zone: CGRect
    }

    static func read(image: UIImage, fragments: [TicketVisionScanner.TextFragment],
                     game: GameKey, classifier: DigitClassifier) -> Reading? {
        guard let cgImage = image.cgImage, cgImage.width > 0 else { return nil }
        let width = min(cgImage.width, workingWidth)
        let height = Int((Double(cgImage.height) * Double(width) / Double(cgImage.width)).rounded())
        guard height > 0, let red = ZoneRaster.red(cgImage, width: width, height: height) else { return nil }
        let lines = fragments.map { fragment in
            NumberZone.Line(text: fragment.text,
                            minX: Double(fragment.box.minX) * Double(width),
                            maxX: Double(fragment.box.maxX) * Double(width),
                            minY: Double(1 - fragment.box.maxY) * Double(height),
                            maxY: Double(1 - fragment.box.minY) * Double(height))
        }
        let sports = [GameKey.dlt, .pl3, .pl5, .qxc].contains(game)
        guard let bounds = NumberZone.bounds(lines, sports: sports, imageWidth: Double(width)) else { return nil }
        let slope = TicketVisionScanner.textTilt(fragments, size: CGSize(width: width, height: height)) ?? 0
        guard let zone = NumberZone.sample(red, width: width, height: height, bounds: bounds, slope: slope) else { return nil }
        let rows = GlyphRows.read(zone.pixels, width: zone.width, height: zone.height,
                                  rowColumns: sports ? 1 : 0.6, classifier: classifier)
        let rect = CGRect(x: bounds.left / Double(width), y: bounds.top / Double(height),
                          width: (bounds.right - bounds.left) / Double(width),
                          height: (bounds.bottom - bounds.top) / Double(height))
        return Reading(rows: rows, zone: rect)
    }
}
