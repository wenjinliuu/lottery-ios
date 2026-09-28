import XCTest
@testable import LotteryWallet

/// App 备案号：关于页最底下那一行，点了跳工信部备案查询。
@MainActor
final class ICPFilingTests: XCTestCase {

    func testFilingNumberIsTheIssuedAppFiling() {
        XCTAssertEqual(AboutView.icpFiling, "沪ICP备2026015335号-2A")
        // App 备案号以 A 结尾，和网站备案号区分开
        XCTAssertTrue(AboutView.icpFiling.hasSuffix("A"))
    }

    func testLookupOpensMIITOverHTTPS() {
        XCTAssertEqual(AboutView.icpLookupURL.scheme, "https")
        XCTAssertEqual(AboutView.icpLookupURL.host, "beian.miit.gov.cn")
    }
}
