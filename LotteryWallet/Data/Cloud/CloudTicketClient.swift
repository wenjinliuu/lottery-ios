import Foundation

/// 云端的一张票（一注）。`record` 是备份文件里单条记录的 JSON，
/// 和 `BackupService` 导出的格式完全一样 —— 云同步不另造一套字段。
struct CloudTicket: Sendable, Equatable {
    var id: String
    var updatedAt: Date
    var deleted: Bool
    var record: Data
}

struct CloudPage: Sendable {
    var tickets: [CloudTicket]
    var cursor: Int
    var hasMore: Bool
}

struct CloudPushResult: Sendable, Equatable {
    var accepted: Int
    var skipped: Int
}

/// 同步引擎只认这个协议：真机上是 HTTP，测试里是一个内存里的假云端。
protocol CloudTicketTransport: Sendable {
    func pull(since: Int) async throws -> CloudPage
    func push(_ tickets: [CloudTicket]) async throws -> CloudPushResult
    func registerDevice(token: String, sandbox: Bool, bundleID: String) async throws
}

enum CloudSyncError: LocalizedError, Equatable {
    case unauthorized
    case notConfigured
    case server(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .unauthorized: "个人密钥不对"
        case .notConfigured: "云端还没配置个人密钥"
        case .server(let code): "云端返回错误（\(code)）"
        case .malformed: "云端返回的数据看不懂"
        }
    }
}

/// 个人票据接口的 HTTP 客户端。
///
/// 和 `LotteryAPIClient` 分开：那边是公共开奖数据（只读、有 GitHub 兜底、
/// 密钥编在包里），这边是自己的票（读写、没有兜底、密钥只在钥匙串里）。
/// 两把密钥、两套失败语义，混在一个类里迟早会把个人密钥发到不该去的地方。
struct CloudTicketClient: CloudTicketTransport {
    static let baseURL = URL(string: "https://wenjin-cloudbase-d1empq882391ac1-1311287495.ap-shanghai.app.tcloudbase.com/lottery")!
    static let keyHeader = "X-Lottery-User-Key"
    /// 服务端一次最多收 200 条。
    static let batchLimit = 200

    let userKey: String
    var session: URLSession = .shared

    func pull(since: Int) async throws -> CloudPage {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("v2/me/tickets"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: String(since))]
        let data = try await send(request(components.url!, method: "GET", body: nil))
        return try Self.decodePage(data)
    }

    func push(_ tickets: [CloudTicket]) async throws -> CloudPushResult {
        let url = Self.baseURL.appendingPathComponent("v2/me/tickets")
        let data = try await send(request(url, method: "POST", body: Self.encodePush(tickets)))
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accepted = root["accepted"] as? Int,
              let skipped = root["skipped"] as? Int else { throw CloudSyncError.malformed }
        return CloudPushResult(accepted: accepted, skipped: skipped)
    }

    func registerDevice(token: String, sandbox: Bool, bundleID: String) async throws {
        let url = Self.baseURL.appendingPathComponent("v2/me/devices")
        let body = try JSONSerialization.data(withJSONObject: [
            "token": token,
            "environment": sandbox ? "sandbox" : "production",
            "bundle_id": bundleID
        ])
        _ = try await send(request(url, method: "POST", body: body))
    }

    // MARK: - 编解码（纯函数，单测直接测）

    static func encodePush(_ tickets: [CloudTicket]) throws -> Data {
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = tickets.map { ticket in
            let record = (try? JSONSerialization.jsonObject(with: ticket.record)) ?? [String: Any]()
            return [
                "id": ticket.id,
                "updated_at": iso.string(from: ticket.updatedAt),
                "deleted": ticket.deleted,
                "record": record
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["tickets": rows])
    }

    static func decodePage(_ data: Data) throws -> CloudPage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["tickets"] as? [[String: Any]],
              let cursor = root["cursor"] as? Int else { throw CloudSyncError.malformed }
        let tickets: [CloudTicket] = rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let stamp = row["updated_at"] as? String,
                  let updatedAt = DateText.parse(stamp),
                  let record = row["record"] as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: record) else { return nil }
            return CloudTicket(id: id,
                               updatedAt: updatedAt,
                               deleted: row["deleted"] as? Bool ?? false,
                               record: encoded)
        }
        return CloudPage(tickets: tickets, cursor: cursor, hasMore: root["has_more"] as? Bool ?? false)
    }

    // MARK: - 请求

    private func request(_ url: URL, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(userKey, forHTTPHeaderField: Self.keyHeader)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudSyncError.malformed }
        switch http.statusCode {
        case 200: return data
        case 401: throw CloudSyncError.unauthorized
        case 503: throw CloudSyncError.notConfigured
        default: throw CloudSyncError.server(http.statusCode)
        }
    }
}
