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

    /// 文件名的约定全在 `BackupNaming` 里，这里不再各写一套。
    ///
    /// 上一版自动备份是**固定文件名、反复覆盖**（`lottery-backup-auto.json`）。
    /// 那是个隐患：一次误操作（清库、或者库打不开变成空的）退到后台，
    /// 唯一那份备份当场被空数据覆盖，历史就再也回不来了。
    /// 现在自动备份也带时间戳、滚动保留若干份，见 `BackupPolicy`。

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
    /// CI 是「归档不签名、导出时再签」，entitlement 有没有进到最终产物里，
    /// 光看构建日志看不出来，只能在真机上问运行时。
    ///
    /// 读的是包里的 `embedded.mobileprovision`（开发、TestFlight、App Store
    /// 三种分发都带着它）。**不能用 `SecTaskCopyValueForEntitlement`** ——
    /// 那是 macOS 专有的，iOS SDK 里根本没有这个符号。
    static func declaredContainers() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return [] }

        // 描述文件是 CMS 签名包着一份 plist，把中间那段 plist 抠出来解析。
        guard let plist = extractPlist(from: data),
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        let key = "com.apple.developer.ubiquity-container-identifiers"
        if let list = entitlements[key] as? [String] { return list }
        if let single = entitlements[key] as? String { return [single] }
        return []
    }

    private static func extractPlist(from data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards) else { return nil }
        let slice = data[start.lowerBound..<end.upperBound]
        return try? PropertyListSerialization.propertyList(
            from: slice, options: [], format: nil) as? [String: Any]
    }

    /// 系统按**二进制里真正带着的** entitlement 给出的默认容器。
    ///
    /// 传 nil 问的是 entitlement 里排第一的那个容器，所以这一问能分开两件
    /// 描述文件看不出来的事：
    ///
    /// - 默认容器拿得到、指定 ID 拿不到 → 容器标识符写错了，路径里就写着对的那个；
    /// - 默认容器也拿不到 → 要么最终二进制压根没带 entitlement（描述文件里有
    ///   不代表签进去了 —— CI 是归档不签名、导出再签），要么 iCloud 云盘关着。
    ///
    /// 描述文件只能证明「Apple 那边允许」，证明不了「这个包签进去了」，
    /// 上一版的诊断就卡在这个盲区上。
    static func defaultContainerURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }

    /// 给「管理备份」页显示的人话诊断。
    ///
    /// 模拟器和某些构建里没有 `embedded.mobileprovision`，那时候「权限」这一行
    /// 只能说「读不到描述文件」，不代表真的缺 —— 别把它当成故障。
    static func diagnosticSummary() -> String {
        let hasProfile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
        let containers = declaredContainers()
        let entitlement: String
        if !containers.isEmpty {
            entitlement = containers.contains(containerID) ? "有（\(containerID)）" : "有，但容器对不上：\(containers.joined(separator: ", "))"
        } else {
            entitlement = hasProfile ? "缺失" : "读不到描述文件（模拟器上正常）"
        }
        let account = isSignedIn() ? "已登录" : "未登录"
        let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) != nil
            ? "可用" : "拿不到"
        // 目录名就是系统认的容器标识符（`iCloud.a.b.c` 会写成 `iCloud~a~b~c`），
        // 和我们写死的那个一比就知道是不是写错了。
        let fallback: String
        if let url = defaultContainerURL() {
            fallback = "可用（\(url.lastPathComponent)）"
        } else {
            fallback = "拿不到"
        }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return """
        权限：\(entitlement)
        账户：\(account)
        容器：\(container)
        默认容器：\(fallback)
        版本：\(version) (\(build))
        """
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
        // 只有「确实读到了描述文件、但里面没有这个容器」才敢断定是打包问题。
        // 读不到描述文件（模拟器）时不下结论，继续往下走真实调用。
        let hasProfile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
        if hasProfile, !declaredContainers().contains(containerID) { return .entitlementMissing }
        guard isSignedIn() else { return .notSignedIn }
        return containerURL() == nil ? .driveUnavailable : nil
    }

    /// 容器里的 `Documents` 目录。
    ///
    /// **这个调用会阻塞**，Apple 明确要求不要放在主线程上。
    /// 所以整个类型都设计成在后台线程用，调用方拿到结果再回主线程更新界面。
    static func documentsDirectory() throws -> URL {
        guard let container = containerURL() else {
            throw availability() ?? Failure.driveUnavailable
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        if !FileManager.default.fileExists(atPath: documents.path) {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        }
        return documents
    }

    // MARK: - 读写

    /// 写一份备份上去。
    ///
    /// 用 `NSFileCoordinator` 而不是直接 `Data.write` —— 同一个容器可能正被
    /// 系统的同步进程读写，不协调的写入会和它撞上，轻则写坏、重则丢文件。
    static func write(_ data: Data, named name: String) throws {
        let url = try documentsDirectory().appendingPathComponent(name)
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &coordinatorError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    static func deleteFile(named name: String) throws {
        let url = try documentsDirectory().appendingPathComponent(name)
        var coordinatorError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting,
                                       error: &coordinatorError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { deleteError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let deleteError { throw deleteError }
    }

    /// 读回某一份备份。
    ///
    /// 文件在 iCloud 上但还没下到本机时，`fileExists` 是 false，
    /// 得先让系统把它拉下来再读，否则换了新手机第一次恢复必然报「没有备份」。
    static func readFile(named name: String) throws -> Data {
        let url = try documentsDirectory().appendingPathComponent(name)

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

}
