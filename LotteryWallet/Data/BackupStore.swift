import Foundation

/// 备份的统一模型。
///
/// ## 为什么要有这一层
///
/// 原来「备份」在 App 里是**三套互不相干的东西**：设置页的「导出备份 /
/// 导入备份」（走系统文件选择器，文件去哪儿了 App 自己都不知道）、
/// 「iCloud 备份」开关（一个固定文件名反复覆盖）、以及「管理备份」页
/// （只看得见 iCloud 上那几个文件）。同一件事三个入口、三种语义、
/// 三处各自为政的错误处理，用户根本分不清自己的数据到底在哪儿。
///
/// 这一层把它们收拢成一句话：**备份就是一份带时间戳的 JSON 快照，
/// 它躺在某个地方 —— iCloud 或者本机。** 剩下的（列表、恢复、删除、分享、
/// 从外部导入）对两个地方是同一套操作。
///
/// 数据库本身永远是本机的、不同步的（见 `ModelStore`）。备份是**显式的、
/// 不可变的快照**，不是同步。这两件事分开，是这次数据事故之后定下的边界：
/// 一个会自己动的库 + 一个会自己覆盖的备份 = 出事时两头都救不回来。
struct BackupItem: Identifiable, Hashable, Sendable {

    enum Location: String, Sendable, CaseIterable {
        case iCloud
        case local

        var label: String {
            switch self {
            case .iCloud: "iCloud"
            case .local: "本机"
            }
        }

        var symbol: String {
            switch self {
            case .iCloud: "icloud.fill"
            case .local: "iphone"
            }
        }
    }

    /// 这份备份是怎么来的。三种来源的留存策略完全不同，必须分得清。
    enum Kind: Sendable {
        /// 退到后台时自动写的。滚动保留最近几份。
        case auto
        /// 用户自己点「新建备份」。**永不自动删除。**
        case manual
        /// 恢复之前自动存下的当前状态。出事了能退回去。
        case safety

        var label: String {
            switch self {
            case .auto: "自动备份"
            case .manual: "手动备份"
            case .safety: "恢复前快照"
            }
        }

        var symbol: String {
            switch self {
            case .auto: "arrow.triangle.2.circlepath"
            case .manual: "doc.fill"
            case .safety: "shield.lefthalf.filled"
            }
        }
    }

    let name: String
    let location: Location
    let kind: Kind
    let modifiedAt: Date
    let size: Int

    var id: String { "\(location.rawValue)/\(name)" }
}

// MARK: - 命名

/// 备份文件名的唯一约定处。
///
/// 文件名同时承担两件事：**排序**（时间戳）和**分类**（前缀）。
/// 写在一个地方，两个存储实现共用 —— 否则 iCloud 上叫一个名字、
/// 本机上叫另一个名字，同一份备份换个地方就认不出来了。
enum BackupNaming {
    static let autoPrefix = "lottery-backup-auto-"
    static let safetyPrefix = "lottery-backup-safety-"
    static let manualPrefix = "lottery-backup-"
    static let suffix = ".json"

    /// 1.2.0 之前写过的两个固定文件名，列表和恢复时仍然要认。
    static let legacyAuto = "lottery-backup-auto.json"
    static let legacyManual = "lottery-backup.json"

    static func timestamp(_ now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = DateText.chinaTimeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: now)
    }

    static func name(for kind: BackupItem.Kind, now: Date = Date()) -> String {
        let stamp = timestamp(now)
        switch kind {
        case .auto: return "\(autoPrefix)\(stamp)\(suffix)"
        case .safety: return "\(safetyPrefix)\(stamp)\(suffix)"
        case .manual: return "\(manualPrefix)\(stamp)\(suffix)"
        }
    }

    /// 从文件名反推类别。
    ///
    /// 顺序要紧：`lottery-backup-auto-…` 同时也以 `lottery-backup-` 开头，
    /// 先判自动和安全快照，剩下的才算手动。
    static func kind(of name: String) -> BackupItem.Kind {
        if name == legacyAuto { return .auto }
        if name.hasPrefix(autoPrefix) { return .auto }
        if name.hasPrefix(safetyPrefix) { return .safety }
        return .manual
    }

    static func isBackupFile(_ name: String) -> Bool {
        name.hasSuffix(suffix) && (name.hasPrefix(manualPrefix) || name == legacyManual)
    }
}

