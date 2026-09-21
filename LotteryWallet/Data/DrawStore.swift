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

    /// 东八区的当前年份。按年取往期和日历都以它为准。
    static func year(_ reference: Date = Date()) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DateText.chinaTimeZone
        return calendar.component(.year, from: reference)
    }

    /// 东八区的当前月份。只在「要不要顺带取下一年日历」这一处用。
    static func month(_ reference: Date = Date()) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DateText.chinaTimeZone
        return calendar.component(.month, from: reference)
    }
}

/// 一块数据的加载状态。
///
/// **不能只有一个全局 `isLoading`。** 上一版就是那样：往期页在拉数据，
/// 首页跟着一起转圈；某个彩种拉失败，整个 App 都显示「加载失败」。
/// 每个端点各记各的，页面才能只为自己那一块负责。
enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool { self == .loading }
    /// 试过了没有。区分「还没轮到它」和「试过但没有数据」。
    var hasTried: Bool { self != .idle }
    var hasFailed: Bool { if case .failed = self { return true }; return false }
    /// 失败原因。没失败就是 nil，页面可以直接拿它当「有没有错要显示」用。
    var failureText: String? { if case .failed(let text) = self { return text }; return nil }
}

/// 开奖数据的全局状态。
///
/// ## 渐进式加载
///
/// 冷启动**只请求 `/v2/bootstrap` 一个端点**（八个彩种的最新一期 + 开奖
/// 日程 + 下一期推算，7KB 左右）。其余一律等到用户真的要看才取：
///
/// | 用户动作 | 请求 |
/// | --- | --- |
/// | 打开 App | `/v2/bootstrap` |
/// | 进往期开奖、翻到某个彩种 | `/v2/draws/{type}`（最近 30 期） |
/// | 点「查看今年全部」 | `/v2/by-year/{type}/{今年}` |
/// | 点「加载 20XX 年」 | `/v2/by-year/{type}/{那一年}`，一次只一年 |
/// | 进录入页选期号 | `/v2/calendar/{今年}` |
///
/// 上一版冷启动一口气发 13 个请求（latest、calendar、health、两年日历、
/// 八个彩种的往期），其中 `health` 拉回来后**没有任何界面读过**。
@MainActor
@Observable
final class DrawStore {

    // MARK: - 数据

    private(set) var draws: [Draw] = []
    /// 各彩种的开奖日程。V2 把它从每条开奖记录里挪了出来，一个彩种一份。
    private(set) var schedules: [GameKey: DrawSchedule] = [:]
    private(set) var latestUpdatedAt: String = ""
    /// 年度开奖日历，按年存。
    private(set) var yearCalendars: [Int: DrawCalendarYear] = [:]

    // MARK: - 状态（四组，互不干扰）

    private(set) var bootstrapState: LoadState = .idle
    private(set) var recentStates: [GameKey: LoadState] = [:]
    private(set) var yearStates: [GameKey: [Int: LoadState]] = [:]
    private(set) var calendarStates: [Int: LoadState] = [:]
    /// 已经确认「再往前没有了」的彩种。翻到最早那一年之后就不再给「加载更早」。
    private(set) var exhaustedHistory: Set<GameKey> = []
    /// 最近一次成功取数的来源，只用于诊断。
    private(set) var lastSource: LotteryDataSource?
    /// 数据源体检结果。**只有用户打开「开奖数据」详情页才会有值。**
    private(set) var health: DataSourceHealth?
    private(set) var healthState: LoadState = .idle

    /// 各彩种最早支持翻到哪一年。再往前服务端也没有数据，别无限往下探。
    static let earliestYear = 2003

    // MARK: - 索引

    /// 按彩种+期号建索引。核对成百上千条记录时，每条都去线性扫全部开奖
    /// 是 O(记录 × 开奖)，几百条就能让主线程停住。
    private var drawIndex: [GameKey: [String: Draw]] = [:]
    private var latestByGame: [GameKey: Draw] = [:]
    private var drawsByGame: [GameKey: [Draw]] = [:]

    private let repository: LotteryRepository

    init(repository: LotteryRepository = .shared) {
        self.repository = repository
    }

    // MARK: - 冷启动

    /// 冷启动。**只取 bootstrap，一个端点。**
    ///
    /// 先用磁盘上那份把界面点亮，再去刷新 —— 有缓存的情况下用户看到的是
    /// 瞬间出现的开奖号，而不是一圈转半秒的菊花。
    func bootstrap() async {
        if let cached = await repository.cached(.bootstrap, as: LotteryV2.Bootstrap.self) {
            applyBootstrap(cached.value, source: cached.source, updatedAt: cached.savedAt)
        }
        await refresh()
    }

