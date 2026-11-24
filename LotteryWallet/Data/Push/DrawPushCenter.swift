import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

/// 开奖通知：登记设备令牌，收到开奖后在本机核对。
///
/// 做成单例是因为令牌和后台通知都从 `AppDelegate` 进来，那里拿不到 SwiftUI 的环境。
@MainActor
@Observable
final class DrawPushCenter {
    static let shared = DrawPushCenter()

    /// 建库之后由 `LotteryWalletApp` 填进来。后台被通知唤醒时没有任何视图，
    /// 只能从这里拿数据库。
    private var container: ModelContainer?
    private var walletSaveObserver: (any NSObjectProtocol)?

    private(set) var isEnabled: Bool
    private(set) var status: Status = .off

    enum Status: Equatable {
        case off
        /// 系统通知权限没给。
        case denied
        /// 权限给了，在等苹果发令牌或等云端登记。
        case registering
        case on
        /// 这个安装包里没有云端密钥（模拟器构建），登记不了。
        case unavailable
        case failed(String)

        var label: String {
            switch self {
            case .off: "未开启"
            case .denied: "系统设置里关掉了通知"
            case .registering: "正在开启…"
            case .on: "已开启"
            case .unavailable: "这个版本不支持"
            case .failed(let reason): "开启失败：\(reason)"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private var lastRegistration: Date?
    private var isUpdatingRegistration = false
    private var registrationNeedsUpdate = false
    private var presenting: Set<String> = []
    private var presented: Set<String> = []
    private enum Keys {
        static let enabled = "push.drawEnabled"
        static let token = "push.deviceToken"
        static let pendingUnsubscribe = "push.pendingUnsubscribe"
    }

    private static let endpoint = URL(string: "https://wenjin-cloudbase-d1empq882391ac1-1311287495.ap-shanghai.app.tcloudbase.com/lottery/v2/devices")!

    private init() {
        // 示例模式是截图和 UI 测试用的，绝不能去要通知权限或连云端。
        isEnabled = !DemoData.isEnabled && defaults.bool(forKey: Keys.enabled)
    }

    func connectWallet(_ container: ModelContainer) {
        self.container = container
        if let walletSaveObserver { NotificationCenter.default.removeObserver(walletSaveObserver) }
        walletSaveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let container = self.container,
                      let context = notification.object as? ModelContext,
                      context.container === container else { return }
                self.publishPendingTickets()
            }
        }
    }

    private func publishPendingTickets() {
        guard let store = DrawNotificationStore.shared else { return }
        let records = isEnabled ? container.flatMap { try? Self.pendingTickets(in: ModelContext($0)) } : []
        // An empty snapshot prevents deleted or no longer readable tickets from causing alerts.
        try? store.replacePendingTickets(records ?? [])
    }

    static func pendingTickets(in context: ModelContext) throws -> [DrawNotificationStore.PendingTicket] {
        let pending = RecordStatus.pending.rawValue
        let review = NextDrawStatus.review.rawValue
        let descriptor = FetchDescriptor<TicketRecord>(predicate: #Predicate {
            $0.statusRaw == pending && $0.targetStatusRaw != review && $0.targetExpect != ""
        })
        return try context.fetch(descriptor).compactMap { record in
            guard let game = GameKey(rawValue: record.gameRaw) else { return nil }
            return .init(game: game, issue: record.targetExpect, date: record.targetOpenDate,
                         numbers: record.numbersData, multiple: record.multiple, cost: record.cost)
        }
    }

    @discardableResult
    func applyNotificationResults() -> Bool {
        guard isEnabled, let container, let store = DrawNotificationStore.shared,
              let files = try? store.receiptFiles(), !files.isEmpty else { return false }
        let context = ModelContext(container)
        var updated = false
        for file in files {
            do {
                let draw = try JSONDecoder().decode(Draw.self, from: Data(contentsOf: file))
                guard DrawNotificationStore.isComplete(draw) else {
                    try FileManager.default.removeItem(at: file)
                    continue
                }
                let result = try settle(with: draw, in: context, requireMatchingDate: true)
                updated = result.tickets > 0 || updated
                try FileManager.default.removeItem(at: file)
            } catch {
                context.rollback()
                // Leave the receipt available for the next launch if the wallet cannot save yet.
            }
        }
        return updated
    }

