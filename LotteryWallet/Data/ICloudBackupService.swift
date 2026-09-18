import Foundation

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
    static let fileName = "lottery-backup.json"

    enum Failure: LocalizedError {
        case unavailable
        case noBackupYet

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "读不到 iCloud。请确认系统「设置 → Apple 账户 → iCloud」里已登录，并且允许「对个号」使用 iCloud 云盘。"
            case .noBackupYet:
                "iCloud 上还没有备份。先做一次备份再恢复。"
            }
        }
    }

    /// 容器里的 `Documents` 目录。
    ///
    /// **这个调用会阻塞**，Apple 明确要求不要放在主线程上 —— 首次访问要等
    /// 系统把容器准备好。所以整个类型都设计成在后台线程用，
    /// 调用方拿到结果再回主线程更新界面。
    private static func documentsURL() throws -> URL {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else {
            throw Failure.unavailable
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        if !FileManager.default.fileExists(atPath: documents.path) {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        }
        return documents
    }

    /// iCloud 现在能不能用。用户没登录 iCloud 时为 false。
    static func isAvailable() -> Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: containerID) != nil
    }

    /// 写一份备份上去。
    ///
    /// 用 `NSFileCoordinator` 而不是直接 `Data.write` —— 同一个容器可能正被
    /// 系统的同步进程读写，不协调的写入会和它撞上，轻则写坏、重则丢文件。
    static func write(_ data: Data) throws {
        let url = try documentsURL().appendingPathComponent(fileName)
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinatorError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// 读回最近一份备份。
    ///
    /// 文件在 iCloud 上但还没下到本机时，`fileExists` 是 false，
    /// 得先让系统把它拉下来再读，否则换了新手机第一次恢复必然报「没有备份」。
    static func read() throws -> Data {
        let url = try documentsURL().appendingPathComponent(fileName)
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

    /// iCloud 上那份备份的修改时间，设置页用来显示「上次备份」。
    static func lastModified() -> Date? {
        guard let documents = try? documentsURL() else { return nil }
        let url = documents.appendingPathComponent(fileName)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
