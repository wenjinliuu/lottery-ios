import UIKit
import UserNotifications

/// 只为推送存在：苹果把设备令牌交给 `UIApplicationDelegate`，SwiftUI 没有对应的入口。
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await CloudSyncCenter.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in CloudSyncCenter.shared.didFailToRegister(error) }
    }

    /// App 开着的时候开奖推送也要弹出来 —— 默认行为是前台不显示，
    /// 而晚上盯着首页等开奖恰恰是最想看到它的时候。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
