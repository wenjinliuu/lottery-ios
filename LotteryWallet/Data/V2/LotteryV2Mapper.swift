import Foundation

/// V2 线上结构 → 业务模型。
///
/// 整个 App 里**只有这一处**知道 V2 JSON 长什么样。页面、`DrawStore`、
/// 判奖规则拿到的都是 `Draw` / `DrawSchedule` / `DrawCalendarYear`。
enum LotteryV2Mapper {

    // MARK: - 开奖

    /// 一条开奖。
    ///
    /// `drawTime` 由调用方从 `schedule.<type>.draw_time` 传进来 ——
    /// **开奖条目自己不带时刻**，文档里写的 `time` 字段实测一个都没有。
    static func draw(_ item: LotteryV2.DrawItem, game: GameKey) -> Draw? {
        let issue = item.issue.text
        guard !issue.isEmpty else { return nil }

        var draw = Draw()
        draw.gameKey = game
        draw.gameName = game.label
        draw.expect = issue
        draw.openDate = item.date ?? ""
        draw.id = [game.rawValue, draw.expect, draw.openDate].filter { !$0.isEmpty }.joined(separator: "_")
        draw.drawValues = numbers(item.numbers, game: game)
        draw.saleAmount = item.sales.text
        draw.totalMoney = item.pool.text
        draw.prizeList = (item.prizes ?? []).map(prize)
        return draw
    }

    static func draws(_ items: [LotteryV2.DrawItem]?, game: GameKey) -> [Draw] {
        (items ?? []).compactMap { draw($0, game: game) }
    }

    /// 奖级。V2 的字段名和 V1 全不一样，对应关系写在这儿一次。
    ///
    /// `extra_winners` 没有落到业务模型上：`PrizeEntry` 没有这个概念，
    /// 界面也没有任何地方展示「追加中奖注数」。实测数据里大乐透的追加
    /// 本来就是独立的「追加一等奖」行，注数在那一行的 `winners` 上。
    private static func prize(_ item: LotteryV2.Prize) -> PrizeEntry {
        PrizeEntry(prizeName: item.name ?? "",
                   require: item.match ?? "",
                   winningCount: item.winners ?? 0,
                   singleBonus: item.amount.text,
                   addBonus: item.extraAmount.text)
    }

    /// 号码区。各彩种的键名来自实测数据，和 V1 一致。
    static func numbers(_ raw: LotteryV2.Numbers?, game: GameKey) -> NumberSet {
        guard let raw else { return NumberSet() }
        switch game {
        case .ssq:
            return NumberSet([.red: raw.red ?? [], .blue: raw.blue ?? []])
        case .dlt:
            return NumberSet([.front: raw.front ?? [], .back: raw.back ?? []])
        case .k8:
            return NumberSet([.nums: raw.nums ?? []])
        case .fc3d, .pl3, .pl5:
            return NumberSet([.nums: raw.digits ?? []])
        case .qlc:
            var set = NumberSet([.nums7: raw.basic ?? []])
            if let special = raw.special { set[.special] = [special] }
            return set
        case .qxc:
            // 七星彩的 digits 是 7 位：前六位一组，末位单独一组。
            let digits = raw.digits ?? []
            var set = NumberSet([.nums6: Array(digits.prefix(6))])
            if digits.count > 6 { set[.tail] = [digits[6]] }
            return set
        }
    }

    // MARK: - 冷启动

    struct BootstrapResult: Sendable {
        var generatedAt: String
        var latest: [Draw]
        var schedules: [GameKey: DrawSchedule]
    }

    static func bootstrap(_ payload: LotteryV2.Bootstrap) -> BootstrapResult {
        var latest: [Draw] = []
        for (key, item) in payload.latest ?? [:] {
            guard let game = GameKey.fromAPIKey(key), let converted = draw(item, game: game) else { continue }
            latest.append(converted)
        }
        var schedules: [GameKey: DrawSchedule] = [:]
        for (key, item) in payload.schedule ?? [:] {
            guard let game = GameKey.fromAPIKey(key) else { continue }
            schedules[game] = schedule(item, game: game)
        }
        return BootstrapResult(generatedAt: payload.generatedAt ?? "",
                               latest: latest,
                               schedules: schedules)
    }

    static func schedule(_ item: LotteryV2.Schedule, game: GameKey) -> DrawSchedule {
        DrawSchedule(game: game,
                     name: item.name ?? game.label,
                     weekdays: item.weekdays ?? [],
                     drawTime: item.drawTime ?? "",
                     saleCloseTime: item.saleCloseTime ?? "",
                     next: nextDraw(item.next))
    }

    /// 下一期。
    ///
    /// **推算值不能当成官方确认值。** `confirmed == false` 时无论 `status`
    /// 写什么，一律降级成 `.inferred`（界面上是「预计」）；`unavailable`
    /// 原样保留 —— 那表示服务端也给不出下一期，不该由客户端去编一个。
    static func nextDraw(_ item: LotteryV2.NextDraw?) -> NextDrawInfo? {
        guard let item else { return nil }
        let issue = item.issue.text
        var status = NextDrawStatus(rawValue: item.status ?? "") ?? .unavailable
        let confirmed = item.confirmed ?? (status == .confirmed)
        if status == .confirmed && !confirmed { status = .inferred }
        guard status != .unavailable || !issue.isEmpty else {
            return NextDrawInfo(issue: "", date: "", openTime: "", buyEndTime: "",
                                status: .unavailable, source: item.source ?? "",
                                confirmed: false, basisIssue: item.basisIssue.text)
        }
        return NextDrawInfo(issue: issue,
                            date: item.date ?? "",
                            openTime: item.openTime ?? "",
                            buyEndTime: item.buyEndTime ?? "",
                            status: status,
                            source: item.source ?? "",
                            confirmed: confirmed,
                            basisIssue: item.basisIssue.text)
    }