    // MARK: - 开关

    /// 用户打开开关：弹系统授权，同意后向苹果要令牌。
    func enable() async {
        guard !DemoData.isEnabled else { return }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            status = .denied
            return
        }
        isEnabled = true
        defaults.set(true, forKey: Keys.enabled)
        publishPendingTickets()
        defaults.removeObject(forKey: Keys.pendingUnsubscribe)
        lastRegistration = nil
        status = .registering
        UIApplication.shared.registerForRemoteNotifications()
    }

    func disable() async {
        isEnabled = false
        defaults.set(false, forKey: Keys.enabled)
        publishPendingTickets()
        defaults.set(true, forKey: Keys.pendingUnsubscribe)
        lastRegistration = nil
        status = .off
        UIApplication.shared.unregisterForRemoteNotifications()
        await syncRegistration()
    }

    /// 冷启动刷新登记。回到前台也会重试未完成的操作。
    func refreshOnLaunch() async {
        guard !DemoData.isEnabled else { return }
        applyNotificationResults()
        publishPendingTickets()
        guard isEnabled else {
            if defaults.bool(forKey: Keys.pendingUnsubscribe) { await syncRegistration() }
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            if status != .on { status = .registering }
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            status = .denied
        default:
            status = .off
        }
    }

    func didRegister(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        if defaults.string(forKey: Keys.token) != token { lastRegistration = nil }
        defaults.set(token, forKey: Keys.token)
        if isEnabled || defaults.bool(forKey: Keys.pendingUnsubscribe) { await syncRegistration() }
    }

    func didFailToRegister(_ error: Error) {
        guard isEnabled else { return }
        status = .failed(error.localizedDescription)
    }

    private func syncRegistration() async {
        registrationNeedsUpdate = true
        guard !isUpdatingRegistration else { return }
        isUpdatingRegistration = true
        defer { isUpdatingRegistration = false }
        while registrationNeedsUpdate {
            registrationNeedsUpdate = false
            guard let token = defaults.string(forKey: Keys.token) else { return }
            let enabled = isEnabled
            let recent = lastRegistration.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false
            if enabled && status == .on && recent { return }
            if !enabled && !defaults.bool(forKey: Keys.pendingUnsubscribe) { return }
            do {
                try await register(token: token, enabled: enabled)
                guard enabled == isEnabled, token == defaults.string(forKey: Keys.token) else {
                    registrationNeedsUpdate = true
                    continue
                }
                if enabled {
                    lastRegistration = Date()
                    status = .on
                } else {
                    defaults.removeObject(forKey: Keys.pendingUnsubscribe)
                    status = .off
                }
            } catch RegistrationError.noKey {
                if enabled == isEnabled && enabled { status = .unavailable }
            } catch {
                if enabled == isEnabled {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    status = .failed(message)
                }
            }
        }
    }

    enum RegistrationError: LocalizedError {
        case noKey
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .noKey: "这个版本没有带云端密钥"
            case .server(let code): "云端返回错误（\(code)）"
            }
        }
    }

    private func register(token: String, enabled: Bool) async throws {
        guard let key = GeneratedLotteryReadKey.value, !key.isEmpty else { throw RegistrationError.noKey }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "X-Lottery-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.registrationBody(
            token: token,
            enabled: enabled,
            bundleID: Bundle.main.bundleIdentifier ?? "",
            passiveDraws: DrawNotificationStore.shared != nil))
        let (data, response) = try await URLSession.shared.data(for: request, delegate: LotteryReadRedirectGuard())
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              (try? JSONDecoder().decode(RegistrationResponse.self, from: data))?.ok == true else {
            throw RegistrationError.server(code)
        }
    }

    private struct RegistrationResponse: Decodable { let ok: Bool }

    static func registrationBody(token: String, enabled: Bool, bundleID: String, passiveDraws: Bool) -> [String: Any] {
        ["token": token,
         "environment": usesSandboxPush ? "sandbox" : "production",
         "bundle_id": bundleID,
         "enabled": enabled,
         "passive_draws": passiveDraws]
    }

    /// Xcode 直接装的调试包走苹果的沙盒推送环境；TestFlight 和正式包走生产环境。
    static var usesSandboxPush: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    // MARK: - 收到开奖通知

    /// 用通知里的开奖号核对本机这一期的票，把结果写进票夹。
    ///
    /// 写库走的是 `RecordService.write`，和打开 App 时的自动核对是同一个函数 ——
    /// 之后 App 拿到正式开奖数据再核对一遍，结论一样就不会重写。
    func settle(with draw: Draw, in context: ModelContext,
                requireMatchingDate: Bool = false) throws -> DrawPushPayload.Outcome {
        let issue = draw.expect
        let records = try context.fetch(FetchDescriptor<TicketRecord>(
            predicate: #Predicate { $0.targetExpect == issue }
        )).filter {
            $0.gameRaw == draw.gameKey.rawValue &&
            (!requireMatchingDate || ($0.targetStatus != .review &&
                ($0.targetOpenDate.isEmpty || $0.targetOpenDate == draw.openDate)))
        }
        var outcome = DrawPushPayload.Outcome()
        for record in records {
            // 还没结论的、和奖金待公布的才重算；已经定了的直接用。
            let result = PrizeRules.evaluate(gameKey: record.game,
                                                 ticket: record.ticket,
                                                 draw: draw,
                                                 multiple: record.multiple)
            outcome.notification.add(result, draw: draw, ticket: record.ticket, multiple: record.multiple, cost: record.cost)
            if record.status == .pending || record.status == .prizeFloat {
                RecordService.write(result, from: draw, into: record)
            }
            outcome.add(status: record.status, prizeName: record.prizeName, amount: record.prizeAmount)
        }
        if context.hasChanges { try context.save() }
        return outcome
    }

    enum NotificationResult: Equatable {
        case unchanged
        case settled
        case displayedWin
    }

    /// 只有中奖且本地通知提交成功，前台才隐藏原始开奖通知。
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> NotificationResult {
        guard isEnabled, let draw = DrawPushPayload.parse(userInfo), let container else { return .unchanged }
        let id = DrawPushPayload.identifier(game: draw.gameKey, issue: draw.expect)
        if presented.contains(id) { return .displayedWin }
        guard !presenting.contains(id) else { return .unchanged }
        presenting.insert(id)
        defer { presenting.remove(id) }
        // 独立上下文避免通知写入失败时影响正在录入的票据。
        let context = ModelContext(container)
        guard let outcome = try? settle(with: draw, in: context), outcome.tickets > 0 else { return .unchanged }
        guard outcome.notification.winners > 0 else { return .settled }

        let content = UNMutableNotificationContent()
        let alert = (userInfo["aps"] as? [String: Any])?["alert"] as? [String: Any]
        content.title = alert?["title"] as? String ?? "\(draw.gameName) \(draw.expect) 期开奖"
        content.subtitle = alert?["body"] as? String ?? ""
        content.body = outcome.notification.body
        content.sound = .default
        content.threadIdentifier = "draw-\(draw.gameKey.apiKey)"

        let center = UNUserNotificationCenter.current()
        let request = UNNotificationRequest(identifier: "win-\(id)", content: content, trigger: nil)
        do {
            try await center.add(request)
            if presented.count >= 128 { presented.removeAll(keepingCapacity: true) }
            presented.insert(id)
            // 只移除系统已经投递的同期开奖通知，不猜测它的 APNs identifier。
            let ordinary = await center.deliveredNotifications().filter {
                $0.request.trigger is UNPushNotificationTrigger &&
                $0.request.content.userInfo["lottery_type"] as? String == draw.gameKey.apiKey &&
                ($0.request.content.userInfo["draw"] as? [String: Any])?["issue"] as? String == draw.expect
            }
            center.removeDeliveredNotifications(withIdentifiers: ordinary.map(\.request.identifier))
            return .displayedWin
        } catch {
            return .settled
        }
    }
}

extension DrawPushPayload.Outcome {
    mutating func add(status: RecordStatus, prizeName: String, amount: Double) {
        add(winning: status == .won || status == .prizeFloat, isFloating: status == .prizeFloat,
            prizeName: prizeName, amount: amount)
    }
}
