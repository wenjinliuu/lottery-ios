import Foundation
import CoreGraphics

/// 一次识别里「机器看到了什么」的记录。
///
/// 这东西是**常驻**的，不是临时插的打印语句：设置里有开关（默认关闭），
/// 打开之后复核页会把下面这些东西画在票面上 ——
/// 检测到的基准、配准后的矩形、每一个格子。
///
/// 目的很具体：以后任何一张票出问题，用户截个图发过来就能分清是
/// **基准没找对**、**格子划歪了**、还是**格子对了但那一格就是没认出来**。
/// 这三种情况的修法完全不同，靠文字描述永远分不清。
///
/// 坐标一律**归一化、左上原点**，相对那张矫正后的正片。
struct ScanDebugReport: Equatable {

    /// 检测到的一条基准（体彩是虚线，福彩是哈希行 / 开奖期行）。
    struct Baseline: Equatable {
        var label: String
        var start: CGPoint
        var end: CGPoint
        /// 虚线的每一小段（归一化 x 区间）。画出来才看得出抓到的是不是虚线。
        var dashes: [ClosedRange<CGFloat>] = []
    }

    /// 号码区里的一格。四个角是**从标准矩形映射回票面的**，所以是四边形不是矩形。
    struct Cell: Equatable {
        var corners: [CGPoint]
        /// 第几行第几列。用户报问题时能直接说「第 2 注第 7 位划歪了」。
        var row: Int
        var column: Int
    }

    /// 一条竖直边界。
    struct Boundary: Equatable {
        var label: String
        var x: CGFloat
    }

    /// 这张票走的是哪条基准路。没配准成功就是 nil。
    var anchor: TicketFrame.Anchor?
    var baselines: [Baseline] = []
    /// 配准后的号码区四角，画在票面上。
    var frame: [CGPoint] = []
    var boundaries: [Boundary] = []
    var cells: [Cell] = []
    /// 说人话的过程记录：找到几条虚线、为什么没配准成功。
    var notes: [String] = []

    var didRegister: Bool { anchor != nil && frame.count == 4 }
}
