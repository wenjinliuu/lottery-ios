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

    func testWalletTopEdgeAfterScrolling() throws {
        app.tabBars.buttons["票夹"].tap()
        let title = app.navigationBars["票夹"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.71))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.43))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(title.exists)
        capture("wallet-soft-top")
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
        let range = app.segmentedControls["home.range"]
        XCTAssertTrue(range.buttons["本年"].isSelected)
        let total = app.staticTexts["home.jar.total"]
        XCTAssertTrue(total.waitForExistence(timeout: 10))
        let yearTotal = total.label
        range.buttons["本月"].tap()
        XCTAssertNotEqual(total.label, yearTotal, "球罐应按当前月份统计")
        style.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(range.buttons["本月"].isSelected)
        style.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(range.buttons["本月"].isSelected)
        style.buttons.element(boundBy: 2).tap()
        XCTAssertNotEqual(total.label, yearTotal, "切回球罐应保留本月")
        range.buttons["本年"].tap()
        XCTAssertEqual(total.label, yearTotal)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        capture("home-jar")

        shake.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        capture("home-jar-shaking")

        style.buttons.element(boundBy: 1).tap()
        let heatmap = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "逐日收支方格图")).firstMatch
        XCTAssertTrue(heatmap.waitForExistence(timeout: 10))
        capture("home-heatmap")
    }

    func testHistoricalMonthPersistsAcrossChartsAndDarkJar() {
        app.terminate()
        app.launchArguments += ["-lottery.appearance", "dark"]
        app.launch()
        let picker = app.buttons["home.profit.period"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        app.buttons["7 月"].tap()
        app.buttons["完成"].tap()
        let range = app.segmentedControls["home.range"]
        let style = app.segmentedControls["home.chart.style"]
        for index in [0, 1, 2] {
            style.buttons.element(boundBy: index).tap()
            XCTAssertTrue(range.buttons["2026-07"].isSelected)
        }
        XCTAssertTrue(app.staticTexts["home.jar.total"].waitForExistence(timeout: 10))
        capture("home-dark-july")
    }

    func testBallCountPreviews() {
        app.launchArguments.append("--store-dlt")
        for (hits, shown) in [(309, 309), (2000, 1000)] {
            app.terminate()
            app.launchEnvironment["JAR_PREVIEW_HITS"] = String(hits)
            app.launch()
            let style = app.segmentedControls["home.chart.style"]
            XCTAssertTrue(style.waitForExistence(timeout: 10))
            style.buttons.element(boundBy: 2).tap()
            let total = app.staticTexts["home.jar.total"]
            XCTAssertTrue(total.waitForExistence(timeout: 10))
            let shake = app.buttons["home.jar.shake"]
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let digits = total.label.filter(\.isNumber)
            XCTAssertEqual(digits, hits == shown ? String(hits) : "\(hits)\(shown)")
            let frame = app.descendants(matching: .any)["home.jar.frame"].firstMatch.frame
            print("JAR_PREVIEW_COUNT=\(shown) FRAME=\(frame)")
            capture("balls-\(shown)-rest")
            shake.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            capture("balls-\(shown)-shake")
        }
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
