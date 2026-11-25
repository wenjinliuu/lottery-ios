import XCTest
import Vision

/// App Store 截图：用示例票据启动，截首页、票夹、统计、扫描复核、设置五张整屏图。
///
/// 每张图都作为附件留在 `Test.xcresult` 里。手动运行 Build & Test 并勾选
/// record_snapshots 时，还会把 PNG 写进旁边的 `__Snapshots__/AppStoreScreenshotTests/`，
/// 由中央 CI 提交回分支 —— 这样拿图不用下载产物。
///
/// 这里只截图、不比对：状态栏时间、开奖轮播每次都不一样，逐像素比对只会误报。
/// 界面回归交给快照测试。
final class AppStoreScreenshotTests: XCTestCase {

    /// 扫描复核那张图用的票据照片。没有这张照片时跳过扫描截图，其余照截。
    private static let scanTicket = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/review-ticket.jpg")

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
    }

    func testCaptureStoreScreenshots() {
        app.launchArguments.append("--store-dlt")
        app.launch()
        XCTAssertTrue(app.staticTexts["累计收支"].waitForExistence(timeout: 15), "首页没有加载出来")
        // Screen readiness is established above; live network draw text is optional for demo screenshots.
        settle()
        capture("01-home")

        open(tab: "票夹")
        capture("02-wallet")

        open(tab: "设置")
        capture("05-settings")
    }

    /// 扫描复核：示例模式下把票据照片直接交给扫描页，走一遍真实的裁切和识别，
    /// 再往下滑到号码和「票面合计」那一行。预览图在示例模式下整张打了马赛克。
    func testCaptureScanReviewScreenshot() throws {
        guard FileManager.default.fileExists(atPath: Self.scanTicket.path) else {
            throw XCTSkip("没有票据照片 \(Self.scanTicket.lastPathComponent)，跳过扫描截图")
        }
        app.launchEnvironment["DEMO_SCAN_IMAGE"] = Self.scanTicket.path
        app.launch()

        let scan = app.buttons["dock.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15), "找不到扫描按钮")
        scan.tap()

        let recognize = app.buttons["识别这张"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 15), "没有进入裁切")
        settle()
        // 自动框选只是起点，对这张图容易框到票面里的一小块；用默认框（整张内缩 8%）更稳。
        app.buttons["重置"].tap()
        settle(1)
        recognize.tap()

        // 云端 Intel 模拟器上的整张票识别可能超过一分钟。
        XCTAssertTrue(app.navigationBars["核对识别结果"].waitForExistence(timeout: 180), "识别没有完成")
        settle()

        // 预览图不要，往下滑到号码和票面合计完整露出来。
        let total = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "票面共")).firstMatch
        let photo = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "放大核对")).firstMatch
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<4 where photo.exists && photo.isHittable {
            scroll.swipeUp(velocity: .slow)
            settle(1)
        }
        XCTAssertTrue(total.waitForExistence(timeout: 5), "复核页没有票面金额那一行")
        settle()
        capture("04-scan")
    }

    func testCaptureMultipleTickets() {
        let pair = Self.scanTicket.deletingLastPathComponent().appendingPathComponent("review-pair.jpg")
        app.launchEnvironment["DEMO_SCAN_IMAGE"] = pair.path
        app.launchEnvironment["DEMO_SCAN_LOCATE"] = "1"
        app.launch()
        let scan = app.buttons["dock.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15))
        scan.tap()
        XCTAssertTrue(app.staticTexts["找到 2 张票"].waitForExistence(timeout: 90))
        settle(2)
        for title in ["大乐透", "双色球"] {
            let mark = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "第 ", "张票，" + title)).firstMatch
            guard mark.waitForExistence(timeout: 90) else {
                XCTFail("票框缺少彩种标签：\(title)")
                return
            }
        }
        capture("06-multiple")
    }

    func testCaptureMaskedDisplayPair() {
        app.launchEnvironment["DEMO_SCAN_IMAGE"] = Self.scanTicket.deletingLastPathComponent()
            .appendingPathComponent("store-display-pair.jpg").path
        app.launchArguments.append("--store-display-pair")
        app.launch()
        let scan = app.buttons["dock.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15))
        scan.tap()
        XCTAssertTrue(app.staticTexts["找到 3 张票"].waitForExistence(timeout: 15))
        settle()
        capture("08-display-pair")
    }

    func testCaptureNotificationBanner() throws {
        app.launchArguments.append("--store-notification")
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let status = app.staticTexts["store.notification.status"]
        let allowAlert = board.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch
        let allowButton = board.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch

        func runSchedulingPass(timeout: TimeInterval) -> Bool {
            app.launch()
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if allowAlert.exists {
                    allowAlert.tap()
                    settle(0.6)
                } else if allowButton.exists && allowButton.isHittable {
                    allowButton.tap()
                    settle(0.6)
                }
                if status.exists {
                    let label = status.label
                    if label == "已排程 3 条" { return true }
                    if label.hasPrefix("排程失败") || label == "系统权限已关闭" { return false }
                }
                settle(0.4)
            }
            return status.exists && status.label == "已排程 3 条"
        }

        // 优先走完整授权（锁屏通知卡片无「Keep/Turn Off」提示条）：
        // 第 2 轮先重启进程刷新 XPC 会话；
        // 第 3 轮若仍出现 auth=2 但 usernoted 仓库报 Source is not authorized，通过系统「设置 → 通知 → 对个号」
        // 切换一次「允许通知」强制 BBSettingsGateway 写穿通知仓库；
        // 第 4 轮若 SpringBoard 彻底丢失权限弹窗导致未注册，退回 .provisional 静默授权兜底。
        var scheduled = runSchedulingPass(timeout: 20)
        if !scheduled {
            app.terminate()
            settle(1.2)
            scheduled = runSchedulingPass(timeout: 18)
        }
        if !scheduled {
            app.terminate()
            enableNotificationsInSettings()
            settle(1.2)
            scheduled = runSchedulingPass(timeout: 18)
        }
        if !scheduled {
            app.terminate()
            settle(1.0)
            app.launchArguments.append("--store-notification-provisional")
            scheduled = runSchedulingPass(timeout: 18)
        }
        guard scheduled else {
            let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            evidence.name = "notification-permission-failure"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTFail("系统排程状态：" + (status.exists ? status.label : app.debugDescription))
            return
        }
        // Accessibility can expose the banner before its first visible frame.
        // Read the actual screenshot pixels, and keep the very frame we verified.
        func visibleNotification() -> XCUIScreenshot? {
            let shot = XCUIScreen.main.screenshot()
            guard let image = shot.image.cgImage else { return nil }
            let read = VNRecognizeTextRequest()
            read.recognitionLanguages = ["zh-Hans", "en-US"]
            try? VNImageRequestHandler(cgImage: image).perform([read])
            let words = (read.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
            guard ["2026134", "26132", "26308", "奖金"].allSatisfy({ words.contains($0) }) else { return nil }
            return shot
        }
        XCUIDevice.shared.press(.home)
        let start = board.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.003))
        let end = board.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.85))
        start.press(forDuration: 0.15, thenDragTo: end)
        settle(8)
        for attempt in 0..<12 {
            if let shot = visibleNotification() {
                capture("07-notification", screenshot: shot)
                return
            }
            if attempt == 3 || attempt == 8 {
                let group = board.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "notifications", "条通知")).firstMatch
                if group.exists && group.isHittable { group.tap() }
            }
            if attempt == 5 {
                // Some simulator builds open on the clock with earlier alerts collapsed.
                let lower = board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
                let middle = board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.43))
                lower.press(forDuration: 0.1, thenDragTo: middle)
            }
            settle(0.5)
        }
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "notification-center-failure"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTFail("截图像素中没有同时读到期号和奖金")

    }

    // MARK: - 工具

    /// 通过 `UIApplication.openNotificationSettingsURLString` 直达「设置 → 对个号 → 通知」并切换一次「允许通知」，
    /// 强制 BBSettingsGateway 写入 usernoted 通知仓库，绕过 iOS 模拟器偶发的 auth=2 授权未落盘竞态。
    private func enableNotificationsInSettings() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settle(0.4)

        let jumper = XCUIApplication()
        jumper.launchArguments = ["--demo-data", "--open-notification-settings"]
        jumper.launch()
        _ = settings.wait(for: .runningForeground, timeout: 8)
        settle(1.0)

        let allowToggle = settings.switches
            .matching(NSPredicate(format: "label IN %@", ["Allow Notifications", "允许通知"]))
            .firstMatch
        if !allowToggle.waitForExistence(timeout: 2) && !settings.switches.firstMatch.exists {
            // 部分模拟器版本会停在「对个号」应用设置首页，点进里面的「Notifications / 通知」子页再切开关。
            let notifPredicate = NSPredicate(format: "label IN %@", ["Notifications", "通知"])
            let notifRow = [
                settings.buttons.matching(notifPredicate).firstMatch,
                settings.cells.matching(notifPredicate).firstMatch,
                settings.staticTexts.matching(notifPredicate).firstMatch
            ].first(where: { $0.exists })
            if let notifRow {
                notifRow.tap()
                settle(1.0)
            }
        }
        let toggle = allowToggle.waitForExistence(timeout: 4) ? allowToggle : settings.switches.firstMatch
        if toggle.exists || toggle.waitForExistence(timeout: 3) {
            if (toggle.value as? String) == "1" {
                toggle.tap()
                settle(0.8)
                toggle.tap()
            } else {
                toggle.tap()
            }
            settle(1.2)
        }
        settings.terminate()
        jumper.terminate()
    }

    private func open(tab: String) {
        let id: String
        switch tab {
        case "首页": id = "dock.tab.home"
        case "票夹": id = "dock.tab.wallet"
        case "设置": id = "dock.tab.settings"
        default: id = tab
        }
        let byID = app.buttons[id].firstMatch
        let button = byID.waitForExistence(timeout: 6) ? byID : app.segmentedControls["dock.tabs"].buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 6), "找不到标签：\(tab)")
        button.tap()
        settle()
    }

    /// 等切页、淡入这些动画走完。
    private func settle(_ seconds: TimeInterval = 2.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func capture(_ name: String, screenshot: XCUIScreenshot = XCUIScreen.main.screenshot(), file: StaticString = #filePath) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_RECORD"] != nil else { return }
        let folder = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__/AppStoreScreenshotTests", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
        } catch {
            XCTFail("写不进截图 \(name)：\(error)")
        }
    }
}
