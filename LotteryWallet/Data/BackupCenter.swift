import Foundation
import SwiftData

/// 备份的留存策略。
///
/// 这些数字不是随便定的，每一条都对应一次真实的坑：
///
/// - **自动备份只留最新一份。** 每次自动备份覆盖上一份。
/// - **空库永远不写自动备份。** 见下面那段，这是保住上面那条的前提。
/// - **手动备份永不自动删除。** 用户自己点的那一下代表「这一份我要留着」，
///   程序没有资格替他回收。导出的文件更是完全在 App 管辖之外。
/// - **恢复前先存一份当前状态。** 恢复是合并覆盖，覆盖就有后悔的可能，
///   这三份快照是唯一的退路，所以它们**不跟着自动备份一起缩到一份**。
///
/// ## 自动备份为什么从 5 份改回 1 份
///
/// 改回来是用户要求的：自动备份在每次退到后台且记录变过时触发，一天下来
/// 攒出十几份长得差不多的文件，列表根本没法看。
///
/// 但要说清楚代价。**当初改成滚动 5 份，是因为「一份反复覆盖」曾经参与过
/// 一次真实的数据事故**：库变空之后退到后台，唯一那份备份当场被空数据
/// 盖掉，历史再也回不来 —— 备份最该顶用的那一刻，恰恰是它最容易自毁的
/// 那一刻。
///
/// 现在敢改回一份，是因为那条路上多了两道闸，而且都比「多留几份」更根本：
///
/// 1. **空库不写自动备份**（`autoBackup` 第一行）。当初那次事故的具体形态
///    是「空数据盖掉有数据」，这一条直接把它堵死了。
/// 2. **数据库不再会自己变空**（`ModelStore` 写死 `cloudKitDatabase: .none`）。
///    那次事故的根因是建库方式和 iCloud 权限耦合，根因已经修掉了。
///
/// 剩下的残余风险是「记录被改坏但没变空」时覆盖掉好的那一份。对着这个，
/// 用户的退路是手动备份和导出文件 —— 它们永不自动删除。
enum BackupPolicy {
    /// 自动备份保留几份。**1 = 每次覆盖上一份。** 理由见上面那段。
    static let autoKeep = 1
    /// 恢复前快照保留几份。
    ///
    /// **刻意比自动备份多。** 这三份是「恢复之后发现恢复错了」时唯一的退路，
    /// 而恢复是低频且高危的动作，留三次的余地不算多。
    static let safetyKeep = 3
}

/// 备份中心：列表、新建、恢复、删除，iCloud 和本机一视同仁。
///
/// **它不管同步。** 数据库永远是本机的（见 `ModelStore`），备份是显式的
/// 不可变快照。上一版把「iCloud 备份」做成一个开关，容易让人以为那是同步，
/// 于是两台设备互相覆盖的预期就建立起来了 —— 而它从来不是。
@MainActor
@Observable
final class BackupCenter {

    let cloud: any BackupStore = ICloudBackupStore()
    let local: any BackupStore = LocalBackupStore()

    private(set) var items: [BackupItem] = []
    private(set) var isLoading = false
    /// iCloud 现在为什么用不了。nil 表示可用。
    private(set) var cloudIssue: String?

    /// 上一次自动备份时的记录指纹。没变就不重复写。
    private var lastAutoFingerprint: String? {
        get { UserDefaults.standard.string(forKey: "lottery.backup.autoFingerprint") }
        set { UserDefaults.standard.set(newValue, forKey: "lottery.backup.autoFingerprint") }
    }

