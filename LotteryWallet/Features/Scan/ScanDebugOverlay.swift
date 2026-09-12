import Foundation
import UIKit

/// 把「机器看到了什么」画到票面上。
///
/// 这张图是这次重构留给以后的**排查工具**：用户截个图发过来，
/// 三种毛病一眼就能分开 ——
///
/// - 绿线没压在票面那两条虚线上 → **基准没找对**，问题在检测那一层
/// - 绿线对了但蓝框歪了 → **配准算错了**
/// - 蓝框正、橙格却没套住数字 → **格子划歪了**，问题在网格那一层
/// - 全都对，就是某一格读不出来 → 那才是识别本身的问题
///
/// 没有这张图的时候，这四种情况在用户那儿都只是一句「又认错了」。
enum ScanDebugOverlay {

    /// 画超过这个尺寸就先缩一缩：复核页那张卡片最多两三百点宽，
    /// 按 4000px 的正片开画布纯属白烧内存。
    private static let maximumSide: CGFloat = 1400

    static func render(on image: UIImage, report: ScanDebugReport) -> UIImage {
        let base = fitted(image)
        let size = base.size
        guard size.width > 1, size.height > 1 else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            base.draw(in: CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            let unit = Swift.max(1.5, size.width / 400)

            func point(_ normalized: CGPoint) -> CGPoint {
                CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
            }

            // 框出来的那些块。号码区是主角画粗，票头区是配角画细。
            for zone in report.zones where zone.corners.count == 4 {
                cg.setStrokeColor(zone.isPrimary
                                  ? UIColor.systemBlue.cgColor
                                  : UIColor.systemPurple.cgColor)
                cg.setLineWidth(zone.isPrimary ? unit * 1.6 : unit * 1.1)
                cg.beginPath()
                cg.move(to: point(zone.corners[0]))
                for corner in zone.corners.dropFirst() { cg.addLine(to: point(corner)) }
                cg.closePath()
                cg.strokePath()
            }

            // 基准画在框**之后** —— 它就压在号码区上下两条边旁边，
            // 先画的话会被框整条盖住，看着像"没找到基准"。
            for baseline in report.baselines {
                cg.setStrokeColor(UIColor.systemGreen.withAlphaComponent(0.9).cgColor)
                cg.setLineWidth(unit)
                cg.beginPath()
                cg.move(to: point(baseline.start))
                cg.addLine(to: point(baseline.end))
                cg.strokePath()

                cg.setLineWidth(unit * 2.4)
                cg.setStrokeColor(UIColor.systemGreen.withAlphaComponent(0.55).cgColor)
                let start = point(baseline.start)
                let end = point(baseline.end)
                let span = end.x - start.x
                for dash in baseline.dashes {
                    let x0 = dash.lowerBound * size.width
                    let x1 = dash.upperBound * size.width
                    // 段在基准线上的高度按端点线性插值，斜着的票也贴得住
                    func y(_ x: CGFloat) -> CGFloat {
                        guard abs(span) > 0.001 else { return start.y }
                        return start.y + (x - start.x) / span * (end.y - start.y)
                    }
                    cg.beginPath()
                    cg.move(to: CGPoint(x: x0, y: y(x0)))
                    cg.addLine(to: CGPoint(x: x1, y: y(x1)))
                    cg.strokePath()
                }
            }

            // 左右边界
            cg.setStrokeColor(UIColor.systemOrange.cgColor)
            cg.setLineWidth(unit)
            for boundary in report.boundaries {
                let x = boundary.x * size.width
                let ys = report.numberZone.map { $0.y * size.height }
                let top = (ys.min() ?? 0) - unit * 6
                let bottom = (ys.max() ?? size.height) + unit * 6
                cg.saveGState()
                cg.setLineDash(phase: 0, lengths: [unit * 4, unit * 3])
                cg.beginPath()
                cg.move(to: CGPoint(x: x, y: Swift.max(0, top)))
                cg.addLine(to: CGPoint(x: x, y: Swift.min(size.height, bottom)))
                cg.strokePath()
                cg.restoreGState()
            }

            // 每一个格子
            cg.setStrokeColor(UIColor.systemPink.withAlphaComponent(0.95).cgColor)
            cg.setLineWidth(Swift.max(1, unit * 0.8))
            for cell in report.cells where cell.corners.count == 4 {
                cg.beginPath()
                cg.move(to: point(cell.corners[0]))
                for corner in cell.corners.dropFirst() { cg.addLine(to: point(corner)) }
                cg.closePath()
                cg.strokePath()
            }
        }
    }

    private static func fitted(_ image: UIImage) -> UIImage {
        let longest = Swift.max(image.size.width, image.size.height)
        guard longest > maximumSide, longest > 0 else { return image }
        let scale = maximumSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
