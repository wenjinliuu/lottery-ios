import Foundation

/// 公共开奖数据的磁盘缓存，按端点分文件。
///
/// ## 两条硬规矩
///
/// **一、一个文件坏掉不能牵连别的。** 每个端点一个文件，读不出来就当这一个
/// 没有，直接删掉重取，绝不清空整个目录。上一版所有数据挤在一套 key 里，
/// 真要清理只能一锅端。
///
/// **二、过期不等于该删。** `savedAt` 只用来回答「要不要去刷新」。刷新失败时
/// 这份旧数据仍然是用户唯一能看到的东西 —— 过期就删的话，飞机上打开 App
/// 看到的是空白，而不是昨天的开奖号。
///
/// 放在 `Caches` 目录：这是可以从网络重新取回的公共数据，系统空间紧张时
/// 回收掉是对的。用户自己的票据不在这儿（那在 SwiftData 里，见 `ModelStore`）。
actor LotteryCache {
    static let shared = LotteryCache()

    private let directory: URL

    init(folder: String = "lottery-v2") {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for endpoint: LotteryEndpoint) -> URL {
        directory.appendingPathComponent("\(endpoint.cacheKey).json")
    }

    struct Entry: Sendable {
        let data: Data
        let savedAt: Date

        func isFresh(for endpoint: LotteryEndpoint, now: Date = Date()) -> Bool {
            now.timeIntervalSince(savedAt) < endpoint.freshness
        }
    }

    func read(_ endpoint: LotteryEndpoint) -> Entry? {
        let target = url(for: endpoint)
        guard let data = try? Data(contentsOf: target), !data.isEmpty else { return nil }
        let savedAt = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.modificationDate] as? Date
        return Entry(data: data, savedAt: savedAt ?? .distantPast)
    }

    /// 原子写。半截文件比没有文件更糟 —— 它会一直解码失败，而且看起来「有缓存」。
    func write(_ data: Data, for endpoint: LotteryEndpoint) {
        try? data.write(to: url(for: endpoint), options: .atomic)
    }

    /// 只丢掉这一个端点的缓存。解码失败时调用。
    func invalidate(_ endpoint: LotteryEndpoint) {
        try? FileManager.default.removeItem(at: url(for: endpoint))
    }

    func savedAt(_ endpoint: LotteryEndpoint) -> Date? {
        read(endpoint)?.savedAt
    }
}
