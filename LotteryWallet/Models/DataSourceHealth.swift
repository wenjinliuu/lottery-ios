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
///
/// ## 这里没有「未知」
///
/// `isHealthy` 是不可选的 `Bool`。V2 契约里 `ok` 是**唯一**的健康状态字段，
/// 而且是必需的；拿不到它就说明这份响应根本不符合契约，那种情况走
/// `LotteryDataError.contractViolation`，不会变成一个「状态未知」的
/// `DataSourceHealth`。
///
/// 这条区分是有代价换来的：上一版为了兼容一份猜出来的 schema，把
/// `isHealthy` 写成 `Bool?`，于是「数据源没给」和「我们字段认错了」
/// 在界面上是同一个「未知」，谁也查不出来。
struct DataSourceHealth: Sendable, Hashable {
    /// 数据源自报正不正常。契约里 `ok` 是唯一的健康状态字段。
    let isHealthy: Bool
    /// 本次检查的生成时间，ISO-8601 带北京时间偏移。
    let generatedAt: String
    /// 数据从哪儿来，契约里固定是 `cloudbase_postgresql`。
    let source: String
    /// `latest` 里正常给出了期号的彩种数。
    let reportedGames: Int
    /// `latest` 里是 `null` 的彩种（远端标识）。
    ///
    /// 契约写明：某个彩种没有记录时它的值为 `null`，同时 `ok` 为 `false`。
    /// 所以 `ok == false` 时这里基本就是原因，直接显示出来比一句
    /// 「异常」有用得多。
    let missingGames: [String]

    var label: String { isHealthy ? "正常" : "异常" }
}
