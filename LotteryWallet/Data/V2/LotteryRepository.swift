import Foundation

/// 开奖数据的唯一入口：缓存、两个在线源、请求去重都在这儿收口。
///
/// ## 取数顺序
///
/// ```text
/// 缓存还新鲜        → 直接用缓存，一个请求都不发
/// 缓存旧了或没有    → CloudBase V2
///                   → CloudBase 失败则 GitHub public_data/v2
///                   → 两个在线源都失败则回落到（过期的）缓存
///                   → 连缓存都没有才报错
/// ```
///
/// **一次请求只认一个来源，绝不把两边的数据拼起来。** 拼接出来的东西
/// 没有任何一个来源能解释它，出了问题无从查起。
///
/// ## 请求去重
///
/// SwiftUI 的 `.task` / `onAppear` 会重复触发，八个彩种的页面在
/// `TabView` 里还会同时活着。同一个端点在同一时刻只允许有一个网络请求，
/// 后来的调用方等前一个的结果 —— 这就是 `inFlight` 的全部作用。
actor LotteryRepository {
    static let shared = LotteryRepository()

    private let client: LotteryAPIClient
    private let cache: LotteryCache
    private var inFlight: [LotteryEndpoint: Task<(Data, LotteryDataSource), Error>] = [:]

    init(client: LotteryAPIClient = .shared, cache: LotteryCache = .shared) {
        self.client = client
        self.cache = cache
    }

    /// 一次取数的结果，带上它从哪儿来。
    struct Loaded<T: Sendable>: Sendable {
        let value: T
        let source: LotteryDataSource
        /// 来自缓存时是缓存写入时间，来自网络时是现在。
        let savedAt: Date
    }

    // MARK: - 只读缓存

    /// 只看缓存，**不发任何网络请求**。
    ///
    /// 用来「先把界面点亮」：冷启动时先拿它画一屏，再去刷新。
    /// 解不出来就说明这个文件坏了，删掉当没有 —— 只删这一个。
    func cached<T: Decodable & Sendable>(_ endpoint: LotteryEndpoint, as type: T.Type) async -> Loaded<T>? {
        guard let entry = await cache.read(endpoint) else { return nil }
        guard let value = try? decoder.decode(T.self, from: entry.data) else {
            await cache.invalidate(endpoint)
            return nil
        }
        return Loaded(value: value, source: .localCache, savedAt: entry.savedAt)
    }

    // MARK: - 取数

    /// 按上面那套顺序取一个端点。
    ///
    /// - Parameter forceRefresh: 下拉刷新用。跳过「缓存还新鲜」这一步，
    ///   但网络失败时**仍然**回落缓存 —— 用户下拉刷新失败，不该换来一个空列表。
    func load<T: Decodable & Sendable>(_ endpoint: LotteryEndpoint,
                                       as type: T.Type,
                                       forceRefresh: Bool = false) async throws -> Loaded<T> {
        if !forceRefresh,
           let entry = await cache.read(endpoint),
           entry.isFresh(for: endpoint),
           let value = try? decoder.decode(T.self, from: entry.data) {
            return Loaded(value: value, source: .localCache, savedAt: entry.savedAt)
        }

        do {
            let (data, source) = try await fetch(endpoint)
            let value = try decodeOrThrow(T.self, from: data)
            // 解码成功了才写缓存。**先写后解**的话，服务端某天改了字段名，
            // 我们会把一份解不出来的东西存进磁盘，然后离线时连旧数据都没了。
            await cache.write(data, for: endpoint)
            return Loaded(value: value, source: source, savedAt: Date())
        } catch {
            // 在线源全挂。过期的缓存仍然值钱 —— 昨天的开奖号远胜于一片空白。
            if let stale = await cached(endpoint, as: T.self) { return stale }
            throw error
        }
    }

    // MARK: - 内部

    /// 同一端点的并发请求合并成一个。
    private func fetch(_ endpoint: LotteryEndpoint) async throws -> (Data, LotteryDataSource) {
        if let existing = inFlight[endpoint] {
            return try await existing.value
        }
        let client = self.client
        let task = Task<(Data, LotteryDataSource), Error> {
            let response = try await client.fetch(endpoint)
            return (response.data, response.source)
        }
        inFlight[endpoint] = task
        defer { inFlight[endpoint] = nil }
        return try await task.value
    }

    private let decoder = JSONDecoder()

    private func decodeOrThrow<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LotteryDataError.decoding(String(describing: error))
        }
    }

    /// 数据源体检。**不缓存、不兜底、不属于任何端点**，理由见
    /// `LotteryAPIClient.fetchHealth`。只有用户打开「开奖数据」详情页才会调。
    func health() async throws -> LotteryV2.Health {
        try await client.fetchHealth()
    }

    /// 缓存写入时间，设置页「数据状态」用。
    func cacheDate(_ endpoint: LotteryEndpoint) async -> Date? {
        await cache.savedAt(endpoint)
    }
}