    /// 刷新 bootstrap。下拉刷新和「刷新开奖数据」走这里。
    func refresh(force: Bool = true) async {
        bootstrapState = .loading
        do {
            let loaded = try await repository.load(.bootstrap,
                                                   as: LotteryV2.Bootstrap.self,
                                                   forceRefresh: force)
            applyBootstrap(loaded.value, source: loaded.source, updatedAt: loaded.savedAt)
            bootstrapState = .loaded
        } catch {
            bootstrapState = .failed(message(for: error))
        }
    }

    private func applyBootstrap(_ payload: LotteryV2.Bootstrap,
                                source: LotteryDataSource,
                                updatedAt: Date) {
        let result = LotteryV2Mapper.bootstrap(payload)
        schedules = result.schedules
        latestUpdatedAt = result.generatedAt.isEmpty ? DateText.day(updatedAt) : result.generatedAt
        lastSource = source
        merge(result.latest)
    }

    // MARK: - 最近 30 期（按彩种、按需）

    /// 进入某个彩种的往期页时调用。**只请求这一个彩种。**
    func loadRecent(for game: GameKey, force: Bool = false) async {
        if !force, recentStates[game] == .loaded { return }
        if recentStates[game] == .loading { return }
        recentStates[game] = .loading
        do {
            let loaded = try await repository.load(.recentDraws(game),
                                                   as: LotteryV2.DrawsPayload.self,
                                                   forceRefresh: force)
            lastSource = loaded.source
            merge(LotteryV2Mapper.draws(loaded.value.draws, game: game))
            recentStates[game] = .loaded
        } catch {
            recentStates[game] = .failed(message(for: error))
        }
    }

    /// 用户点「重试」：状态清干净再来一次。
    func reloadRecent(for game: GameKey) async {
        recentStates[game] = .idle
        await loadRecent(for: game, force: true)
    }

    /// 把这几个彩种的最近 30 期补齐。
    ///
    /// **只给真正需要的彩种用**，典型场景是启动自动核对时发现有票的目标期号
    /// 不在 bootstrap 的最新一期里。绝不拿它去把八个彩种一次拉满 ——
    /// 那正是上一版冷启动最贵的那一步。
    func ensureRecentDraws(for games: Set<GameKey>) async {
        // 顺序取。这条路上通常只有一两个彩种，并行省不下什么，
        // 而 `DrawStore` 是 MainActor 隔离的，扔进 TaskGroup 只会换来一堆
        // 跨隔离域的捕获问题。同端点的去重在 `LotteryRepository` 那一层。
        for game in games where recentStates[game] != .loaded && recentStates[game] != .loading {
            await loadRecent(for: game)
        }
    }

    /// 把**已经加载过的**彩种重新取一遍。
    ///
    /// 「刷新开奖数据」「重新核对」用。刷的是用户已经看过的那些，
    /// 不会顺手把没看过的七个也拉下来。
    func refreshLoadedRecents() async {
        for game in recentStates.filter({ $0.value == .loaded }).map(\.key) {
            await loadRecent(for: game, force: true)
        }
    }

    // MARK: - 按年往期（一次一年）

    /// 某个彩种已经加载过的年份，新的在前。
    func loadedYears(for game: GameKey) -> [Int] {
        (yearStates[game] ?? [:]).filter { $0.value == .loaded }.keys.sorted(by: >)
    }

    func yearState(for game: GameKey, year: Int) -> LoadState {
        yearStates[game]?[year] ?? .idle
    }

    func isLoadingAnyYear(_ game: GameKey) -> Bool {
        (yearStates[game] ?? [:]).values.contains { $0.isLoading }
    }

    /// 下一次「加载更早」该取哪一年。今年还没取就是今年，
    /// 否则是已取到的最早那年再往前一年。
    func nextYearToLoad(for game: GameKey, now: Date = Date()) -> Int? {
        guard !exhaustedHistory.contains(game) else { return nil }
        let current = ChinaClock.year(now)
        guard let earliest = loadedYears(for: game).min() else { return current }
        let candidate = earliest - 1
        return candidate >= Self.earliestYear ? candidate : nil
    }

    func hasMoreHistory(for game: GameKey, now: Date = Date()) -> Bool {
        nextYearToLoad(for: game, now: now) != nil
    }

    /// 加载某个彩种的某一年。**同一彩种同一年不会请求两次。**
    func loadYear(for game: GameKey, year: Int) async {
        let state = yearState(for: game, year: year)
        if state == .loaded || state == .loading { return }
        yearStates[game, default: [:]][year] = .loading
        do {
            let loaded = try await repository.load(.yearDraws(game, year), as: LotteryV2.YearPayload.self)
            lastSource = loaded.source
            let converted = LotteryV2Mapper.draws(loaded.value.draws, game: game)
            merge(converted)
            yearStates[game, default: [:]][year] = .loaded
            // 这一年一条都没有，说明再往前也不会有了。
            if converted.isEmpty { exhaustedHistory.insert(game) }
        } catch {
            yearStates[game, default: [:]][year] = .failed(message(for: error))
        }
    }

