import Foundation

/// CloudBase API V2 的线上结构。
///
/// ## 这一层只负责「把 JSON 读进来」
///
/// 它不进入任何 SwiftUI 页面，也不进入 `DrawStore`。页面拿到的一律是
/// `Draw` / `DrawSchedule` / `DrawCalendarYear` 这些业务模型，
/// 转换在 `LotteryV2Mapper` 里一次做完。**网络结构一旦渗进页面，
/// 以后换一次数据源就要改几十个文件。**
///
/// ## 为什么几乎每个字段都是 Optional
///
/// 服务端会省略空值和空字段。实测的 `bootstrap.latest` 里：
/// 八个彩种都有 `issue`/`date`/`numbers`/`fetched_at`，但只有三个有
/// `prizes`、七个有 `pool`/`sales`，而文档里写的 `time` **一个都没有**
/// —— 开奖时刻实际在 `schedule.<type>.draw_time` 上。
/// 只要有一个字段写成非 Optional，那一整份响应就会解码失败，
/// 而表现是「什么数据都没有」，看不出是哪个字段的事。
///
/// 这里的 CodingKeys 全部手写，不用 `.convertFromSnakeCase`：
/// 那个策略**会连字典的键一起转换**，而 `latest` / `schedule` 是以彩种
/// 标识为键的字典，将来只要有一个彩种标识带下划线就会被悄悄改名。
enum LotteryV2 {}

// MARK: - 冷启动合集

extension LotteryV2 {
    struct Bootstrap: Decodable, Sendable {
        var schema: String?
        var version: Int?
        var generatedAt: String?
        var timezone: String?
        /// 键是**远端**彩种标识（`kl8` 而不是 `k8`）。
        var latest: [String: DrawItem]?
        var schedule: [String: Schedule]?

        enum CodingKeys: String, CodingKey {
            case schema, version, timezone, latest, schedule
            case generatedAt = "generated_at"
        }
    }

    /// 一个彩种的开奖日程。开奖星期、开奖时刻、销售截止、下一期推算。
    struct Schedule: Decodable, Sendable {
        var name: String?
        /// 0 为周日，和 `ChinaClock.weekday` 同一套。
        var weekdays: [Int]?
        /// "21:15"
        var drawTime: String?
        /// "20:00"
        var saleCloseTime: String?
        var next: NextDraw?

        enum CodingKeys: String, CodingKey {
            case name, weekdays, next
            case drawTime = "draw_time"
            case saleCloseTime = "sale_close_time"
        }
    }

    /// 下一期。**可能只是按周期推算出来的**，见 `confirmed` / `status`。
    struct NextDraw: Decodable, Sendable {
        var issue: FlexibleText?
        var date: String?
        /// 完整时刻 "2026-09-22 21:15:00"
        var openTime: String?
        var buyEndTime: String?
        var status: String?
        var source: String?
        var confirmed: Bool?
        var basisIssue: FlexibleText?

        enum CodingKeys: String, CodingKey {
            case issue, date, status, source, confirmed
            case openTime = "open_time"
            case buyEndTime = "buy_end_time"
            case basisIssue = "basis_issue"
        }
    }
}

// MARK: - 开奖条目

extension LotteryV2 {
    struct DrawItem: Decodable, Sendable {
        var issue: FlexibleText?
        var date: String?
        /// 文档里有，实测的数据里没有。留着，有就用。
        var time: String?
        var numbers: Numbers?
        var pool: FlexibleText?
        var sales: FlexibleText?
        var prizes: [Prize]?
        var fetchedAt: String?

        enum CodingKeys: String, CodingKey {
            case issue, date, time, numbers, pool, sales, prizes
            case fetchedAt = "fetched_at"
        }
    }

    /// 号码区。每个彩种只出现自己那一组键。
    struct Numbers: Decodable, Sendable {
        var red: [Int]?
        var blue: [Int]?
        var front: [Int]?
        var back: [Int]?
        var nums: [Int]?
        var digits: [Int]?
        var basic: [Int]?
        var special: Int?
    }

    /// 一条奖级。
    ///
    /// **字段名和 V1 完全不同**（V1 是 `prize_name`/`require`/`winning_count`/
    /// `prize_amount`/`additional_amount`）。大乐透的追加两版都是**独立的
    /// 「追加一等奖」行**带自己的 `amount`，不是挂在同一行的附加字段 ——
    /// 所以 `PrizeRules` 里那条追加奖金查找链不用动。
    struct Prize: Decodable, Sendable {
        var name: String?
        /// 中奖条件，如 "中5+2"。对应业务模型里的 `require`。
        var match: String?
        var winners: Int?
        var amount: FlexibleText?
        var extraWinners: Int?
        var extraAmount: FlexibleText?

        enum CodingKeys: String, CodingKey {
            case name, match, winners, amount
            case extraWinners = "extra_winners"
            case extraAmount = "extra_amount"
        }
    }
}

// MARK: - 列表端点

extension LotteryV2 {
    /// `/v2/draws/{type}`：最近 30 期。
    struct DrawsPayload: Decodable, Sendable {
        var schema: String?
        var version: Int?
        var lotteryType: String?
        var generatedAt: String?
        var limit: Int?
        var draws: [DrawItem]?

        enum CodingKeys: String, CodingKey {
            case schema, version, limit, draws
            case lotteryType = "lottery_type"
            case generatedAt = "generated_at"
        }
    }

