import XCTest

/// 关键流程：只守最核心的几条路径，每条都要在真实界面上点一遍。
/// 用 `--demo-data` 启动：App 装的是内存里的示例票据，不读写用户数据。
final class KeyFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()
    }

    /// 三个主页面都能打开。
    func testEveryMainTabOpens() {
        for tab in ["票夹", "设置", "首页"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "找不到标签：\(tab)")
            button.tap()
            XCTAssertTrue(button.isSelected, "点了「\(tab)」没有切过去")
        }
    }

    /// 首页的累计收支来自示例票据：票面 734 元、奖金 1,146 元、结余 412 元
    /// （Scripts/make-demo-data.py 生成时打印的数字）。
    func testHomeShowsDemoTotals() {
        XCTAssertTrue(app.staticTexts["累计收支"].waitForExistence(timeout: 10), "首页没有累计收支")
        // 金额和「元」是分开的两段字（「元」小一号），按数字找
        for text in ["412", "734", "1,146"] {
            let element = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 10), "首页没有显示 \(text)")
        }
    }

    /// 票夹里能看到示例票据的彩种。
    func testWalletListsDemoTickets() {
        app.tabBars.buttons["票夹"].tap()
        let ticket = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                                          "双色球", "大乐透", "七乐彩", "七星彩")).firstMatch
        XCTAssertTrue(ticket.waitForExistence(timeout: 10), "票夹里没有示例票据")
    }

    /// 首页切到号码球罐：罐子出来，点「摇一摇」球会被吹起来。
    /// 录制快照时顺手存两张图（停稳的、吹起来的），改了罐子的样子可以直接看。
    func testHomeBallJar() {
        let style = app.segmentedControls["home.chart.style"]
        XCTAssertTrue(style.waitForExistence(timeout: 10), "首页没有图表样式切换")
        XCTAssertEqual(style.buttons.count, 3, "图表样式应该是曲线、方格、球罐三种")
        style.buttons.element(boundBy: 2).tap()

        let shake = app.buttons["home.jar.shake"]
        XCTAssertTrue(shake.waitForExistence(timeout: 10), "切到球罐后没有「摇一摇」")
        XCTAssertTrue(app.buttons["home.jar.scope"].exists, "球罐上没有选年份的按钮")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        capture("home-jar")

        shake.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        capture("home-jar-shaking")
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
            .appendingPathComponent("__Snapshots__/KeyFlowTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
