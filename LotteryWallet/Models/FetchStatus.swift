import Foundation

/// 后端最近一次抓取任务的结果。
///
/// 设置页上就一行：
///
/// ```
/// 09月22日 02:44 · 执行成功 · 6/8 数据完整
/// ```
///
/// 三段各回答一个问题：**什么时候跑的、跑成了没有、数据齐了几个**。
/// 开奖号迟迟不更新时，用户要的就是这三件事 —— 而这三件事以前一件都看不到。
///
/// ## 为什么分母写死 8
///
/// 分母**不是** `lotteries` 字典的大小。某个彩种整个没出现在响应里，
/// 恰恰是最该被看见的情况：那说明后端连它的记录都没有。跟着字典大小走的话，
/// 少一个彩种分母就少一个，`7/7 数据完整` —— 一切正常，问题被抹平了。
///
/// 所以分母恒为 `GameKey.ordered.count`，缺失的彩种只是不计入分子。
struct FetchStatus: Sendable, Hashable {
    /// 任务执行时刻，ISO-8601 原文。空串表示还没有执行记录。
    let executedAt: String
    /// 执行成不成功。`nil` 表示响应里没有这个字段或给了个没见过的值。
    ///
    /// **不可以把未知当成功。** 真出事的时候界面上一片正常，是最坏的结果。
    let isSuccess: Bool?
    /// 数据完整的彩种数。
    let completed: Int
    /// 分母，恒为八。
    let total: Int

    /// 有没有执行记录。`latest_execution` 为空时整个状态是「暂无执行记录」。
    var hasExecution: Bool { !executedAt.isEmpty }

    /// `09月22日 02:44`
    var timeText: String {
        DateText.padded(executedAt)
    }

    /// `执行成功` / `执行失败` / 状态字段缺失时的兜底
    var resultText: String {
        switch isSuccess {
        case true: "执行成功"
        case false: "执行失败"
        case nil: "执行状态未知"
        }
    }

    /// `6/8 数据完整`
    var progressText: String { "\(completed)/\(total) 数据完整" }

    /// 设置页那一行的完整文案。
    var summary: String {
        guard hasExecution else { return "暂无执行记录" }
        return "\(timeText) · \(resultText) · \(progressText)"
    }

    /// 详情页「数据源更新时间」那一行：时间 + 成没成功。
    var executionText: String {
        guard hasExecution else { return "暂无执行记录" }
        return "\(timeText) · \(resultText)"
    }

    /// 八个彩种是不是都齐了。
    var isComplete: Bool { completed >= total }

    /// 红黄绿：执行失败最要紧，其次是数据没齐。
    ///
    /// 数据没齐**不一定是问题** —— 今天还没开奖的彩种本来就是 `waiting`。
    /// 所以它只是「值得看一眼」，不是错误。
    var needsAttention: Bool { isSuccess == false }
}
