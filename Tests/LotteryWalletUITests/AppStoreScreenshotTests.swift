import XCTest

/// App Store 截图：用示例票据启动，截首页、票夹、设置三张整屏图。
///
/// 每张图都作为附件留在 `Test.xcresult` 里。手动运行 Build & Test 并勾选
/// record_snapshots 时，还会把 PNG 写进旁边的 `__Snapshots__/AppStoreScreenshotTests/`，
/// 由中央 CI 提交回分支 —— 这样拿图不用下载产物。
///
/// 这里只截图、不比对：状态栏时间、开奖轮播每次都不一样，逐像素比对只会误报。
/// 界面回归交给快照测试。
final class AppStoreScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()
    }

    func testCaptureStoreScreenshots() {
        XCTAssertTrue(app.staticTexts["累计收支"].waitForExistence(timeout: 15), "首页没有加载出来")
        // 等开奖轮播从网络拿到数据；拿不到也照样截，只是少了开奖号码
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "期")).firstMatch.waitForExistence(timeout: 15)
        settle()
        capture("01-home")

        open(tab: "票夹")
        capture("02-wallet")

        open(tab: "设置")
        capture("03-settings")
    }

    // MARK: - 工具

    private func open(tab: String) {
        let button = app.tabBars.buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "找不到标签：\(tab)")
        button.tap()
        settle()
    }

    /// 等切页、淡入这些动画走完。
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
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
