import UIKit
import UserNotifications

/// 只为推送存在：设备令牌和后台通知都交给 `UIApplicationDelegate`，SwiftUI 没有对应的入口。
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await DrawPushCenter.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in DrawPushCenter.shared.didFailToRegister(error) }
    }

    /// 开奖通知带着 `content-available`：系统在后台把 App 叫起来几十秒，
    /// 这里用本机的票核对完，把那条通知换成中奖情况。
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await DrawPushCenter.shared.handleRemoteNotification(userInfo) ? .newData : .noData
    }

    /// App 开着的时候通知也要弹出来 —— 默认行为是前台不显示，
    /// 而晚上盯着首页等开奖恰恰是最想看到它的时候。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let isRemote = notification.request.trigger is UNPushNotificationTrigger
        if isRemote, await DrawPushCenter.shared.hasTickets(for: notification.request.content.userInfo) {
            // 这一期我有票：核对结果那条马上就来，开奖号码这条不重复弹。
            return []
        }
        return [.banner, .list, .sound]
    }
}
