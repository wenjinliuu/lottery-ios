import SwiftUI
import UIKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var delivery: Delivery?

    private struct Delivery {
        let handler: (UNNotificationContent) -> Void
        var fallback: UNNotificationContent
    }

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard request.content.userInfo["lottery_type"] != nil else {
            contentHandler(request.content)
            return
        }

        lock.withLock { delivery = Delivery(handler: contentHandler, fallback: UNMutableNotificationContent()) }
        guard let draw = DrawPushPayload.parse(request.content.userInfo),
              let store = DrawNotificationStore.shared,
              let summary = try? store.summary(for: draw),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            finish()
            return
        }

        // The app can reconcile the wallet on its next wake, even if iOS suspends this extension.
        try? store.record(draw)
        content.subtitle = content.body
        content.body = summary.body
        lock.withLock { delivery?.fallback = content }

        Task { @MainActor in
            self.finish(with: Self.attachNumbers(for: draw, to: content))
        }
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

    @MainActor
    private static func attachNumbers(for draw: Draw, to textContent: UNNotificationContent) -> UNNotificationContent {
        guard let content = textContent.mutableCopy() as? UNMutableNotificationContent else { return textContent }
        let renderer = ImageRenderer(content:
            DrawNumbersView(draw: draw, size: 30)
                .frame(width: 280, alignment: .leading)
                .padding(12)
                .background(Color(hex: 0xF2F4F8))
        )
        renderer.scale = 2
        guard let png = renderer.uiImage?.pngData() else { return textContent }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("draw-numbers.png")
            try png.write(to: file)
            content.attachments = [try UNNotificationAttachment(identifier: "draw-numbers", url: file)]
            content.subtitle = ""
            return content
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return textContent
        }
    }
}
