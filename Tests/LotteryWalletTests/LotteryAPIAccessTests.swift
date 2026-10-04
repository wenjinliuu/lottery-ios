import XCTest
@testable import LotteryWallet

@MainActor
final class LotteryAPIAccessTests: XCTestCase {
    private let key = "unit-test-only-read-key-not-for-production"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    func testCloudBaseReceivesReadKey() async throws {
        StubURLProtocol.stub("v2/bootstrap", body: LotteryV2Fixtures.bootstrap)
        let client = LotteryAPIClient(session: StubURLProtocol.makeSession(), apiKey: key)
        let response = try await client.fetch(.bootstrap)
        XCTAssertEqual(response.source, .cloudBase)
        XCTAssertEqual(StubURLProtocol.recordedRequests.first?.value(forHTTPHeaderField: "X-Lottery-Api-Key"), key)
    }

    func testRejectionAndRateLimitFallBackWithoutLeakingKey() async throws {
        for status in [401, 429] {
            StubURLProtocol.reset()
            StubURLProtocol.stub("v2/bootstrap", status: status, body: Data())
            StubURLProtocol.stub("v2/bootstrap.json", body: LotteryV2Fixtures.bootstrap)
            let client = LotteryAPIClient(session: StubURLProtocol.makeSession(), apiKey: key)
            let response = try await client.fetch(.bootstrap)
            XCTAssertEqual(response.source, .githubFallback)
            let requests = StubURLProtocol.recordedRequests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Lottery-Api-Key"), key)
            XCTAssertNil(requests[1].value(forHTTPHeaderField: "X-Lottery-Api-Key"))
            XCTAssertEqual(requests[1].url?.path, "/wenjinliuu/lottery-data-repo/main/public_data/v2/bootstrap.json")
        }
    }

    func testDirectFallbackHasNoReadKey() async throws {
        StubURLProtocol.stub("v2/bootstrap.json", body: LotteryV2Fixtures.bootstrap)
        let client = LotteryAPIClient(session: StubURLProtocol.makeSession(), apiKey: key)
        _ = try await client.fetchFallback(.bootstrap)
        XCTAssertNil(StubURLProtocol.recordedRequests.first?.value(forHTTPHeaderField: "X-Lottery-Api-Key"))
    }

    func testStatusCarriesReadKey() async throws {
        StubURLProtocol.stub("v2/status", body: LotteryV2Fixtures.status)
        let client = LotteryAPIClient(session: StubURLProtocol.makeSession(), apiKey: key)
        _ = try await client.fetchStatus()
        XCTAssertEqual(StubURLProtocol.recordedRequests.first?.value(forHTTPHeaderField: "X-Lottery-Api-Key"), key)
    }

    func testCrossOriginRedirectStripsReadKey() {
        let origin = URL(string: "https://cloud.example/lottery/v2/bootstrap")!
        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var redirected = URLRequest(url: URL(string: "https://other.example/data")!)
        redirected.setValue(key, forHTTPHeaderField: "X-Lottery-Api-Key")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        LotteryReadRedirectGuard().urlSession(session, task: session.dataTask(with: origin),
                                             willPerformHTTPRedirection: response, newRequest: redirected) { request in
            XCTAssertNil(request?.value(forHTTPHeaderField: "X-Lottery-Api-Key"))
        }
    }
}
