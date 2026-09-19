import Foundation
import Security

/// iCloud 备份。
///
/// **只是把导出的那份 JSON 放进 iCloud 容器，不是数据库同步。**
/// 走 CloudKit 同步 SwiftData 要求所有属性可选、不能有唯一约束，
/// `TicketRecord` 整个模型都得推倒重来 —— 为了一个备份开关不值得。
/// 这里复用 `BackupService` 已经在用的格式，文件也放在容器的 `Documents`
/// 下，用户在「文件」App 里看得见、能自己拷走，换机路径和本地备份完全一致。
///
/// 容器标识符在 `LotteryWallet.entitlements` 里声明，两处必须一致。
struct ICloudBackupService: Sendable {
    static let containerID = "iCloud.com.wenjinliu.lotterywallet"

    /// 退到后台自动写的那一份，**固定文件名、反复覆盖**。
    ///
    /// 自动备份要是每次都新建文件，用户的 iCloud 里几天就堆出上百个快照 ——
    /// 那不叫备份，叫垃圾。手动「新建备份」才留带时间戳的快照，由用户自己管。
    static let autoFileName = "lottery-backup-auto.json"
    /// 1.2.0 之前写过的名字，恢复时仍然要认。
    private static let legacyFileName = "lottery-backup.json"
    private static let manualPrefix = "lottery-backup-"

    /// 云端的一份备份文件。
    struct BackupFile: Identifiable, Hashable, Sendable {
        let name: String
        let modifiedAt: Date
        let size: Int
        /// 是不是那份反复覆盖的自动备份。
        let isAuto: Bool

        var id: String { name }
    }

