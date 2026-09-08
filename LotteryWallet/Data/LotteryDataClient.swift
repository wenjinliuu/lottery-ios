import Foundation

/// 开奖数据仓库的只读客户端。
/// 数据来自公开仓库 lottery-data-repo，App 不做任何写入，也不需要 API key。
actor LotteryDataClient {
    static let shared = LotteryDataClient()

    private let baseURL = URL(string: "https://raw.githubusercontent.com/wenjinliuu/lottery-data-repo/main/public_data")!
    private let session: URLSession
    private let cache: DiskCache

    init(session: URLSession = .shared, cache: DiskCache = DiskCache(folder: "lottery-data")) {
        self.session = session
        self.cache = cache
    }

    // MARK: - 拉取

    func fetchLatest() async throws -> (updatedAt: String, draws: [Draw]) {
        let payload: RemoteLatestPayload = try await load("latest.json", cacheKey: "latest")
        let draws = (payload.draws ?? [:]).compactMap { key, remote -> Draw? in
            guard let game = GameKey.fromRemoteKey(key) else { return nil }
            return Draw(remote: remote, gameKey: game)
        }
        return (payload.updatedAt ?? "", draws)
    }

    func fetchHistory(for game: GameKey) async throws -> [Draw] {
        let payload: RemoteHistoryPayload = try await load("draws/\(game.remoteKey).json", cacheKey: "draws-\(game.remoteKey)")
        return (payload.draws ?? []).compactMap { Draw(remote: $0, gameKey: game) }
    }

    func fetchCalendar() async throws -> DrawCalendar {
        try await load("calendar.json", cacheKey: "calendar")
    }

    func fetchHealth() async throws -> RepoHealth {
        try await load("health.json", cacheKey: "health")
    }

    /// 整年开奖日历。文件是按年预生成的静态文件，缓存下来跨年才会变。
    func fetchDrawCalendar(year: Int) async throws -> DrawCalendarYear {
        try await load("calendar/\(year).json", cacheKey: "calendar-\(year)")
    }

    /// 某个彩种某一年的**全部**开奖记录。
    ///
    /// `draws/{game}.json` 只有最近 50 期，补核对几个月前的老票根本够不着。
    /// 仓库另有 `by-year/{game}/{year}.json` 存整年，格式和 50 期那份一模一样。
    func fetchYearDraws(for game: GameKey, year: Int) async throws -> [Draw] {
        let payload: RemoteHistoryPayload = try await load(
            "by-year/\(game.remoteKey)/\(year).json",
            cacheKey: "by-year-\(game.remoteKey)-\(year)")
        return (payload.draws ?? []).compactMap { Draw(remote: $0, gameKey: game) }
    }

    // MARK: - 网络 + 磁盘缓存

    /// 先走网络；失败时回退到最近一次成功缓存，让离线也能看到开奖号。
    private func load<T: Decodable>(_ path: String, cacheKey: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw LotteryDataError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let decoded = try JSONDecoder().decode(T.self, from: data)
            cache.write(data, key: cacheKey)
            return decoded
        } catch {
            guard let cached = cache.read(key: cacheKey),
                  let decoded = try? JSONDecoder().decode(T.self, from: cached) else {
                throw error
            }
            return decoded
        }
    }

    /// 缓存写入时间，用于"数据状态"里的离线提示。
    func cacheDate(key: String) -> Date? { cache.modifiedAt(key: key) }
}

enum LotteryDataError: LocalizedError {
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "开奖数据读取失败（HTTP \(code)）"
        }
    }
}

/// `calendar.json`：各彩种的开奖周表与下期信息。
struct DrawCalendar: Decodable, Sendable {
    var updatedAt: String?
    var lotteries: [String: CalendarEntry]?

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case lotteries
    }

    func entry(for game: GameKey) -> CalendarEntry? {
        lotteries?[game.remoteKey] ?? lotteries?[game.rawValue]
    }
}

struct CalendarEntry: Decodable, Sendable {
    /// 开奖星期，0 为周日。
    var drawWeekdays: [Int]?
    /// 开奖时刻 "21:15"。
    var drawTime: String?
    var nextIssue: FlexibleText?
    var nextDrawDate: String?
    var nextOpenTime: String?
    var nextBuyEndTime: String?
    var nextStatus: String?
    var nextSource: String?
    var nextConfirmed: Bool?
    var nextBasisIssue: FlexibleText?
    var nextResolutionReason: String?

    enum CodingKeys: String, CodingKey {
        case drawWeekdays = "draw_weekdays"
        case drawTime = "draw_time"
        case nextIssue = "next_issue"
        case nextDrawDate = "next_draw_date"
        case nextOpenTime = "next_open_time"
        case nextBuyEndTime = "next_buy_end_time"
        case nextStatus = "next_status"
        case nextSource = "next_source"
        case nextConfirmed = "next_confirmed"
        case nextBasisIssue = "next_basis_issue"
        case nextResolutionReason = "next_resolution_reason"
    }
}

/// `health.json`：仓库自身的抓取健康度。字段可能增减，只取展示需要的部分。
struct RepoHealth: Decodable, Sendable {
    var updatedAt: String?
    var status: String?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case status
        case message
    }
}

/// 简单的 JSON 磁盘缓存，放在 Caches 目录，系统可回收。
struct DiskCache: Sendable {
    private let directory: URL

    init(folder: String) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    func write(_ data: Data, key: String) {
        try? data.write(to: url(for: key), options: .atomic)
    }

    func read(key: String) -> Data? {
        try? Data(contentsOf: url(for: key))
    }

    func modifiedAt(key: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(for: key).path))?[.modificationDate] as? Date
    }
}
