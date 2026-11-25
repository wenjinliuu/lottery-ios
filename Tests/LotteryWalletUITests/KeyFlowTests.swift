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

    private func dockTab(_ name: String) -> XCUIElement {
        let id: String
        switch name {
        case "首页": id = "dock.tab.home"
        case "票夹": id = "dock.tab.wallet"
        case "设置": id = "dock.tab.settings"
        default: id = name
        }
        let segmented = app.segmentedControls["dock.tabs"].buttons[name]
        if segmented.exists { return segmented }
        let byID = app.buttons[id].firstMatch
        if byID.exists { return byID }
        return app.segmentedControls["dock.tabs"].buttons[name]
    }

    func testWalletTopEdgeAfterScrolling() throws {
        let walletTab = dockTab("票夹")
        XCTAssertTrue(walletTab.waitForExistence(timeout: 10))
        walletTab.tap()
        let title = app.navigationBars["票夹"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls["wallet.filter.bar"].waitForExistence(timeout: 5)
                      || app.otherElements["wallet.filter.bar"].exists
                      || app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "全部")).firstMatch.exists,
                      "票夹顶部应显示悬浮四合一筛选条")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.71))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.43))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(title.exists)
        capture("wallet-soft-top")
    }

    /// 三个主页面都能打开，且扫描按钮独立位于底栏胶囊右侧。
    func testEveryMainTabOpens() {
        for tab in ["票夹", "设置", "首页"] {
            let button = dockTab(tab)
            XCTAssertTrue(button.waitForExistence(timeout: 10), "找不到标签：\(tab)")
            button.tap()
            XCTAssertTrue(button.isSelected, "点了「\(tab)」没有切过去")
        }

        let scan = app.buttons["dock.scan"]
        let dockTabs = app.segmentedControls["dock.tabs"].firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 10), "找不到独立扫描按钮")
        XCTAssertTrue(dockTabs.waitForExistence(timeout: 5), "找不到底栏导航胶囊")
        XCTAssertGreaterThan(scan.frame.minX, dockTabs.frame.maxX, "扫描按钮应独立位于底栏胶囊右侧")
        scan.tap()
        let close = app.buttons["关闭"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "点扫描按钮没有弹出扫描抽屉")
        close.tap()
    }

    /// 首页的累计收支来自示例票据：票面 734 元、奖金 1,146 元、结余 412 元
    /// （Scripts/make-demo-data.py 生成时打印的数字）。
    func testHomeShowsDemoTotals() {
        XCTAssertTrue(app.staticTexts["累计收支"].waitForExistence(timeout: 10), "首页没有累计收支")
        for text in ["412", "734", "1,146"] {
            let element = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 10), "首页没有显示 \(text)")
        }
        // 默认一屏内「最新开奖」卡片及其下方免责提示与轮播状态圆点均应完整露在底部悬浮栏之上。
        let disclaimer = app.staticTexts["开奖信息整理自公开信息，仅供核对参考"].firstMatch
        let dockTabs = app.segmentedControls["dock.tabs"].firstMatch
        XCTAssertTrue(disclaimer.waitForExistence(timeout: 10), "首页缺少最新开奖免责提示")
        XCTAssertTrue(dockTabs.waitForExistence(timeout: 5), "首页缺少底栏导航胶囊")
        XCTAssertLessThan(disclaimer.frame.maxY + 10, dockTabs.frame.minY,
                          "默认一屏下最新开奖卡片与轮播状态圆点不应被底栏遮挡")
    }

    /// 票夹里能看到示例票据的彩种。
    func testWalletListsDemoTickets() {
        dockTab("票夹").tap()
        let ticket = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                                          "双色球", "大乐透", "七乐彩", "七星彩")).firstMatch
        XCTAssertTrue(ticket.waitForExistence(timeout: 10), "票夹里没有示例票据")
    }

    /// 首页默认展示放大版玻璃球罐：点命中胶囊弹按彩种/球区细分的液态玻璃分布卡，
    /// 点「摇一摇」吹球，切曲线/方格保留时间范围。
    func testHomeBallJar() {
        let style = app.segmentedControls["home.chart.style"]
        XCTAssertTrue(style.waitForExistence(timeout: 10), "首页没有图表样式切换")
        XCTAssertEqual(style.buttons.count, 3, "图表样式应该是球罐、曲线、方格三种")
        XCTAssertTrue(style.buttons.element(boundBy: 0).isSelected, "首页默认应展示玻璃球罐")

        let shake = app.buttons["home.jar.shake"]
        XCTAssertTrue(shake.waitForExistence(timeout: 10), "球罐视图缺少「摇一摇」")
        let range = app.segmentedControls["home.range"]
        XCTAssertTrue(range.buttons["本年"].isSelected)
        let total = app.buttons["home.jar.total"]
        XCTAssertTrue(total.waitForExistence(timeout: 10), "缺少命中球明细入口胶囊")
        let yearTotal = total.label

        range.buttons["本月"].tap()
        XCTAssertNotEqual(total.label, yearTotal, "球罐应按当前月份统计")
        style.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(range.buttons["本月"].isSelected)
        style.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(range.buttons["本月"].isSelected)
        style.buttons.element(boundBy: 0).tap()
        XCTAssertNotEqual(total.label, yearTotal, "切回球罐应保留本月")
        range.buttons["本年"].tap()
        XCTAssertEqual(total.label, yearTotal)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        capture("home-jar")

        // 点命中胶囊，弹出按彩种与号码区细分的玻璃明细卡片。
        total.tap()
        XCTAssertTrue(app.staticTexts["命中号码分布"].waitForExistence(timeout: 10), "点击命中数没有弹出分布明细卡")
        XCTAssertTrue(app.staticTexts["双色球"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["红球"].waitForExistence(timeout: 5))
        capture("home-jar-breakdown")
        let closeBreakdown = app.buttons["关闭分布"].firstMatch
        XCTAssertTrue(closeBreakdown.waitForExistence(timeout: 5), "找不到分布卡关闭按钮")
        closeBreakdown.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        shake.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        capture("home-jar-shaking")

        let gridButton = style.buttons.element(boundBy: 2)
        gridButton.tap()
        if !gridButton.isSelected {
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            gridButton.tap()
        }
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
        // 点选月份即刻生效并自动收起日历抽屉，不再多点一次「完成」。
        let july = app.buttons["7 月"]
        XCTAssertTrue(july.waitForExistence(timeout: 5))
        july.tap()
        let range = app.segmentedControls["home.range"]
        let style = app.segmentedControls["home.chart.style"]
        XCTAssertTrue(range.buttons["2026-07"].waitForExistence(timeout: 5))
        for index in [1, 2, 0] {
            style.buttons.element(boundBy: index).tap()
            XCTAssertTrue(range.buttons["2026-07"].isSelected)
        }
        // 验证首页内联左右快捷步进：往后一步切到 8 月，再退回 7 月保持深色截图一致。
        let next = app.buttons["home.period.next"]
        let prev = app.buttons["home.period.prev"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(range.buttons["2026-08"].waitForExistence(timeout: 5))
        prev.tap()
        XCTAssertTrue(range.buttons["2026-07"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.jar.total"].waitForExistence(timeout: 10))
        capture("home-dark-july")
    }

    func testBallCountPreviews() {
        app.launchArguments.append("--store-dlt")
        for (hits, shown) in [(309, 309), (2000, 1000)] {
            app.terminate()
            app.launchEnvironment["JAR_PREVIEW_HITS"] = String(hits)
            app.launch()
            let total = app.buttons["home.jar.total"]
            XCTAssertTrue(total.waitForExistence(timeout: 10))
            let shake = app.buttons["home.jar.shake"]
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let digits = total.label.filter(\.isNumber)
            XCTAssertEqual(digits, String(hits))
            if hits > shown {
                total.tap()
                let scaledNote = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "示意 \(shown.formatted()) 颗")).firstMatch
                XCTAssertTrue(scaledNote.waitForExistence(timeout: 5), "分布弹窗应显示示意颗数说明")
                let closeBreakdown = app.buttons["关闭分布"].firstMatch
                XCTAssertTrue(closeBreakdown.waitForExistence(timeout: 5))
                closeBreakdown.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            }
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