    /// 用户点「查看今年全部」或「加载更早」。一次只推进一年。
    func loadOlderHistory(for game: GameKey, now: Date = Date()) async {
        guard let year = nextYearToLoad(for: game, now: now) else { return }
        await loadYear(for: game, year: year)
    }

    /// 按需补齐某几年的整年开奖记录。
    ///
    /// 补核对导入的老票要用：那些票绑定的期号可能是好几年前的，
    /// 不在最近 30 期里，光靠 `/v2/draws/{type}` 永远查不到对应开奖号。
    func loadArchives(_ wanted: [GameKey: Set<Int>]) async {
        let pending = wanted.flatMap { game, years in
            years.filter { yearState(for: game, year: $0) == .idle }.map { (game, $0) }
        }
        for (game, year) in pending {
            await loadYear(for: game, year: year)
        }
    }

    // MARK: - 年度日历（按年、按需）

    /// 加载某一年的开奖日历。
    func loadCalendar(year: Int) async {
        let state = calendarStates[year] ?? .idle
        if state == .loaded || state == .loading { return }
        calendarStates[year] = .loading
        do {
            let loaded = try await repository.load(.calendar(year), as: LotteryV2.CalendarPayload.self)
            lastSource = loaded.source
            yearCalendars[year] = LotteryV2Mapper.calendarYear(loaded.value, year: year)
            calendarStates[year] = .loaded
        } catch {
            calendarStates[year] = .failed(message(for: error))
        }
    }

    /// 录入页、扫描页要选期号时调用。
    ///
    /// **默认只取当年。** 只有到了 12 月才顺带取下一年 —— 跨年那几天
    /// 「下一期」会落到明年 001，那时候确实需要明年的日历；
    /// 而在三月份把明年整年拉下来纯属浪费（这份文件 200KB 出头）。
    func loadYearCalendars(_ now: Date = Date()) async {
        let year = ChinaClock.year(now)
        await loadCalendar(year: year)
        if ChinaClock.month(now) == 12 {
            await loadCalendar(year: year + 1)
        }
    }

    // MARK: - 数据源体检

    /// 问一次数据源「你那边现在正不正常」。
    ///
    /// **只能从「设置 → 开奖数据」这一个地方调，绝不进冷启动。**
    /// 上一版每次启动都拉一次 health，而拉回来的东西从头到尾没有界面读过。
    func loadHealth(force: Bool = false) async {
        if !force, healthState == .loaded { return }
        if healthState == .loading { return }
        healthState = .loading
        do {
            health = LotteryV2Mapper.health(try await repository.health())
            healthState = .loaded
        } catch {
            health = nil
            healthState = .failed(message(for: error))
        }
    }

    // MARK: - 合并与索引

