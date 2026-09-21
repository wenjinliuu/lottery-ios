import Foundation

/// 开奖数据源自己的体检结果。
///
/// **它不是开奖数据，是「给数据的那一边现在正不正常」。**
///
/// 存在的理由只有一个场景：用户说「开奖号怎么没更新」的时候，用来分清
/// 是谁的锅 ——
///
/// - 它说正常，而 App 里没有新数据 → App 这边的问题（缓存没刷、请求失败）
/// - 它说抓取卡住了 → 后端的问题，App 怎么重试都没用
///
/// 没有它的时候，这两种情况在界面上长得一模一样，只能靠猜。
struct DataSourceHealth: Sendable, Hashable {
    /// 数据源自报正不正常。`nil` = 它没给这个字段，只能看时间自己判断。
    let isHealthy: Bool?
    /// 数据源给的一句话，原样显示，不翻译 —— 翻译会把排查线索翻没。
    let message: String
    /// 数据源最后一次更新数据的时刻。
    let updatedAt: String
    /// 体检报告里带到了几个彩种。
    let gameCount: Int

    var label: String {
        switch isHealthy {
        case true: "正常"
        case false: "异常"
        case nil: updatedAt.isEmpty ? "未知" : "已响应"
        }
    }
}
