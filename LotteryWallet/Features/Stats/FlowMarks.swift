import Foundation

/// 奖金线上的一次跳升：这一天中了奖。
struct FlowWin: Identifiable, Equatable {
    var day: Date
    /// 跳上去之后的累计奖金，红点就画在这个高度。
    var prize: Double
    /// 这一跳多了多少。
    var gain: Double

    var id: Date { day }
}

/// 首页累计图上的标注：中奖点、右端的数字标签。
///
/// 三条累计线本身只增不减，买得规律时就是三条斜线。标注不改线，只把「哪天中了、中了多少」
/// 和「现在各是多少」直接写在图上。
enum FlowMarks {
    /// 奖金线上所有往上跳的点。图上的点是抽稀过的，所以一跳可能是相邻几天中的奖合在一起。
    static func wins(_ flow: [FlowPoint]) -> [FlowWin] {
        var out: [FlowWin] = []
        var previous = 0.0
        for point in flow {
            if point.prize > previous + 0.005 {
                out.append(FlowWin(day: point.day, prize: point.prize, gain: point.prize - previous))
            }
            previous = point.prize
        }
        return out
    }

    /// 跳得最高的那几次。点太多会把线盖住，所以图上只画这些。
    static func largest(_ wins: [FlowWin], limit: Int) -> [FlowWin] {
        Array(wins.sorted { $0.gain > $1.gain }.prefix(limit)).sorted { $0.day < $1.day }
    }

    /// 把几个标签的纵坐标错开：彼此至少隔 `gap`，都落在 `bounds` 里，尽量靠近各自原来的位置。
    ///
    /// 三条线的右端常常挨得很近（公益金和奖金），标签直接摆上去会叠在一起。
    /// 返回值和输入一一对应，顺序不变。
    static func spread(_ positions: [CGFloat], gap: CGFloat, in bounds: ClosedRange<CGFloat>) -> [CGFloat] {
        guard !positions.isEmpty else { return [] }
        let order = positions.indices.sorted { positions[$0] < positions[$1] }
        var placed = order.map { min(max(positions[$0], bounds.lowerBound), bounds.upperBound) }
        // 从上往下推开
        for index in placed.indices.dropFirst() where placed[index] < placed[index - 1] + gap {
            placed[index] = placed[index - 1] + gap
        }
        // 最下面的出界了：整体往上收，再从下往上推开
        if let last = placed.last, last > bounds.upperBound {
            placed[placed.count - 1] = bounds.upperBound
            for index in placed.indices.dropLast().reversed() where placed[index] > placed[index + 1] - gap {
                placed[index] = placed[index + 1] - gap
            }
        }
        var out = positions
        for (rank, index) in order.enumerated() { out[index] = placed[rank] }
        return out
    }
}
