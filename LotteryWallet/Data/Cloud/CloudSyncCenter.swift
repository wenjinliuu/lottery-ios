import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

/// 云同步的总开关和状态。界面只跟它打交道。
///
/// 做成单例是因为推送令牌从 `AppDelegate` 进来，那里拿不到 SwiftUI 的环境。
@MainActor
@Observable
final class CloudSyncCenter {
    static let shared = CloudSyncCenter()

    private(set) var isConfigured: Bool
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastSummary: CloudSyncEngine.Summary?
    private(set) var lastError: String?
    private(set) var pushStatus: PushStatus = .unknown

    enum PushStatus: Equatable {
        case unknown
        /// 系统通知权限没给。
        case denied
        /// 权限给了，在等苹果发令牌。
        case waitingForToken
        case registered
        case failed(String)

        var label: String {
            switch self {
            case .unknown: "未开启"
            case .denied: "系统设置里关掉了通知"
            case .waitingForToken: "正在注册…"
            case .registered: "已开启"
            case .failed(let reason): "注册失败：\(reason)"
            }
        }
    }

    private let state = CloudSyncState()
    private var lastAttemptAt = Date.distantPast

    private init() {
        // 示例模式是截图和 UI 测试用的内存库，绝不能连真的云端。
        isConfigured = !DemoData.isEnabled && state.isEnabled && CloudKeychain.read() != nil
        lastSyncedAt = state.lastSyncedAt
    }

    private var transport: CloudTicketClient? {
        guard isConfigured, let key = CloudKeychain.read() else { return nil }
        return CloudTicketClient(userKey: key)
    }

    // MARK: - 配置

    /// 保存个人密钥。格式不对直接拒绝，不往钥匙串里写。
    @discardableResult
    func configure(key raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !DemoData.isEnabled, CloudKeychain.isWellFormed(key), CloudKeychain.save(key) else { return false }
        state.isEnabled = true
        // 换了密钥就当成换了一个云端：从头对一遍。
        state.resetProgress()
        isConfigured = true
        lastError = nil
        return true
    }

    /// 关闭云同步。只动这台设备：云端的票、本机的票都不删。
    func disconnect() {
        CloudKeychain.clear()
        state.clearAll()
        isConfigured = false
        lastSyncedAt = nil
        lastSummary = nil
        lastError = nil
        pushStatus = .unknown
    }

    // MARK: - 同步

    /// - Parameter throttle: 自动触发时传 true，一分钟内不重复跑。
    func sync(context: ModelContext, throttle: Bool = false) async {
        guard let transport, !isSyncing else { return }
        if throttle, Date().timeIntervalSince(lastAttemptAt) < 60 { return }
        lastAttemptAt = Date()
        isSyncing = true
        // 退后台时系统只给几秒；申请一小段后台时间把这一轮跑完。
        let background = UIApplication.shared.beginBackgroundTask(withName: "cloud-sync")
        defer {
            isSyncing = false
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        do {
            lastSummary = try await CloudSyncEngine(context: context, state: state).run(transport)
            lastSyncedAt = state.lastSyncedAt
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 本机全部重传、云端全部重拉。恢复了旧备份之后用。
    func resyncEverything(context: ModelContext) async {
        state.resetProgress()
        await sync(context: context)
    }

    // MARK: - 推送

    /// 用户点「开启开奖通知」：弹系统授权，同意后向苹果要令牌。
    func enablePush() async {
        guard isConfigured else { return }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            pushStatus = .denied
            return
        }
        pushStatus = .waitingForToken
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// 每次启动：之前同意过就重新要一次令牌（苹果会不定期换）。不主动弹授权。
    func refreshPushRegistration() async {
        guard isConfigured else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            if pushStatus == .unknown { pushStatus = .waitingForToken }
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            pushStatus = .denied
        default:
            pushStatus = .unknown
        }
    }

    func didRegister(deviceToken: Data) async {
        guard let transport else { return }
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        do {
            try await transport.registerDevice(token: token,
                                               sandbox: Self.usesSandboxPush,
                                               bundleID: Bundle.main.bundleIdentifier ?? "")
            state.pushToken = token
            pushStatus = .registered
        } catch {
            pushStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func didFailToRegister(_ error: Error) {
        pushStatus = .failed(error.localizedDescription)
    }

    /// Xcode 直接装的调试包走苹果的沙盒推送环境；TestFlight 和正式包走生产环境。
    static var usesSandboxPush: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
