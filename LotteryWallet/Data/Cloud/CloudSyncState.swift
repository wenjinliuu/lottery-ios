import Foundation
import Security

/// 云同步在本机记的三样东西：拉到哪了、推到哪了、哪些票删了还没告诉云端。
///
/// 放 UserDefaults 而不是数据库：它们描述的是「这台设备和云端的相对位置」，
/// 不是票据本身 —— 不该进备份，换设备恢复后也应该从头对一遍。
struct CloudSyncState {
    var defaults: UserDefaults = .standard

    private enum Keys {
        static let enabled = "cloud.syncEnabled"
        static let cursor = "cloud.pullCursor"
        static let pushedAt = "cloud.lastPushedAt"
        static let syncedAt = "cloud.lastSyncedAt"
        static let tombstones = "cloud.tombstones"
        static let pushToken = "cloud.pushToken"
    }

    /// 填过个人密钥才算开启。没开启时不记删除，免得那张表无限长下去。
    var isEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    var cursor: Int {
        get { defaults.integer(forKey: Keys.cursor) }
        nonmutating set { defaults.set(newValue, forKey: Keys.cursor) }
    }

    /// 上一次成功上传**开始**的时刻。之后改过的票才需要再传。
    var lastPushedAt: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: Keys.pushedAt)) }
        nonmutating set { defaults.set(newValue.timeIntervalSince1970, forKey: Keys.pushedAt) }
    }

    var lastSyncedAt: Date? {
        get {
            let stamp = defaults.double(forKey: Keys.syncedAt)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        nonmutating set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Keys.syncedAt) }
    }

    var pushToken: String {
        get { defaults.string(forKey: Keys.pushToken) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Keys.pushToken) }
    }

    // MARK: - 删除记号

    struct Tombstone: Equatable {
        var id: String
        var game: String
        var deletedAt: Date
    }

    var tombstones: [Tombstone] {
        let raw = defaults.dictionary(forKey: Keys.tombstones) as? [String: [String: Any]] ?? [:]
        return raw.compactMap { id, value in
            guard let game = value["game"] as? String, let at = value["at"] as? Double else { return nil }
            return Tombstone(id: id, game: game, deletedAt: Date(timeIntervalSince1970: at))
        }.sorted { $0.id < $1.id }
    }

    /// 本机删了票：记下来，下次同步告诉云端。没开云同步时什么都不记。
    func recordDeletion(ids: [(id: String, game: String)], at moment: Date = Date()) {
        guard isEnabled, !ids.isEmpty else { return }
        var raw = defaults.dictionary(forKey: Keys.tombstones) as? [String: [String: Any]] ?? [:]
        for item in ids {
            raw[item.id] = ["game": item.game, "at": moment.timeIntervalSince1970]
        }
        defaults.set(raw, forKey: Keys.tombstones)
    }

    /// 同一个 id 又被写回来了（改票就是「删掉旧的几注再按新号码展开」）：
    /// 这一注没有消失，删除记号要撤掉。
    func forgetDeletion(ids: [String]) {
        guard !ids.isEmpty,
              var raw = defaults.dictionary(forKey: Keys.tombstones) as? [String: [String: Any]] else { return }
        for id in ids { raw[id] = nil }
        defaults.set(raw, forKey: Keys.tombstones)
    }

    /// 从头对一遍：下次同步把云端全部拉一次、本机全部传一次。
    func resetProgress() {
        defaults.removeObject(forKey: Keys.cursor)
        defaults.removeObject(forKey: Keys.pushedAt)
    }

    func clearAll() {
        for key in [Keys.enabled, Keys.cursor, Keys.pushedAt, Keys.syncedAt, Keys.tombstones, Keys.pushToken] {
            defaults.removeObject(forKey: key)
        }
    }
}

/// 个人密钥只放钥匙串。不进 UserDefaults、不进备份、不编进安装包。
enum CloudKeychain {
    private static let service = "com.wenjinliu.lotterywallet.cloud"
    private static let account = "user-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        // 锁屏后台同步也要读得到；不随 iCloud 钥匙串漫游到别的设备。
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }

    /// 和服务端同一条规则：32–128 位字母、数字、下划线、短横线。
    static func isWellFormed(_ key: String) -> Bool {
        key.range(of: "^[A-Za-z0-9_-]{32,128}$", options: .regularExpression) != nil
    }
}
