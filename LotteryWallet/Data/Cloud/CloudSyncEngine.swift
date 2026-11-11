import Foundation
import SwiftData

/// 一次同步：先拉、后推。
///
/// **同一张票以修改时间为准，新的赢。** 两头都只有我一个人在用，
/// 不需要比这更聪明的合并；要的是「重复跑多少遍结果都一样」——
/// 网络断在半路、退后台被系统掐掉，下次接着跑不能出重复票、也不能丢票。
///
/// 云端算的核对结果（`settlement`）这里不用：App 拿到开奖号会自己核对，
/// 两边各算各的，谁也不覆盖谁。
@MainActor
struct CloudSyncEngine {
    let context: ModelContext
    var state = CloudSyncState()

    struct Summary: Equatable {
        var pulled = 0
        var removed = 0
        var pushed = 0
        var deletionsSent = 0
    }

    func run(_ transport: CloudTicketTransport, now: Date = Date()) async throws -> Summary {
        var summary = Summary()
        try await pull(transport, into: &summary)
        try await push(transport, startedAt: now, into: &summary)
        state.lastSyncedAt = now
        return summary
    }

    // MARK: - 拉

    private func pull(_ transport: CloudTicketTransport, into summary: inout Summary) async throws {
        // 防呆：服务端出错一直说「还有」时不能在这里转一辈子。
        for _ in 0..<200 {
            let page = try await transport.pull(since: state.cursor)
            try apply(page.tickets, into: &summary)
            // 这一页落库成功才前移游标 —— 中途失败，下次从同一页重来。
            state.cursor = page.cursor
            guard page.hasMore, !page.tickets.isEmpty else { return }
        }
    }

    private func apply(_ tickets: [CloudTicket], into summary: inout Summary) throws {
        guard !tickets.isEmpty else { return }
        let local = (try? context.fetch(FetchDescriptor<TicketRecord>())) ?? []
        let byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pendingDeletes = Dictionary(state.tombstones.map { ($0.id, $0.deletedAt) },
                                        uniquingKeysWith: { first, _ in first })

        var rows: [Any] = []
        for ticket in tickets {
            if ticket.deleted {
                // 云端说删了：本机这一注要是在那之后又改过，就留着（它会在推的时候覆盖回去）。
                if let record = byID[ticket.id], record.updatedAt <= ticket.updatedAt {
                    context.delete(record)
                    summary.removed += 1
                }
                continue
            }
            // 本机刚删、还没来得及告诉云端的票，不能被这次拉取复活。
            if let deletedAt = pendingDeletes[ticket.id], deletedAt >= ticket.updatedAt { continue }
            if let record = byID[ticket.id], record.updatedAt >= ticket.updatedAt { continue }
            if let row = try? JSONSerialization.jsonObject(with: ticket.record) {
                rows.append(row)
            }
        }
        if !rows.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: ["records": rows])
            let result = try BackupService(context: context).importData(data)
            summary.pulled += result.inserted + result.updated
        }
        try context.save()
    }

    // MARK: - 推

    private func push(_ transport: CloudTicketTransport, startedAt: Date, into summary: inout Summary) async throws {
        let since = state.lastPushedAt
        let local = (try? context.fetch(FetchDescriptor<TicketRecord>())) ?? []
        let changed = local.filter { $0.updatedAt > since }
        let tombstones = state.tombstones

        var outgoing: [CloudTicket] = changed.compactMap { record in
            guard let data = try? JSONSerialization.data(withJSONObject: BackupService.dictionary(from: record)) else {
                return nil
            }
            return CloudTicket(id: record.id, updatedAt: record.updatedAt, deleted: false, record: data)
        }
        // 删除也是一条记录：只带彩种（服务端要它来校验），号码不用带。
        outgoing += tombstones.compactMap { stone in
            guard let data = try? JSONSerialization.data(withJSONObject: ["id": stone.id, "gameKey": stone.game]) else {
                return nil
            }
            return CloudTicket(id: stone.id, updatedAt: stone.deletedAt, deleted: true, record: data)
        }
        guard !outgoing.isEmpty else {
            state.lastPushedAt = startedAt
            return
        }

        var index = 0
        while index < outgoing.count {
            let batch = Array(outgoing[index..<min(index + CloudTicketClient.batchLimit, outgoing.count)])
            _ = try await transport.push(batch)
            index += batch.count
        }
        // 全部批次都成功才前移。失败就整段重传 —— 服务端按修改时间去重，重传是安全的。
        state.lastPushedAt = startedAt
        state.forgetDeletion(ids: tombstones.map(\.id))
        summary.pushed = changed.count
        summary.deletionsSent = tombstones.count
    }
}