// MARK: - 存储

/// 一个能放备份的地方。iCloud 和本机各实现一遍，上层只认这个协议。
protocol BackupStore: Sendable {
    var location: BackupItem.Location { get }
    /// nil 表示现在可用；否则是**用人话写的**不可用原因。
    func unavailableReason() -> String?
    func list() throws -> [BackupItem]
    func read(_ item: BackupItem) throws -> Data
    func write(_ data: Data, named name: String) throws
    func delete(_ item: BackupItem) throws
    /// 分享 / 用系统文件选择器导出时要的真实路径。
    func fileURL(for item: BackupItem) throws -> URL
}

extension BackupStore {
    /// 把目录里的文件列成备份项。两个实现共用。
    func items(in directory: URL) -> [BackupItem] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { BackupNaming.isBackupFile($0.lastPathComponent) }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let name = url.lastPathComponent
                return BackupItem(name: name,
                                  location: location,
                                  kind: BackupNaming.kind(of: name),
                                  modifiedAt: values?.contentModificationDate ?? .distantPast,
                                  size: values?.fileSize ?? 0)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

/// 本机备份：App 沙盒 `Documents/Backups`。
///
/// 放在 `Documents` 下而不是 `Application Support`，是为了让用户在「文件」
/// App 里看得见、拷得走（配合 Info.plist 里的 `UIFileSharingEnabled`）。
/// 数据库不在这儿 —— 它在 `Application Support`，不会被顺手删掉。
///
/// **本机备份不是摆设。** iCloud 用不了（没登录、云盘关着、权限出问题）
/// 的时候，它是唯一还能落地的地方；上一版没有它，于是 iCloud 一坏，
/// 自动备份就完全静默地什么都没做。
struct LocalBackupStore: BackupStore {
    let location: BackupItem.Location = .local

    func directory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent("Backups", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    func unavailableReason() -> String? {
        (try? directory()) == nil ? "本机存储空间不可用" : nil
    }

    func list() throws -> [BackupItem] { items(in: try directory()) }

    func fileURL(for item: BackupItem) throws -> URL {
        try directory().appendingPathComponent(item.name)
    }

    func read(_ item: BackupItem) throws -> Data {
        try Data(contentsOf: try fileURL(for: item))
    }

    func write(_ data: Data, named name: String) throws {
        try data.write(to: try directory().appendingPathComponent(name), options: .atomic)
    }

    func delete(_ item: BackupItem) throws {
        try FileManager.default.removeItem(at: try fileURL(for: item))
    }
}

/// iCloud 备份：ubiquity 容器的 `Documents`。
///
/// 真正和 iCloud 打交道的细节（容器就绪、文件协调、按需下载、三态可用性）
/// 都在 `ICloudBackupService` 里，这里只是把它接到统一协议上。
struct ICloudBackupStore: BackupStore {
    let location: BackupItem.Location = .iCloud

    func unavailableReason() -> String? {
        ICloudBackupService.availability()?.errorDescription
    }

    func list() throws -> [BackupItem] {
        items(in: try ICloudBackupService.documentsDirectory())
    }

    func fileURL(for item: BackupItem) throws -> URL {
        try ICloudBackupService.documentsDirectory().appendingPathComponent(item.name)
    }

    func read(_ item: BackupItem) throws -> Data {
        try ICloudBackupService.readFile(named: item.name)
    }

    func write(_ data: Data, named name: String) throws {
        try ICloudBackupService.write(data, named: name)
    }

    func delete(_ item: BackupItem) throws {
        try ICloudBackupService.deleteFile(named: item.name)
    }
}
