import XCTest

/// 无障碍审计：在每个主页面跑一遍系统的 `performAccessibilityAudit()`。
/// 类名带 Accessibility，中央 CI 会把这里的失败单独列为「无障碍问题」，目前只警告不阻断；
/// 问题清干净后把 .ios-ci.yml 的 build_test.accessibility_audit 改成 fail。
/// 每个页面单独一个测试：一个页面审计超时或出错，不影响其他页面的结果。
final class AccessibilityAuditTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()
    }

    func testAccessibilityAuditHome() throws { try audit(tab: "首页") }
    func testAccessibilityAuditWallet() throws { try audit(tab: "票夹") }
    func testAccessibilityAuditSettings() throws { try audit(tab: "设置") }

    private func audit(tab: String) throws {
        let button = app.tabBars.buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "找不到标签：\(tab)")
        button.tap()
        try app.performAccessibilityAudit()
    }
}