    // MARK: - 列表

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let cloudStore = cloud
        let localStore = local
        let result = await Task.detached { () -> ([BackupItem], String?) in
            let issue = cloudStore.unavailableReason()
            var all: [BackupItem] = []
            if issue == nil { all += (try? cloudStore.list()) ?? [] }
            all += (try? localStore.list()) ?? []
            return (all.sorted { $0.modifiedAt > $1.modifiedAt }, issue)
        }.value
        items = result.0
        cloudIssue = result.1
    }

    private func store(for location: BackupItem.Location) -> any BackupStore {
        location == .iCloud ? cloud : local
    }

    // MARK: - 新建

    /// 新建一份备份。
    ///
    /// iCloud 能用就写 iCloud，不能用就写本机 —— **不会因为 iCloud 不可用
    /// 就什么都不做**。上一版正是那样：iCloud 一坏，自动备份彻底静默失效，
    /// 而用户以为开关开着就有备份。
    @discardableResult
    func create(kind: BackupItem.Kind,
                data: Data,
                preferring preferred: BackupItem.Location? = nil) async throws -> BackupItem.Location {
        let name = BackupNaming.name(for: kind)
        let cloudStore = cloud
        let localStore = local
        let wanted = preferred
        let location = try await Task.detached { () -> BackupItem.Location in
            let order: [any BackupStore] = wanted == .local
                ? [localStore, cloudStore]
                : [cloudStore, localStore]
            var lastError: Error?
            for candidate in order {
                guard candidate.unavailableReason() == nil else { continue }
                do {
                    try candidate.write(data, named: name)
                    return candidate.location
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? BackupCenterError.nowhereToWrite
        }.value
        await prune()
        await reload()
        return location
    }

    /// 退到后台时的自动备份。
    ///
    /// 两道闸：记录没变过不写（省得云上堆一堆一模一样的文件），
    /// 库是空的不写（见 `BackupPolicy`）。
    func autoBackup(records: [TicketRecord],
                    context: ModelContext,
                    preferring preferred: BackupItem.Location) async {
        guard !records.isEmpty else { return }
        let fingerprint = Self.fingerprint(records)
        guard fingerprint != lastAutoFingerprint else { return }
        guard let data = try? BackupService(context: context).exportData(records: records) else { return }
        guard (try? await create(kind: .auto, data: data, preferring: preferred)) != nil else { return }
        lastAutoFingerprint = fingerprint
    }

    /// 记录集合的指纹：条数 + 最后更新时间。够用来判断「有没有变过」。
    static func fingerprint(_ records: [TicketRecord]) -> String {
        var newest = Date.distantPast
        for record in records where record.updatedAt > newest { newest = record.updatedAt }
        return "\(records.count)-\(Int(newest.timeIntervalSince1970))"
    }

    // MARK: - 恢复

    /// 恢复一份备份。**恢复前先把当前状态存成「恢复前快照」。**
    ///
    /// 恢复的语义是**合并**：备份里有的按 id 覆盖，本机多出来的不删。
    /// 这一条对两个来源、对「从文件导入」都一样，不另发明一种。
    func restore(_ item: BackupItem,
                 records: [TicketRecord],
                 context: ModelContext) async throws -> (inserted: Int, updated: Int) {
        if !records.isEmpty,
           let current = try? BackupService(context: context).exportData(records: records) {
            // 存不下去也不拦着恢复 —— 但会尽力存。
            _ = try? await create(kind: .safety, data: current, preferring: .local)
        }
        let data = try await read(item)
        return try BackupService(context: context).importData(data)
    }

    func read(_ item: BackupItem) async throws -> Data {
        let target = store(for: item.location)
        return try await Task.detached { try target.read(item) }.value
    }

    func delete(_ item: BackupItem) async throws {
        let target = store(for: item.location)
        try await Task.detached { try target.delete(item) }.value
        await reload()
    }

    func fileURL(for item: BackupItem) -> URL? {
        try? store(for: item.location).fileURL(for: item)
    }

    // MARK: - 回收

    /// 按策略回收：自动备份和恢复前快照各保留最近几份，手动备份一份不动。
    private func prune() async {
        let cloudStore = cloud
        let localStore = local
        await Task.detached {
            for candidate in [cloudStore, localStore] {
                guard candidate.unavailableReason() == nil,
                      let all = try? candidate.list() else { continue }
                Self.expired(in: all).forEach { try? candidate.delete($0) }
            }
        }.value
    }

    /// 哪些该回收。抽成静态函数是为了能单独测 —— 「不该删的被删了」
    /// 这种错一旦上线就是不可逆的。
    nonisolated static func expired(in items: [BackupItem]) -> [BackupItem] {
        let sorted = items.sorted { $0.modifiedAt > $1.modifiedAt }
        var result: [BackupItem] = []
        result += sorted.filter { if case .auto = $0.kind { return true } else { return false } }
            .dropFirst(BackupPolicy.autoKeep)
        result += sorted.filter { if case .safety = $0.kind { return true } else { return false } }
            .dropFirst(BackupPolicy.safetyKeep)
        return result
    }
}

enum BackupCenterError: LocalizedError {
    case nowhereToWrite

    var errorDescription: String? {
        switch self {
        case .nowhereToWrite: "iCloud 和本机都写不进去，备份没有做成。"
        }
    }
}
