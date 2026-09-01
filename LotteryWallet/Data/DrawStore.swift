import Foundation
import Observation

/// 中国标准时间的"此刻"，开奖日与截止时间都按这个判断。
struct ChinaClock: Sendable {
    /// yyyy-MM-dd
    let date: String
    /// HH:mm
    let clock: String
    /// 0 = 周日
    let weekday: Int

    static func now(_ reference: Date = Date()) -> ChinaClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DateText.chinaTimeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: reference)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        // Calendar 的 weekday 是 1...7（周日为 1），换算成 web 版的 0...6。
        return ChinaClock(date: date, clock: clock, weekday: (parts.weekday ?? 1) - 1)
    }
}

/// 开奖数据的全局状态：最新一期、往期、日历、仓库健康。
@MainActor
@Observable
final class DrawStore {
    private(set) var draws: [Draw] = []
    private(set) var calendar: DrawCalendar?
    private(set) var health: RepoHealth?
    private(set) var latestUpdatedAt: String = ""
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private(set) var loadedHistoryGames: Set<GameKey> = []

    /// 按彩种+期号建索引。核对成百上千条记录时，每条都去线性扫全部开奖
    /// 是 O(记录 × 开奖)，几百条就能让主线程停住。
    private var drawIndex: [GameKey: [String: Draw]] = [:]
    private var latestByGame: [GameKey: Draw] = [:]
    private var drawsByGame: [GameKey: [Draw]] = [:]

    private let client: LotteryDataClient

    init(client: LotteryDataClient = .shared) {
        self.client = client
    }

    // MARK: - 加载

    /// 冷启动：先拿最新一期把首页点亮，再后台补齐各彩种近 50 期。
    func bootstrap() async {
        await refresh()
        await loadAllHistories()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let client = self.client
        let latestTask = Task { try? await client.fetchLatest() }
        let calendarTask = Task { try? await client.fetchCalendar() }
        let healthTask = Task { try? await client.fetchHealth() }
        let latest = await latestTask.value
        calendar = await calendarTask.value
        health = await healthTask.value
        if let latest {
            latestUpdatedAt = latest.updatedAt
            merge(latest.draws)
            loadFailed = false
        } else {
            loadFailed = draws.isEmpty
        }
    }

    func loadHistory(for game: GameKey) async {
        guard !loadedHistoryGames.contains(game) else { return }
        // 空结果不算"已加载"：否则往期页第一次拿到空数组之后就永远停在空状态，
        // 连"重试"都点不动。
        guard let history = try? await client.fetchHistory(for: game), !history.isEmpty else { return }
        merge(history)
        loadedHistoryGames.insert(game)
    }