    /// `/v2/by-year/{type}/{year}`。
    ///
    /// **`year` 和 `earliest_year` 都按 `FlexibleText` 读。**
    /// 新契约里它们是 JSON 数字，但迁移之前已经生成的 GitHub 镜像里
    /// `year` 是字符串（`"year": "2026"`）。写死 `Int?` 的话，读到旧镜像时
    /// 整份响应解码失败 —— 表现是「查看今年全部」永远没反应，而且不报任何错。
    /// 两种都吃，代价只是一次 `Int(...)`。
    struct YearPayload: Decodable, Sendable {
        var schema: String?
        var version: Int?
        var lotteryType: String?
        var year: FlexibleText?
        /// 这个彩种在数据源里**真实存在的最早年份**。
        ///
        /// 有了它，「还能不能往前翻」就是一个事实而不是猜测。
        /// 在它出现之前，客户端只能靠「某一年返回空就算到头」—— 而中间年份
        /// 恰好为空（某彩种停办过一年）时那个猜测是错的。
        /// 旧镜像没有这个字段，所以仍然是 Optional。
        var earliestYear: FlexibleText?
        var generatedAt: String?
        var draws: [DrawItem]?

        enum CodingKeys: String, CodingKey {
            case schema, version, year, draws
            case lotteryType = "lottery_type"
            case earliestYear = "earliest_year"
            case generatedAt = "generated_at"
        }
    }
}

// MARK: - 年度日历

extension LotteryV2 {
    /// `/v2/calendar/{year}`。
    ///
    /// **结构和 V1 完全不是一回事。** V1 是
    /// `lotteries: { "ssq": { name, draw_weekdays, issues: [...] } }`，
    /// V2 是一个**扁平数组**，每条自带 `lottery_type`；而且
    /// `draw_time` / `sale_close_time` 只有时刻（`"21:15:00"`），没有日期。
    /// 业务模型要的是完整时刻，拼接在 `LotteryV2Mapper` 里做。
    struct CalendarPayload: Decodable, Sendable {
        var schema: String?
        var version: Int?
        /// 同 `YearPayload.year`：实际是字符串，不能按 `Int` 解。
        var year: FlexibleText?
        var generatedAt: String?
        var entries: [CalendarEntry]?

        enum CodingKeys: String, CodingKey {
            case schema, version, year, entries
            case generatedAt = "generated_at"
        }
    }

    struct CalendarEntry: Decodable, Sendable {
        var lotteryType: String?
        var issue: FlexibleText?
        var date: String?
        /// 只有时刻 "21:15:00"
        var drawTime: String?
        /// 只有时刻 "20:00:00"
        var saleCloseTime: String?

        enum CodingKeys: String, CodingKey {
            case issue, date
            case lotteryType = "lottery_type"
            case drawTime = "draw_time"
            case saleCloseTime = "sale_close_time"
        }
    }
}

// MARK: - 数据源健康

extension LotteryV2 {
    /// `/v2/health`：**数据源自己的体检报告**，不是开奖数据。
    ///
    /// 用处只有一个场景：用户说「开奖号怎么没更新」时，用来分清是谁的锅 ——
    /// 它说正常就是 App 这边的事（缓存没刷、请求失败），它说抓取卡住了就是
    /// 后端的事，App 怎么重试都没用。
    ///
    /// **绝不进冷启动**，也没有 GitHub 兜底文件（文档 §3.5）。
    /// 只有用户打开「设置 → 开奖数据」时才请求一次。
    ///
    /// ## 字段按正式契约写，不再猜
    ///
    /// 曾经这里是「`ok` 和 `status` 两套都认、`updated_at` 和 `generated_at`
    /// 两套都认」—— 那是在文档还没给 schema 时照着 V1 的
    /// `public_data/health.json` 猜的。**V2 明确不返回 `status`、`healthy`、
    /// `updated_at`、`checked_at`、`message`**，所以那些替代字段全部去掉了。
    ///
    /// 留着猜测的害处不是解码失败，而是**解码成功但没意义**：认不出的键被
    /// 忽略、缺失的键是 nil，界面于是永远显示「未知」，而你分不清那是数据源
    /// 真的没给，还是我们字段写错了。现在必需字段缺一个就报契约错误。
    struct Health: Decodable, Sendable {
        var schema: String?
        var version: Int?
        /// **唯一的健康状态字段。**
        var ok: Bool?
        var generatedAt: String?
        var source: String?
        /// 按远端彩种标识给的最新一期。某个彩种没有记录时值是 `null`，
        /// 同时 `ok` 为 `false` —— 所以这里必须能装下 `null`。
        var latest: [String: LatestIssue]?

        enum CodingKeys: String, CodingKey {
            case schema, version, ok, source, latest
            case generatedAt = "generated_at"
        }

        /// 契约规定的固定值。
        static let expectedSchema = "duigehao.lottery.health"
        static let expectedVersion = 2
    }

    /// `latest` 里的一项。**可能整个是 `null`。**
    ///
    /// 没有写成 `[String: LatestIssue?]` —— 字典里装 Optional 依赖
    /// `Optional` 的 Decodable 合成，那条路在不同 Swift 版本上表现不一致，
    /// 踩中了就是整份 health 解码失败。自己吃掉 `null`：解出来是个空壳，
    /// `isMissing` 为真，语义一点不丢。
    struct LatestIssue: Decodable, Sendable {
        var issue: FlexibleText? = nil
        var date: String? = nil

        enum CodingKeys: String, CodingKey { case issue, date }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), single.decodeNil() { return }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            issue = try container.decodeIfPresent(FlexibleText.self, forKey: .issue)
            date = try container.decodeIfPresent(String.self, forKey: .date)
        }

        /// `null`，或者给了对象但没有期号 —— 都算「这个彩种没有记录」。
        var isMissing: Bool { (issue?.value ?? "").isEmpty }
    }
}
