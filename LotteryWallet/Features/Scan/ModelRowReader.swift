import UIKit

/// 一张摆正的票 → 模型按行读出来的号码。`TicketVisionScanner.scan` 拿它和 Vision 的结果对。
///
/// 端侧模型优先链路：
/// 1. 找号码区：优先 `NumberZone` 精确文字锚；锚词缺失/遮挡时回退至端侧视觉模型 `ZoneLayout`；
/// 2. 读每一行：优先整行 CRNN+CTC 模型 `CoreMLLineReader`（抗粘连/印章/宽幅行），
///    未加载或需要逐格坐标时退回单字模型 `DigitClassifier` (`GlyphRows.read`)。
enum ModelRowReader {
    /// 取像素时最宽用这么多。再宽对认字没有帮助，只是慢。
    static let workingWidth = 2000

    struct Reading {
        var rows: [[GlyphRows.Token]]
        /// 号码区在正片上的位置（归一化，左上原点），画在调试图上。
        var zone: CGRect
        /// 本次实际走的行读取引擎与号码区来源（供调试日志透出）。
        var usedLineModel: Bool = false
        var usedVisualZone: Bool = false
    }

    /// 找行投影只看左侧这么多列：福彩排除行尾顶天立地的 `(1)` 括号（60%），
    /// 体彩排除最右侧竖排「☆中国体育彩票」边条与纸边（85%），避免把多行粘成一整块。
    static let sportsRowColumns: Double = 0.85
    static let welfareRowColumns: Double = 0.6

    static func read(image: UIImage, fragments: [TicketVisionScanner.TextFragment],
                     game: GameKey, classifier: DigitClassifier? = DigitClassifier.shared,
                     visualLayout: CoreMLZoneLayout.Layout? = nil,
                     preferLineModel: Bool = true) -> Reading? {
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
        var usedVisualZone = false
        let resolvedBounds: NumberZone.Bounds?
        if let ocrBounds = NumberZone.bounds(lines, sports: sports, imageWidth: Double(width)) {
            resolvedBounds = ocrBounds
        } else if let layout = visualLayout ?? CoreMLZoneLayout.shared?.predict(cgImage),
                  layout.hasZoneProbability >= 0.45,
                  layout.number.width > 0.15, layout.number.height > 0.04 {
            // 视觉号码区四周适度留 1.5% 安全边距防贴边切头
            let n = layout.number
            let left = max(0.0, Double(n.minX - 0.015) * Double(width))
            let right = min(Double(width), Double(n.maxX + 0.015) * Double(width))
            let top = max(0.0, Double(n.minY - 0.015) * Double(height))
            let bottom = min(Double(height), Double(n.maxY + 0.015) * Double(height))
            if right - left >= 40, bottom - top >= 12 {
                resolvedBounds = NumberZone.Bounds(top: top, bottom: bottom, left: left, right: right)
                usedVisualZone = true
            } else {
                resolvedBounds = nil
            }
        } else {
            resolvedBounds = nil
        }
        guard let bounds = resolvedBounds else { return nil }
        let slope = TicketVisionScanner.textTilt(fragments, size: CGSize(width: width, height: height)) ?? 0
        guard let zone = NumberZone.sample(red, width: width, height: height, bounds: bounds, slope: slope) else { return nil }
        let rowColumns = sports ? sportsRowColumns : welfareRowColumns

        var rows: [[GlyphRows.Token]] = []
        var usedLineModel = false
        if preferLineModel, let lineModel = CoreMLLineReader.shared {
            let lineRows = lineModel.readZone(zone.pixels, width: zone.width, height: zone.height, rowColumns: rowColumns)
            if lineRows.contains(where: { !$0.isEmpty }) {
                rows = lineRows
                usedLineModel = true
            }
        }
        if rows.isEmpty, let classifier {
            rows = GlyphRows.read(zone.pixels, width: zone.width, height: zone.height,
                                  rowColumns: rowColumns, classifier: classifier)
        }
        let rect = CGRect(x: bounds.left / Double(width), y: bounds.top / Double(height),
                          width: (bounds.right - bounds.left) / Double(width),
                          height: (bounds.bottom - bounds.top) / Double(height))
        return Reading(rows: rows, zone: rect, usedLineModel: usedLineModel, usedVisualZone: usedVisualZone)
    }
}