    // MARK: - 数据源体检

    /// 按 V2 正式契约转换，**必需字段缺一个就抛契约违例**。
    ///
    /// 不再认 V1 的 `status` / `updated_at` / `message` —— 契约明确写了
    /// V2 不返回这些。留着它们当替代品的害处不是解码失败，而是
    /// **解码成功但没意义**：界面显示「未知」，而没人分得清那是数据源没给
    /// 还是我们字段写错了。
    ///
    /// `schema` 和 `version` 也校验：它们是契约里的固定值，对不上就说明
    /// 打到的根本不是这个接口，或者契约已经变了 —— 两种都该当场说出来，
    /// 而不是继续按老结构去读一份新东西。
    static func health(_ item: LotteryV2.Health) throws -> DataSourceHealth {
        var problems: [String] = []

        if let schema = item.schema {
            if schema != LotteryV2.Health.expectedSchema {
                problems.append("schema 应为 \(LotteryV2.Health.expectedSchema)，实际是 \(schema)")
            }
        } else {
            problems.append("缺少 schema")
        }

        if let version = item.version {
            if version != LotteryV2.Health.expectedVersion {
                problems.append("version 应为 \(LotteryV2.Health.expectedVersion)，实际是 \(version)")
            }
        } else {
            problems.append("缺少 version")
        }

        if item.ok == nil { problems.append("缺少 ok") }
        if (item.generatedAt ?? "").isEmpty { problems.append("缺少 generated_at") }
        if (item.source ?? "").isEmpty { problems.append("缺少 source") }
        if item.latest == nil { problems.append("缺少 latest") }

        guard problems.isEmpty, let ok = item.ok else {
            throw LotteryDataError.contractViolation(endpoint: "/v2/health", problems: problems)
        }

        // `latest` 里值为 null 的彩种就是「这个彩种没有记录」，
        // 契约说这时候 ok 会是 false —— 把它们列出来，比一句「异常」有用。
        let latest = item.latest ?? [:]
        let missing = latest.filter(\.value.isMissing).keys.sorted()
        return DataSourceHealth(isHealthy: ok,
                                generatedAt: item.generatedAt ?? "",
                                source: item.source ?? "",
                                reportedGames: latest.count - missing.count,
                                missingGames: missing)
    }

    // MARK: - 年度日历

    /// 把扁平的 `entries` 还原成按彩种分组的年度日历。
    ///
    /// 三件 V1 不需要做、V2 必须做的事：
    ///
    /// 1. **拼完整时刻。** V2 给的是 `"21:15:00"`，没有日期；而
    ///    `CalendarIssue.saleClosesAt` 要 `DateText.parse` 得出真实时间点，
    ///    只给时刻解不出来，结果是「这一期永远不算在售」—— 录入页会直接
    ///    找不到可绑定的期次。
    /// 2. **算星期。** V2 条目里没有 `weekday`。
    /// 3. **补彩种级别的元信息。** `name` 用本地名字；开奖星期从这一年
    ///    实际出现过的星期推，比另取 `bootstrap.schedule.weekdays` 更贴近
    ///    这一年的真实安排，也让日历这一份数据自成闭环、不依赖 bootstrap。
    static func calendarYear(_ payload: LotteryV2.CalendarPayload, year: Int) -> DrawCalendarYear {
        var grouped: [GameKey: [CalendarIssue]] = [:]
        for entry in payload.entries ?? [] {
            guard let game = GameKey.fromAPIKey(entry.lotteryType ?? ""),
                  let date = entry.date, !date.isEmpty else { continue }
            let issue = entry.issue.text
            guard !issue.isEmpty else { continue }
            let drawClock = entry.drawTime ?? ""
            let closeClock = entry.saleCloseTime ?? ""
            grouped[game, default: []].append(
                CalendarIssue(issue: issue,
                              drawDate: date,
                              weekday: DateText.weekday(of: date) ?? 0,
                              drawTime: joinDateTime(date, drawClock),
                              saleCloseTime: joinDateTime(date, closeClock))
            )
        }

        var lotteries: [String: GameYearCalendar] = [:]
        for (game, issues) in grouped {
            let sorted = issues.sorted { ($0.drawDate, $0.issue) < ($1.drawDate, $1.issue) }
            lotteries[game.apiKey] = GameYearCalendar(
                name: game.label,
                drawWeekdays: Array(Set(sorted.map(\.weekday))).sorted(),
                drawTime: clock(of: sorted.first?.drawTime ?? ""),
                saleCloseTime: clock(of: sorted.first?.saleCloseTime ?? ""),
                issues: sorted)
        }
        // 以调用方请求的年份为准：响应里的 year 是字符串，且只是回显。
        return DrawCalendarYear(year: Int(payload.year.text) ?? year, lotteries: lotteries)
    }

    /// `"2026-01-01"` + `"21:15:00"` → `"2026-01-01 21:15:00"`。
    /// 时刻缺失或者已经是完整时刻时原样返回，不制造半截字符串。
    static func joinDateTime(_ date: String, _ clock: String) -> String {
        guard !clock.isEmpty else { return "" }
        if clock.contains(" ") || clock.count > 8 { return clock }
        return "\(date) \(clock)"
    }

    /// 从 `"2026-01-01 21:15:00"` 取回 `"21:15"`，给 `GameYearCalendar` 的展示字段用。
    private static func clock(of dateTime: String) -> String {
        let parts = dateTime.split(separator: " ")
        guard let time = parts.last, time.count >= 5 else { return "" }
        return String(time.prefix(5))
    }
}
