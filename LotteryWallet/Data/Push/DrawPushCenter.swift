import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

/// 开奖通知：向苹果要令牌、告诉云端订哪些彩种、收到通知后在本机核对。
///
/// 做成单例是因为令牌和后台通知都从 `AppDelegate` 进来，那里拿不到 SwiftUI 的环境。
@MainActor
@Observable
final class DrawPushCenter {
    static let shared = DrawPushCenter()

    /// 建库之后由 `LotteryWalletApp` 填进来。后台被通知唤醒时没有任何视图，
    /// 只能从这里拿数据库。
    var container: ModelContainer?

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
    private enum Keys {
        static let enabled = "push.drawEnabled"
        static let token = "push.deviceToken"
        /// 上次成功登记的「令牌 + 彩种」，没变就不重复请求。
        static let registered = "push.registeredSignature"
    }

    private static let endpoint = URL(string: "https://wenjin-cloudbase-d1empq882391ac1-1311287495.ap-shanghai.app.tcloudbase.com/lottery/v2/devices")!

    private init() {
        // 示例模式是截图和 UI 测试用的，绝不能去要通知权限或连云端。
        isEnabled = !DemoData.isEnabled && defaults.bool(forKey: Keys.enabled)
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
        status = .registering
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// 用户关掉开关：告诉云端一个彩种都不订，本机也不再登记。
    func disable() async {
        isEnabled = false
        defaults.set(false, forKey: Keys.enabled)
        status = .off
        if let token = defaults.string(forKey: Keys.token) {
            try? await register(token: token, lotteries: [])
        }
        defaults.removeObject(forKey: Keys.registered)
    }

    /// 每次启动：之前开过就重新要一次令牌（苹果会不定期换）。不主动弹授权。
    func refreshOnLaunch() async {
        guard isEnabled else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            if status == .off { status = .registering }
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            status = .denied
        default:
            status = .off
        }
    }

    // MARK: - 登记

    func didRegister(deviceToken: Data) async {
        defaults.set(deviceToken.map { String(format: "%02x", $0) }.joined(), forKey: Keys.token)
        await syncSubscription()
    }

    func didFailToRegister(_ error: Error) {
        guard isEnabled else { return }
        status = .failed(error.localizedDescription)
    }

    /// 订阅的彩种跟着票夹走。令牌和彩种都没变就什么都不发。
    func syncSubscription() async {
        guard isEnabled, let token = defaults.string(forKey: Keys.token), let container else { return }
        let records = (try? container.mainContext.fetch(FetchDescriptor<TicketRecord>())) ?? []
        let lotteries = DrawPushPayload.subscription(records.map {
            (game: $0.game, createdAt: $0.createdAt, isPending: $0.status == .pending)
        })
        let signature = ([token] + lotteries).joined(separator: "|")
        if defaults.string(forKey: Keys.registered) == signature {
            status = .on
            return
        }
        do {
            try await register(token: token, lotteries: lotteries)
            defaults.set(signature, forKey: Keys.registered)
            status = .on
        } catch RegistrationError.noKey {
            status = .unavailable
        } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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

    private func register(token: String, lotteries: [String]) async throws {
        guard let key = GeneratedLotteryReadKey.value, !key.isEmpty else { throw RegistrationError.noKey }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "X-Lottery-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.registrationBody(
            token: token,
            lotteries: lotteries,
            bundleID: Bundle.main.bundleIdentifier ?? ""))
        let (_, response) = try await URLSession.shared.data(for: request, delegate: LotteryReadRedirectGuard())
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw RegistrationError.server(code) }
    }

    static func registrationBody(token: String, lotteries: [String], bundleID: String) -> [String: Any] {
        ["token": token,
         "environment": usesSandboxPush ? "sandbox" : "production",
         "bundle_id": bundleID,
         "lotteries": lotteries]
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
    func settle(with draw: Draw, in context: ModelContext) -> DrawPushPayload.Outcome {
        let records = ((try? context.fetch(FetchDescriptor<TicketRecord>())) ?? [])
            .filter { $0.game == draw.gameKey && $0.targetExpect == draw.expect }
        var outcome = DrawPushPayload.Outcome()
        for record in records {
            // 还没结论的、和奖金待公布的才重算；已经定了的直接用。
            if record.status == .pending || record.status == .prizeFloat {
                let result = PrizeRules.evaluate(gameKey: record.game,
                                                 ticket: record.ticket,
                                                 draw: draw,
                                                 multiple: record.multiple)
                RecordService.write(result, from: draw, into: record)
            }
            outcome.add(status: record.status, prizeName: record.prizeName, amount: record.prizeAmount)
        }
        try? context.save()
        return outcome
    }

    /// 后台被开奖通知唤醒：核对，然后用同一个标识符的本地通知换掉那条开奖号码。
    /// 返回 false 表示这条通知不是开奖通知，或者我没有这一期的票。
    @discardableResult
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard let draw = DrawPushPayload.parse(userInfo), let container else { return false }
        let outcome = settle(with: draw, in: container.mainContext)
        guard let text = outcome.text else { return false }

        let content = UNMutableNotificationContent()
        let alert = (userInfo["aps"] as? [String: Any])?["alert"] as? [String: Any]
        content.title = alert?["title"] as? String ?? "\(draw.gameName) \(draw.expect) 期开奖"
        // 开奖号码挪到副标题，正文让给中奖情况。
        content.subtitle = alert?["body"] as? String ?? ""
        content.body = text
        content.sound = outcome.won > 0 ? .default : nil
        content.threadIdentifier = "draw-\(draw.gameKey.apiKey)"
        let request = UNNotificationRequest(
            identifier: DrawPushPayload.identifier(game: draw.gameKey, issue: draw.expect),
            content: content,
            trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        return true
    }

    /// App 正开着时收到开奖通知：有这一期的票就不弹那条开奖号码
    ///（马上会弹核对结果），没有就照常弹。
    func hasTickets(for userInfo: [AnyHashable: Any]) -> Bool {
        guard let draw = DrawPushPayload.parse(userInfo), let container else { return false }
        let records = (try? container.mainContext.fetch(FetchDescriptor<TicketRecord>())) ?? []
        return records.contains { $0.game == draw.gameKey && $0.targetExpect == draw.expect }
    }
}
