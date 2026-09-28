import XCTest

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
        app.launch()
        XCTAssertTrue(app.staticTexts["累计收支"].waitForExistence(timeout: 15), "首页没有加载出来")
        // 等开奖轮播从网络拿到数据；拿不到也照样截，只是少了开奖号码
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "期")).firstMatch.waitForExistence(timeout: 15)
        settle()
        capture("01-home")

        open(tab: "票夹")
        capture("02-wallet")

        open(tab: "首页")
        let stats = app.navigationBars.buttons["统计"]
        XCTAssertTrue(stats.waitForExistence(timeout: 10), "首页没有统计入口")
        stats.tap()
        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 10), "统计页没有打开")
        settle()
        capture("03-stats")

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

        let scan = app.tabBars.buttons.matching(NSPredicate(format: "label CONTAINS %@", "扫描")).firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 15), "找不到扫描按钮")
        scan.tap()

        let recognize = app.buttons["识别这张"]
        XCTAssertTrue(recognize.waitForExistence(timeout: 15), "没有进入裁切")
        settle()
        recognize.tap()

        XCTAssertTrue(app.navigationBars["核对识别结果"].waitForExistence(timeout: 60), "识别没有完成")
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

    // MARK: - 工具

    private func open(tab: String) {
        let button = app.tabBars.buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "找不到标签：\(tab)")
        button.tap()
        settle()
    }

    /// 等切页、淡入这些动画走完。
    private func settle(_ seconds: TimeInterval = 2.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func capture(_ name: String, file: StaticString = #filePath) {
        let screenshot = XCUIScreen.main.screenshot()
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
