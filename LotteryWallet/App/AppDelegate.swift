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

    /// 后台唤醒是可选的。即使系统跳过回调，远程通知本身也会显示开奖号码。
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard application.applicationState != .active else { return .noData }
        let result = await DrawPushCenter.shared.handleRemoteNotification(userInfo)
        return result == .unchanged ? .noData : .newData
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.trigger is UNPushNotificationTrigger {
            let result = await DrawPushCenter.shared.handleRemoteNotification(notification.request.content.userInfo)
            if result == .displayedWin { return [] }
        }
        return [.banner, .list, .sound]
    }
}
