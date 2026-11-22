import XCTest

final class TopEdgeComparison: XCTestCase {
    func testWalletScrollEdge() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-lottery.appearance", "light"]
        app.launch()
        app.tabBars.buttons["票夹"].tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.71))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.43))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        let image = XCUIScreen.main.screenshot()
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("edge.png")
        try image.pngRepresentation.write(to: file)
    }
}