    enum Failure: LocalizedError {
        /// 设备没登录 iCloud 账户。
        case notSignedIn
        /// 登录了，但这个包**根本没带 iCloud 权限** —— 构建/签名的问题，用户改不了。
        case entitlementMissing
        /// 权限有、账户也登了，但拿不到容器。基本都是 iCloud 云盘被关掉了。
        case driveUnavailable
        case noBackupYet

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                "这台设备还没登录 iCloud 账户。请到系统「设置」最上方登录 Apple 账户后再试。"
            case .entitlementMissing:
                "这个版本的安装包没有带上 iCloud 权限，属于打包问题，重试也不会好。请把这句话反馈给开发者。"
            case .driveUnavailable:
                "拿不到 iCloud 存储空间。请检查系统「设置 → Apple 账户 → iCloud → iCloud 云盘」是否打开，"
                + "并在下面的 App 列表里确认「对个号」是开着的。"
            case .noBackupYet:
                "iCloud 上还没有备份。先做一次备份再恢复。"
            }
        }
    }

    // MARK: - 诊断

    /// 这个包里到底有没有 iCloud 权限。
    ///
    /// **加这一条是因为上一版查不出问题在哪。** 「容器拿不到」至少有三种原因：
    /// 没登录账户、iCloud 云盘关着、包本身没带 entitlement。前两种用户能自己解决，
    /// 第三种用户怎么试都没用 —— 而上一版把它们混成了一句「正在准备，请稍等」，
    /// 于是用户只能一直重试。
    ///
    /// CI 是「归档不签名、导出时再签」，entitlement 到底有没有进到最终二进制里
    /// 只有在真机上问运行时才知道，所以这里直接读自己的签名。
    static func declaredContainers() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        let key = "com.apple.developer.ubiquity-container-identifiers" as CFString
        return (SecTaskCopyValueForEntitlement(task, key, nil) as? [String]) ?? []
    }

    /// 给「管理备份」页显示的一行人话诊断。
    static func diagnosticSummary() -> String {
        let containers = declaredContainers()
        let entitlement = containers.isEmpty ? "缺失" : containers.joined(separator: ", ")
        let account = isSignedIn() ? "已登录" : "未登录"
        let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) != nil
            ? "可用" : "拿不到"
        return "权限：\(entitlement)\n账户：\(account)\n容器：\(container)"
    }

    // MARK: - 可用性

    /// 用户登录 iCloud 了没有。
    ///
    /// 和「容器能不能用」是两件事，必须分开判断 —— 这正是上一版那个
    /// 「明明登录了却提示没登录」的原因：只查了容器，而容器首次访问返回 nil
    /// 被当成了没登录。`ubiquityIdentityToken` 是廉价的同步属性，查的才是登录态。
    static func isSignedIn() -> Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// 拿容器 URL，**首次会重试**。
    ///
    /// `url(forUbiquityContainerIdentifier:)` 在 App 装好后第一次调用时，
    /// 系统往往还在后台创建容器，这时候它返回 nil —— 过几秒再问就有了。
    /// 上一版只问一次就断定「iCloud 不可用」，于是用户明明登录着 iCloud，
    /// 第一次打开开关必然被拒。这里给它最多 ~3 秒去就绪。
    private static func containerURL(retries: Int = 6) -> URL? {
        for attempt in 0..<max(retries, 1) {
            if let url = FileManager.default.url(forUbiquityContainerIdentifier: containerID) {
                return url
            }
            // 没登录就不用等了，等多久都不会有
            guard isSignedIn() else { return nil }
            if attempt < retries - 1 { Thread.sleep(forTimeInterval: 0.5) }
        }
        return nil
    }

    /// iCloud 现在能不能用。
    ///
    /// 返回 nil 表示可用。三种失败**分得清清楚楚**，因为它们的解决办法完全不同：
    /// 包没带权限是开发者的问题，没登录和云盘关着是用户能自己解决的。
    static func availability() -> Failure? {
        guard !declaredContainers().isEmpty else { return .entitlementMissing }
        guard isSignedIn() else { return .notSignedIn }
        return containerURL() == nil ? .driveUnavailable : nil
    }

    /// 容器里的 `Documents` 目录。
    ///
    /// **这个调用会阻塞**，Apple 明确要求不要放在主线程上。
    /// 所以整个类型都设计成在后台线程用，调用方拿到结果再回主线程更新界面。
    private static func documentsURL() throws -> URL {
        guard let container = containerURL() else {
            throw availability() ?? Failure.driveUnavailable
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        if !FileManager.default.fileExists(atPath: documents.path) {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        }
        return documents
    }

    // MARK: - 列表 / 删除

    /// 云端现有的全部备份，按时间倒序。
    static func list() throws -> [BackupFile] {
        let documents = try documentsURL()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: documents,
                                                                 includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { $0.lastPathComponent.hasSuffix(".json") }
            .compactMap { url -> BackupFile? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let name = url.lastPathComponent
                return BackupFile(name: name,
                                  modifiedAt: values?.contentModificationDate ?? .distantPast,
                                  size: values?.fileSize ?? 0,
                                  isAuto: name == autoFileName || name == legacyFileName)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func delete(_ file: BackupFile) throws {
        let url = try documentsURL().appendingPathComponent(file.name)
        var coordinatorError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting,
                                       error: &coordinatorError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { deleteError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let deleteError { throw deleteError }
    }

    // MARK: - 读写

    /// 手动快照用的文件名，带到秒，同一天备份多次也不会互相覆盖。
    static func snapshotName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = DateText.chinaTimeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(manualPrefix)\(formatter.string(from: now)).json"
    }

    /// 写一份备份上去。
    ///
    /// 用 `NSFileCoordinator` 而不是直接 `Data.write` —— 同一个容器可能正被
    /// 系统的同步进程读写，不协调的写入会和它撞上，轻则写坏、重则丢文件。
    static func write(_ data: Data, named name: String = autoFileName) throws {
        let url = try documentsURL().appendingPathComponent(name)
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinatorError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// 读回某一份备份；不指定就读最近的那份。
    ///
    /// 文件在 iCloud 上但还没下到本机时，`fileExists` 是 false，
    /// 得先让系统把它拉下来再读，否则换了新手机第一次恢复必然报「没有备份」。
    static func read(_ file: BackupFile? = nil) throws -> Data {
        let documents = try documentsURL()
        let name: String
        if let file {
            name = file.name
        } else if let newest = try list().first {
            name = newest.name
        } else {
            throw Failure.noBackupYet
        }
        let url = documents.appendingPathComponent(name)

        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            // 等系统把文件拉下来。给 10 秒，超时就当没有 —— 总比一直卡着好。
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.noBackupYet }

        var coordinatorError: NSError?
        var result: Data?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { target in
            do { result = try Data(contentsOf: target) } catch { readError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let readError { throw readError }
        guard let result else { throw Failure.noBackupYet }
        return result
    }

    /// 最近一份备份的时间，设置页用来显示「上次备份」。
    static func lastModified() -> Date? {
        (try? list())?.first?.modifiedAt
    }
}
