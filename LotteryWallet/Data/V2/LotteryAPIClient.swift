import Foundation

/// 公共开奖数据的只读网络客户端。
///
/// ## 两个地址，一套代码
///
/// CloudBase 是当前数据真相，GitHub 上的 `public_data/v2` 是延迟灾备源。
/// 两边的 JSON **结构完全一样**（仓库里的静态文件就是照着 API 生成的），
/// 所以这里只在「取字节」这一层分叉，DTO、解码、转换三层一个字都不分。
///
/// ## 不需要、也不允许有任何密钥
///
/// 用到的全是公开 GET 接口。抓取用的 `CLOUDBASE_API_KEY`、`JISU_APPKEY`
/// 这些只属于服务端和 GitHub Actions，**一个字节都不该进到安装包里**。
/// 这里没有任何 Authorization 头，也没有任何从配置读密钥的入口。
actor LotteryAPIClient {
    static let shared = LotteryAPIClient()

    /// CloudBase：当前数据真相。
    private let cloudBase = URL(string: "https://wenjin-cloudbase-d1empq882391ac1-1311287495.ap-shanghai.app.tcloudbase.com/lottery")!
    /// GitHub：延迟灾备。CloudBase 不可用时才走这里。
    private let github = URL(string: "https://raw.githubusercontent.com/wenjinliuu/lottery-data-repo/main/public_data/v2")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    struct Response: Sendable {
        let data: Data
        let source: LotteryDataSource
    }

    /// 取一个端点的原始字节：先 CloudBase，失败再 GitHub。
    ///
    /// **只在两个在线源之间降级，不碰缓存。** 缓存那一层归
    /// `LotteryRepository` 管 —— 两件事混在一个函数里，就没法单独测
    /// 「CloudBase 成功时到底有没有多打一次 GitHub」。
    func fetch(_ endpoint: LotteryEndpoint) async throws -> Response {
        do {
            let data = try await get(cloudBase.appendingPathComponent(endpoint.cloudBasePath))
            return Response(data: data, source: .cloudBase)
        } catch {
            let data = try await get(github.appendingPathComponent(endpoint.githubPath))
            #if DEBUG
            print("[lottery] CloudBase 不可用，已回落 GitHub：\(endpoint.cacheKey) —— \(error.localizedDescription)")
            #endif
            return Response(data: data, source: .githubFallback)
        }
    }

    /// 数据源体检。**只打 CloudBase，不走 GitHub 兜底，也不进缓存。**
    ///
    /// 三个「不」都是有意的：
    /// - 它问的就是 CloudBase 自己的状态，回落到别处问等于换了个人回答；
    /// - GitHub 的 V2 镜像里根本没有这个文件（404）；
    /// - 缓存一份体检报告毫无意义 —— 要的就是「此刻」。
    ///
    /// 它也**不是任何端点**（`LotteryEndpoint` 里没有 health 这一项），
    /// 这样它在结构上就不可能被误接进冷启动。
    func fetchHealth() async throws -> LotteryV2.Health {
        let data = try await get(cloudBase.appendingPathComponent("v2/health"), timeout: 10)
        do {
            return try JSONDecoder().decode(LotteryV2.Health.self, from: data)
        } catch {
            throw LotteryDataError.decoding(String(describing: error))
        }
    }

    private func get(_ url: URL, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url)
        // 这一层自己管缓存（见 `LotteryCache`），不要让 URLSession 再存一份：
        // 两套缓存各有各的过期判断，出问题时根本说不清界面上那份是谁给的。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LotteryDataError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LotteryDataError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw LotteryDataError.empty }
        return data
    }
}

/// 读取开奖数据时可能出的错。
///
/// 分这么细不是为了给用户看 —— 用户看到的永远是一句人话。
/// 是为了排查时能分清「网络没连上」「服务端 500」「JSON 变了」这三件
/// 修法完全不同的事。上一版全都塞进一个 `badStatus`，一旦服务端改了字段名，
/// 现场看到的只有「读取失败」。
enum LotteryDataError: LocalizedError {
    case notHTTP
    case badStatus(Int)
    case empty
    case decoding(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .notHTTP:
            "开奖数据读取失败"
        case .badStatus(let code):
            "开奖数据读取失败（HTTP \(code)）"
        case .empty:
            "开奖数据是空的"
        case .decoding:
            "开奖数据格式不对"
        case .noData:
            "还没有可显示的开奖数据"
        }
    }

    /// 给日志用的详细原因，不进界面。
    var diagnostic: String {
        switch self {
        case .decoding(let detail): "解码失败：\(detail)"
        default: errorDescription ?? "未知错误"
        }
    }
}