    /// 八个彩种的近 50 期并行拉取，电子票才能直接显示对应开奖号。
    func loadAllHistories() async {
        let games = GameKey.ordered.filter { !loadedHistoryGames.contains($0) }
        guard !games.isEmpty else { return }
        let client = self.client
        let results = await withTaskGroup(of: (GameKey, [Draw]?).self) { group -> [(GameKey, [Draw]?)] in
            for game in games {
                group.addTask { (game, try? await client.fetchHistory(for: game)) }
            }
            var collected: [(GameKey, [Draw]?)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        for (game, history) in results {
            guard let history, !history.isEmpty else { continue }
            merge(history)
            loadedHistoryGames.insert(game)
        }
    }

    /// 去重后按开奖时间倒序，逻辑同 web 版 `dedupeDraws`，顺带重建索引。
    private func merge(_ incoming: [Draw]) {
        var map = Dictionary(draws.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for draw in incoming where !draw.expect.isEmpty {
            map[draw.id] = draw
        }
        draws = map.values.sorted(by: Self.newerFirst)
        rebuildIndex()
    }

    private func rebuildIndex() {
        var byGame: [GameKey: [Draw]] = [:]
        var index: [GameKey: [String: Draw]] = [:]
        for draw in draws {
            byGame[draw.gameKey, default: []].append(draw)
            index[draw.gameKey, default: [:]][draw.expect] = draw
        }
        drawsByGame = byGame
        drawIndex = index
        // draws 已按时间倒序，每个彩种的第一条就是最新一期
        latestByGame = byGame.compactMapValues(\.first)
    }

    static func newerFirst(_ lhs: Draw, _ rhs: Draw) -> Bool {
        if lhs.openDate != rhs.openDate { return lhs.openDate > rhs.openDate }
        return lhs.expect > rhs.expect
    }

    // MARK: - 查询

    /// 开奖日程（今日开奖、轮播顺序、待更新）的变化指纹。
    /// 这几项算一次要过一遍八个彩种，页面拿它当 `task(id:)`，避免放进 body 每帧重算。
    var scheduleToken: String {
        "\(latestUpdatedAt)|\(calendar == nil ? 0 : 1)|\(draws.count)"
    }

    func draws(for game: GameKey) -> [Draw] {
        drawsByGame[game] ?? []
    }

    func latestDraw(for game: GameKey) -> Draw? {
        latestByGame[game]
    }

    func draw(for game: GameKey, expect: String) -> Draw? {
        drawIndex[game]?[expect]
    }

    /// 记录对应的开奖期。优先按绑定期号走索引，其次取购买日之后最早的一期。
    func draw(matching record: TicketRecord) -> Draw? {
        if !record.targetExpect.isEmpty {
            return drawIndex[record.game]?[record.targetExpect]
        }
        let createdDay = DateText.day(record.createdAt)
        return draws(for: record.game)
            .filter { $0.openDate.isEmpty || $0.openDate >= createdDay }
            .min { ($0.openDate, $0.expect) < ($1.openDate, $1.expect) }
    }

    // MARK: - 今日开奖

    /// 没拿到日历时的兜底周表，0 为周日。
    private static let fallbackWeekdays: [GameKey: [Int]] = [
        .ssq: [0, 2, 4], .dlt: [1, 3, 6], .qlc: [1, 3, 5], .qxc: [2, 5, 0],
        .fc3d: [0, 1, 2, 3, 4, 5, 6], .pl3: [0, 1, 2, 3, 4, 5, 6],
        .pl5: [0, 1, 2, 3, 4, 5, 6], .k8: [0, 1, 2, 3, 4, 5, 6]
    ]

    func todayOpenGames(_ now: ChinaClock = .now()) -> [GameKey] {
        GameKey.ordered.filter { game in
            if let weekdays = calendar?.entry(for: game)?.drawWeekdays {
                return weekdays.contains(now.weekday)
            }
            if calendar?.lotteries != nil { return false }
            return Self.fallbackWeekdays[game]?.contains(now.weekday) ?? false
        }
    }

    /// 首页轮播顺序：当天开奖的大乐透/双色球排头。
    func carouselOrder(_ now: ChinaClock = .now()) -> [GameKey] {
        let today = todayOpenGames(now)
        var primary: GameKey
        if today.contains(.dlt) {
            primary = .dlt
        } else if today.contains(.ssq) {
            primary = .ssq
        } else {
            // 周五两者都不开，延续最近一次开奖安排。
            let recent: [GameKey] = [.ssq, .dlt, .ssq, .dlt, .ssq, .ssq, .dlt]
            primary = recent[min(max(now.weekday, 0), 6)]
        }
        let secondary: GameKey = primary == .ssq ? .dlt : .ssq
        return [primary, secondary] + GameKey.ordered.filter { $0 != primary && $0 != secondary }
    }

    /// 今天已过开奖时刻但号码还没更新的彩种。
    func pendingDrawUpdates(_ now: ChinaClock = .now()) -> [GameKey] {
        GameKey.ordered.filter { game in
            guard let entry = calendar?.entry(for: game),
                  let weekdays = entry.drawWeekdays, weekdays.contains(now.weekday),
                  let drawTime = entry.drawTime, drawTime.count >= 5 else { return false }
            let clock = String(drawTime.prefix(5))
            guard now.clock >= clock else { return false }
            return latestDraw(for: game)?.openDate != now.date
        }
    }

    // MARK: - 下一期

    /// 下一期的元信息：日历优先，其次用最新一期里携带的预测。
    func nextDrawMetadata(for game: GameKey) -> DrawTarget? {
        let latest = latestDraw(for: game)
        let entry = calendar?.entry(for: game)
        guard latest != nil || entry != nil else { return nil }

        let statusText = entry?.nextStatus ?? latest?.nextStatus.rawValue ?? "unavailable"
        let confirmed = entry.map { $0.nextConfirmed != false } ?? (latest?.nextStatus == .confirmed)
        var status = NextDrawStatus(rawValue: statusText) ?? .unavailable
        if status == .confirmed && !confirmed { status = .inferred }

        let openTime = entry?.nextOpenTime ?? latest?.nextOpenTime ?? ""
        let openDateFallback = openTime.isEmpty ? "" : String(openTime.prefix(10))
        func pick(_ primary: String?, _ fallback: String?...) -> String {
            for value in [primary] + fallback {
                if let value, !value.isEmpty { return value }
            }
            return ""
        }

        return DrawTarget(
            expect: pick(entry?.nextIssue.text, latest?.nextExpect),
            openDate: pick(entry?.nextDrawDate, latest?.nextOpenDate, openDateFallback),
            openTime: openTime,
            buyEndTime: pick(entry?.nextBuyEndTime, latest?.nextBuyEndTime),
            sourceDrawId: latest?.id ?? "",
            status: status,
            source: pick(entry?.nextSource, latest?.nextSource, "none"),
            basisIssue: pick(entry?.nextBasisIssue.text, latest?.nextBasisIssue, latest?.expect),
            resolutionReason: pick(entry?.nextResolutionReason, latest?.nextResolutionReason)
        )
    }

    /// 录入票据时可以绑定的期次。数据不全或已截止时返回不可用并附带原因。
    func nextDrawTarget(for game: GameKey, now: Date = Date()) -> DrawTarget {
        guard var target = nextDrawMetadata(for: game) else {
            return .unavailable("暂无下期开奖数据，请稍后刷新")
        }
        guard !target.expect.isEmpty, !target.openTime.isEmpty, !target.buyEndTime.isEmpty else {
            target.isAvailable = false
            target.message = "开奖仓库尚未生成下期预测，请稍后刷新"
            return target
        }
        guard let openAt = DateText.parse(target.openTime), let buyEndAt = DateText.parse(target.buyEndTime) else {
            target.isAvailable = false
            target.message = "下期时间格式异常，请稍后刷新"
            return target
        }
        if now >= openAt {
            target.isAvailable = false
            target.message = "当期开奖号码尚未更新，请稍后再试"
            return target
        }
        if now >= buyEndAt {
            target.isAvailable = false
            target.message = "本期已截止，请等待下一期数据更新"
            return target
        }
        target.isAvailable = true
        target.message = ""
        return target
    }
}
