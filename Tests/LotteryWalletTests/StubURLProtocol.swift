import Foundation

/// 把网络层换成可控的桩，并**记下每一个真的发出去的请求**。
///
/// 渐进式加载这件事，光看代码是看不出来的 —— 「冷启动只发一个请求」
/// 只有数请求才能证明。所以这里记的是 URL 列表，断言直接拿它比对。
final class StubURLProtocol: URLProtocol {

    /// 按路径后缀匹配的桩响应。
    struct Stub {
        var status: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [(suffix: String, stub: Stub)] = []
    nonisolated(unsafe) private static var recorded: [String] = []

    /// 每个用例开头调一次。
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs = []
        recorded = []
    }

    /// 路径以 `suffix` 结尾的请求返回这份数据。**先注册的先匹配。**
    static func stub(_ suffix: String, status: Int = 200, body: Data) {
        lock.lock(); defer { lock.unlock() }
        stubs.append((suffix, Stub(status: status, body: body)))
    }

    /// 真的发出去过的请求路径，按顺序。
    static var requestedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// 有几个请求打到了某个路径后缀上。
    static func count(_ suffix: String) -> Int {
        requestedPaths.filter { $0.hasSuffix(suffix) }.count
    }

    /// 便捷断言用：发出去的请求总数。
    static var requestCount: Int { requestedPaths.count }

    /// 这次跑的是不是只碰了 CloudBase（用主机名区分两个在线源）。
    static func hosts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded.compactMap { URL(string: $0)?.host }
    }

    /// 配好桩的 session。用 ephemeral，免得系统那层缓存插一脚。
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.recorded.append(url.absoluteString)
        let match = Self.stubs.first { url.path.hasSuffix($0.suffix) }?.stub
        Self.lock.unlock()

        guard let match else {
            // 没配桩 = 这个请求本来就不该发。让它失败，用例里数请求时一眼看得见。
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url,
                                       statusCode: match.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