    /// 去重后按开奖时间倒序，顺带重建索引。
    private func merge(_ incoming: [Draw]) {
        guard !incoming.isEmpty else { return }
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

    private func message(for error: Error) -> String {
        (error as? LotteryDataError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - 查询

    /// 开奖日程（今日开奖、轮播顺序、待更新）的变化指纹。
    /// 这几项算一次要过一遍八个彩种，页面拿它当 `task(id:)`，避免放进 body 每帧重算。
    var scheduleToken: String {
        // 必须带上时间维度。「今日开奖」「尚未更新」「轮播顺序」算的都是
        // **此刻**的状态，可 App 挂在后台一整夜再回到前台时，数据一个字节没变，
        // 光靠数据指纹这几项就永远停在昨天。按小时分桶，跨过开奖时刻或午夜
        // 都会换一个 token。
        let now = ChinaClock.now()
        return "\(latestUpdatedAt)|\(schedules.count)|\(draws.count)|\(now.date)|\(now.clock.prefix(2))"
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

    /// 某个彩种在日历里的全部期次，按开奖日期升序。
    func calendarIssues(for game: GameKey, year: Int) -> [CalendarIssue] {
        yearCalendars[year]?.entry(for: game)?.issues ?? []
    }

    /// 从某一期开始往后数 `count` 期（含这一期本身）。
    ///
    /// 大乐透可以「追加 3 期」：同一组号码往后连打三期，票面上只印第一期的期号。
    /// 拆票的时候要把后面两期的期号和开奖日一起找出来，才能各自绑定、各自核对。
    func issuesFollowing(game: GameKey, from issue: String, count: Int) -> [CalendarIssue] {
        let all = yearCalendars.keys.sorted().flatMap { calendarIssues(for: game, year: $0) }
        guard let start = all.firstIndex(where: { $0.issue == issue }) else { return [] }
        return Array(all[start...].prefix(count))
    }

    /// 日历里现在还能买的最近一期。
    ///
    /// 这是"过了停售时间就自动落到下一期"的实现：不再去判断某一期能不能买，
    /// 而是直接在全年期次里找第一期停售时刻还没到的。跨年时会顺着接到明年 001。
    func calendarTarget(for game: GameKey, now: Date = Date()) -> DrawTarget? {
        for year in yearCalendars.keys.sorted() {
            guard let entry = yearCalendars[year]?.entry(for: game) else { continue }
            if let issue = entry.issues.first(where: { $0.isOnSale(at: now) }) {
                return issue.target()
            }
        }
        return nil
    }

    // MARK: - 今日开奖

    /// 没拿到日程时的兜底周表，0 为周日。
    private static let fallbackWeekdays: [GameKey: [Int]] = [
        .ssq: [0, 2, 4], .dlt: [1, 3, 6], .qlc: [1, 3, 5], .qxc: [2, 5, 0],
        .fc3d: [0, 1, 2, 3, 4, 5, 6], .pl3: [0, 1, 2, 3, 4, 5, 6],
        .pl5: [0, 1, 2, 3, 4, 5, 6], .k8: [0, 1, 2, 3, 4, 5, 6]
    ]

    func todayOpenGames(_ now: ChinaClock = .now()) -> [GameKey] {
        GameKey.ordered.filter { game in
            if let schedule = schedules[game], !schedule.weekdays.isEmpty {
                return schedule.opensToday(now)
            }
            // 日程拿到了、但这个彩种没给周表 —— 那就是真没有，不要瞎猜。
            if !schedules.isEmpty { return false }
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
            guard let schedule = schedules[game],
                  schedule.opensToday(now),
                  schedule.drawTimePassed(now) else { return false }
            return latestDraw(for: game)?.openDate != now.date
        }
    }

    // MARK: - 下一期

    /// 下一期的元信息。**只看 `bootstrap.schedule`**。
    ///
    /// V1 的时候这份信息是跟着每条开奖记录走的（`Draw.nextExpect` 之类），
    /// 所以要先拿到最新一期才知道下一期。V2 把它单独拎了出来，
    /// 这里也就不再从开奖记录里翻。
    func nextDrawMetadata(for game: GameKey) -> DrawTarget? {
        guard let schedule = schedules[game], let next = schedule.next else { return nil }
        return DrawTarget(
            expect: next.issue,
            openDate: next.date.isEmpty ? String(next.openTime.prefix(10)) : next.date,
            openTime: next.openTime,
            buyEndTime: next.buyEndTime,
            sourceDrawId: latestDraw(for: game)?.id ?? "",
            status: next.status,
            source: next.source.isEmpty ? "none" : next.source,
            basisIssue: next.basisIssue.isEmpty ? (latestDraw(for: game)?.expect ?? "") : next.basisIssue,
            resolutionReason: ""
        )
    }

    /// 录入票据时可以绑定的期次。
    ///
    /// 判断顺序刻意把整年日历放在最前面：`bootstrap.schedule` 只带"下一期"，
    /// 一旦当期停售、开奖号又还没更新，它就只能回一句"本期已截止"，
    /// 用户在录入页看到的是一个不能保存的死界面。而整年日历里每一期都带
    /// `sale_close_time`，只要顺着往后找第一期还没停售的，永远能给出一个
    /// 可以绑定的期次 —— 过了今天的截止时间就自动落到下一期。
    func nextDrawTarget(for game: GameKey, now: Date = Date()) -> DrawTarget {
        if let fromCalendar = calendarTarget(for: game, now: now) {
            // 日程的下期推算和日历指向同一期时，用日程那份 —— 它带着
            // confirmed / inferred 状态和推导依据，信息更全。
            if let remote = remoteNextTarget(for: game, now: now),
               remote.isAvailable, remote.expect == fromCalendar.expect {
                return remote
            }
            return fromCalendar
        }
        return remoteNextTarget(for: game, now: now) ?? .unavailable("暂无下期开奖数据，请稍后刷新")
    }

    /// 只看 `bootstrap.schedule.next` 的下期推算，日历兜底之前的那一层。
    private func remoteNextTarget(for game: GameKey, now: Date) -> DrawTarget? {
        guard var target = nextDrawMetadata(for: game) else { return nil }
        guard !target.expect.isEmpty, !target.openTime.isEmpty, !target.buyEndTime.isEmpty else {
            target.isAvailable = false
            target.message = "开奖数据源尚未生成下期预测，请稍后刷新"
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
            // 界面上不提销售状态：对用户来说这就是"下一期的数据还没到"。
            target.message = "下一期的开奖数据还没更新，请稍后刷新"
            return target
        }
        target.isAvailable = true
        target.message = ""
        return target
    }
}
