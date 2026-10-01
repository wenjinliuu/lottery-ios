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

    /// 首页右上角进统计页。
    func testStatsOpensFromHome() {
        let stats = app.navigationBars.buttons["统计"]
        XCTAssertTrue(stats.waitForExistence(timeout: 10), "首页没有统计入口")
        stats.tap()
        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 10), "统计页没有打开")
    }
}
