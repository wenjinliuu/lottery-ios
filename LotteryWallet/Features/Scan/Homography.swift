import Foundation
import CoreGraphics

/// 平面单应（3×3 投影变换）。
///
/// 配准这一步做的就是：把票面上号码区那个**四边形**（它是歪的、带透视的）
/// 映射成一个**标准矩形**。映射完之后列距、行距在矩形里是常数 ——
/// 不用再从识别结果里估几何，而这正是所有错位的来源。
///
/// 反过来也要用：格子是在标准矩形里划的，要把它裁回原图上认，
/// 得用 `inverse` 把格子的四个角映射回去。**每个号码来自票面哪个像素格子**
/// 这条硬约束，就是靠这一对正反变换说清楚的。
struct Homography: Equatable {
    /// 行优先的 3×3，已归一化成 `m[8] == 1`。
    let m: [Double]

    init?(_ values: [Double]) {
        // NaN 会一路传染下去，最后变成一次 `Int(nan)` 的崩溃。挡在入口。
        guard values.count == 9, values.allSatisfy(\.isFinite), values[8] != 0 else { return nil }
        m = values.map { $0 / values[8] }
    }

    /// 由四组对应点解出单应（DLT）。
    ///
    /// 四个点八个方程，正好定死八个自由度 —— 不用最小二乘，直接解线性方程组。
    /// 点的顺序两边必须一致（左上、右上、右下、左下）。
    static func mapping(_ source: [CGPoint], to destination: [CGPoint]) -> Homography? {
        guard source.count == 4, destination.count == 4 else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for index in 0..<4 {
            let x = Double(source[index].x)
            let y = Double(source[index].y)
            let u = Double(destination[index].x)
            let v = Double(destination[index].y)
            a[index * 2] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[index * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        guard let solution = solve(a) else { return nil }
        return Homography(solution + [1])
    }

    /// 把一个点映射过去。落在无穷远（分母为 0）时返回 nil。
    func map(_ point: CGPoint) -> CGPoint? {
        let x = Double(point.x)
        let y = Double(point.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-12 else { return nil }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w,
                       y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    /// 反向变换。
    var inverse: Homography? {
        let a = m
        let cofactor = [
            a[4] * a[8] - a[5] * a[7], a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
            a[5] * a[6] - a[3] * a[8], a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
            a[3] * a[7] - a[4] * a[6], a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3]
        ]
        let determinant = a[0] * cofactor[0] + a[1] * cofactor[3] + a[2] * cofactor[6]
        guard abs(determinant) > 1e-12 else { return nil }
        return Homography(cofactor.map { $0 / determinant })
    }

    /// 高斯消元解 8×9 的增广矩阵，带部分主元。
    private static func solve(_ rows: [[Double]]) -> [Double]? {
        var a = rows
        let n = 8
        for column in 0..<n {
            // 选主元：绝对值最大的那一行。不选的话票摆得很正（斜率≈0）时
            // 主元接近 0，解出来全是噪声。
            var pivot = column
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-12 else { return nil }
            a.swapAt(column, pivot)
            let head = a[column][column]
            for index in column...n { a[column][index] /= head }
            for row in 0..<n where row != column {
                let factor = a[row][column]
                guard factor != 0 else { continue }
                for index in column...n {
                    a[row][index] -= factor * a[column][index]
                }
            }
        }
        return (0..<n).map { a[$0][n] }
    }
}
