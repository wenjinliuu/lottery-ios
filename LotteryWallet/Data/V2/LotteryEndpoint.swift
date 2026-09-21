import Foundation

/// 公共开奖数据的四个端点。
///
/// **URL、缓存键、彩种标识三者只在这里拼一次。** 上一版把
/// `"draws/\(game.apiKey).json"` 这种字符串散在客户端的每个方法里，
/// 加一个端点就要在三处各写一遍路径和缓存键，写错了还不会报错 ——
/// 只会静默地读不到数据。
///
/// CloudBase 和 GitHub 兜底共用同一个枚举：同一份数据换个地方取，
/// 不该是两套代码。
enum LotteryEndpoint: Hashable, Sendable {
    /// 冷启动唯一请求：八个彩种的最新一期 + 开奖日程 + 下一期推算。
    case bootstrap
    /// 某个彩种最近 30 期。
    case recentDraws(GameKey)
    /// 某个彩种某一年的全部开奖。
    case yearDraws(GameKey, Int)
    /// 某一年的开奖日历。
    case calendar(Int)

    /// CloudBase 上的相对路径（不含 `/lottery` 前缀）。
    var cloudBasePath: String {
        switch self {
        case .bootstrap:
            "v2/bootstrap"
        case .recentDraws(let game):
            "v2/draws/\(game.apiKey)"
        case .yearDraws(let game, let year):
            "v2/by-year/\(game.apiKey)/\(year)"
        case .calendar(let year):
            "v2/calendar/\(year)"
        }
    }

    /// GitHub 兜底仓库里的相对路径（不含 `public_data/v2` 前缀）。
    ///
    /// 就是 CloudBase 路径加个 `.json` —— 这不是巧合，仓库里的静态文件
    /// 本来就是照着 API 路径生成的。写成派生关系而不是再抄一遍，
    /// 两边就不可能对不上。
    var githubPath: String { cloudBasePath + ".json" }

    /// 磁盘缓存键。命名照文档给的约定。
    var cacheKey: String {
        switch self {
        case .bootstrap:
            "v2-bootstrap"
        case .recentDraws(let game):
            "v2-draws-\(game.apiKey)"
        case .yearDraws(let game, let year):
            "v2-year-\(game.apiKey)-\(year)"
        case .calendar(let year):
            "v2-calendar-\(year)"
        }
    }

    /// 多久之后该去刷一次。
    ///
    /// **过期只表示「该刷了」，不表示「这份不能用了」。** 刷新失败时照样拿它
    /// 显示，见 `LotteryRepository`。已经结束的年份几乎不会再变，给一整周；
    /// 当年的数据还在长，按天刷。
    var freshness: TimeInterval {
        switch self {
        case .bootstrap, .recentDraws:
            60
        case .yearDraws(_, let year):
            year < ChinaClock.year() ? 7 * 24 * 3600 : 3600
        case .calendar(let year):
            year < ChinaClock.year() ? 30 * 24 * 3600 : 24 * 3600
        }
    }
}

// MARK: - 彩种标识

extension GameKey {
    /// 远端（CloudBase 与 GitHub 兜底共用）的彩种标识。
    ///
    /// **只有快乐8 两边不一样：App 内是 `k8`，远端是 `kl8`。**
    /// 这个映射只能有这一处。散在页面里做字符串替换，漏掉一处的表现是
    /// 「其它七个彩种都好，就快乐8 没有数据」，而且不报错。
    var apiKey: String { self == .k8 ? "kl8" : rawValue }

    static func fromAPIKey(_ key: String) -> GameKey? {
        key == "kl8" ? .k8 : GameKey(rawValue: key)
    }
}

/// 这次数据是从哪儿来的。只用于日志和诊断，不影响展示。
enum LotteryDataSource: String, Sendable {
    case cloudBase
    case githubFallback
    case localCache

    var label: String {
        switch self {
        case .cloudBase: "CloudBase"
        case .githubFallback: "GitHub 兜底"
        case .localCache: "本地缓存"
        }
    }
}
