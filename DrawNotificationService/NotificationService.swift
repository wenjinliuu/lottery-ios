import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var delivery: Delivery?

    private struct Delivery {
        let handler: (UNNotificationContent) -> Void
        let fallback: UNNotificationContent
    }

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard request.content.userInfo["lottery_type"] != nil else {
            contentHandler(request.content)
            return
        }

        lock.withLock { delivery = Delivery(handler: contentHandler, fallback: request.content) }
        guard let draw = DrawPushPayload.parse(request.content.userInfo),
              let store = DrawNotificationStore.shared,
              let summary = try? store.summary(for: draw),
              let content = DrawPushPayload.personalizedContent(request.content, draw: draw, summary: summary) else {
            finish()
            return
        }

        // The app can reconcile the wallet on its next wake, even if iOS suspends this extension.
        try? store.record(draw)
        finish(with: content)
    }

    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    private func finish(with content: UNNotificationContent? = nil) {
        let ready = lock.withLock {
            let pending = delivery
            delivery = nil
            return pending
        }
        if let ready { ready.handler(content ?? ready.fallback) }
    }
}
