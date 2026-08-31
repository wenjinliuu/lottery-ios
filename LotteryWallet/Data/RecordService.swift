import Foundation
import SwiftData

/// 票据的保存、核对与期次校正。所有操作都在主线程的 ModelContext 上执行。
@MainActor
struct RecordService {
    let context: ModelContext
    let drawStore: DrawStore

    // MARK: - 保存

    /// 一次购买生成一张电子票（同一个 batchId），每注一条记录。
    @discardableResult
    func save(tickets: [Ticket],
              game: GameKey,
              entryKind: EntryKind,
              price: Double,
              multiple: Int,
              target: DrawTarget,
              source: String,
              createdAt: Date = Date()) throws -> String {
        let batchId = "batch_\(Int(createdAt.timeIntervalSince1970))_\(UUID().uuidString.prefix(6))"
        for (index, ticket) in tickets.enumerated() {
            let record = TicketRecord(
                id: "\(batchId)_\(String(format: "%03d", index + 1))",
                batchId: batchId,
                game: game,
                ticket: ticket,
                entryKind: entryKind,
                target: target,
                price: price,
                multiple: multiple,
                source: source,
                createdAt: createdAt
            )
            context.insert(record)
        }
        try context.save()
        return batchId
    }

    func allRecords() -> [TicketRecord] {
        let descriptor = FetchDescriptor<TicketRecord>(sortBy: [SortDescriptor(\TicketRecord.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func delete(batchId: String) throws {
        for record in allRecords() where record.batchId == batchId {
            context.delete(record)
        }
        try context.save()
    }

    func delete(_ record: TicketRecord) throws {
        context.delete(record)
        try context.save()
    }

    func deleteAll() throws {
        try context.delete(model: TicketRecord.self)
        try context.save()
    }

    // MARK: - 核对

    /// 对一注记录求值，不写库。
    func evaluate(_ record: TicketRecord) -> (status: RecordStatus, resultText: String, amount: Double, prizeName: String, matched: [SectionKey: [Bool]], draw: Draw?) {
        guard let draw = drawStore.draw(matching: record) else {
            return (.pending, RecordStatus.pending.label, 0, "", [:], nil)
        }
        let result = PrizeRules.evaluate(gameKey: record.game, ticket: record.ticket, draw: draw, multiple: record.multiple)
        let status: RecordStatus = result.isFloating ? .prizeFloat : (result.amount > 0 ? .won : .lost)
        let text: String
        if result.isFloating {
            text = "\(result.prizeName)，奖金浮动"
        } else if result.amount > 0 {
            text = "中奖 \(MoneyText.format(result.amount))"
        } else {
            text = "未中奖"
        }
        return (status, text, result.amount, result.prizeName, result.matched, draw)
    }

    /// 批量核对，返回本次新确定的中奖注数。已经有最终结论的记录不再重复计算，
    /// 但"奖金浮动"状态会一直复核，直到官方公布单注奖金。
    @discardableResult
    func checkAll() throws -> (checked: Int, won: Int) {
        var checked = 0
        var won = 0
        for record in allRecords() {
            guard record.status == .pending || record.status == .prizeFloat else { continue }
            let outcome = evaluate(record)
            guard outcome.status != record.status || outcome.amount != record.prizeAmount else { continue }
            record.status = outcome.status
            record.resultText = outcome.resultText
            record.prizeAmount = outcome.amount
            if let draw = outcome.draw {
                record.targetExpect = draw.expect.isEmpty ? record.targetExpect : draw.expect
                record.targetOpenDate = draw.openDate.isEmpty ? record.targetOpenDate : draw.openDate
                record.targetSourceDrawId = draw.id
            }
            record.updatedAt = Date()
            checked += 1
            if outcome.status == .won { won += 1 }
        }
        if checked > 0 { try context.save() }
        return (checked, won)
    }

    // MARK: - 期次校正

    struct Reconciliation {
        var confirmed = 0
        var corrected = 0
        var review = 0
        var changed: Bool { confirmed + corrected + review > 0 }
    }

    /// 录入时若下期还是"预计"值，官方日历确认后回填或纠正记录绑定的期号。
    @discardableResult
    func reconcileInferredTargets() throws -> Reconciliation {
        var summary = Reconciliation()
        for record in allRecords() {
            guard !record.status.isFinal, record.targetStatus == .inferred else { continue }
            // 目标期已经有开奖数据了，直接交给核对流程。
            if drawStore.draw(for: record.game, expect: record.targetExpect) != nil { continue }
            guard let official = drawStore.nextDrawMetadata(for: record.game), official.status == .confirmed else { continue }

            // 官方基准期号和录入时不一致，说明推算前提变了，交给用户确认。
            guard !record.targetBasisIssue.isEmpty,
                  !official.basisIssue.isEmpty,
                  record.targetBasisIssue == official.basisIssue else {
                record.targetStatus = .review
                record.targetResolutionReason = "official_basis_issue_changed"
                record.updatedAt = Date()
                summary.review += 1
                continue
            }

            let changed = record.targetExpect != official.expect
                || record.targetOpenDate != official.openDate
                || record.targetOpenTime != official.openTime
            if changed {
                if record.originalTargetExpect.isEmpty { record.originalTargetExpect = record.targetExpect }
                if record.originalTargetOpenDate.isEmpty { record.originalTargetOpenDate = record.targetOpenDate }
                summary.corrected += 1
            } else {
                summary.confirmed += 1
            }
            record.targetExpect = official.expect
            record.targetOpenDate = official.openDate
            record.targetOpenTime = official.openTime
            record.targetBuyEndTime = official.buyEndTime
            record.targetSourceDrawId = official.sourceDrawId
            record.targetStatus = .confirmed
            record.targetSource = official.source
            record.targetBasisIssue = official.basisIssue
            record.targetResolutionReason = official.resolutionReason
            record.updatedAt = Date()
        }
        if summary.changed { try context.save() }
        return summary
    }
}

/// 一张电子票 = 同一次购买的一组记录。
struct TicketBatch: Identifiable, Hashable {
    let id: String
    let records: [TicketRecord]

    var first: TicketRecord? { records.first }
    var game: GameKey { first?.game ?? .ssq }
    var createdAt: Date { first?.createdAt ?? Date() }
    var expect: String { first?.targetExpect ?? "" }
    var openDate: String { first?.targetOpenDate ?? "" }
    var multiple: Int { first?.multiple ?? 1 }
    var entryLabel: String { first?.entryLabel ?? "" }
    var cost: Double { records.reduce(0) { $0 + $1.cost } }
    var prize: Double { records.reduce(0) { $0 + $1.prizeAmount } }
    var netProfit: Double { prize - cost }

    /// 整张票的状态：有中奖即中奖，有浮动即浮动，全部核对完才算未中奖。
    var status: RecordStatus {
        if records.contains(where: { $0.status == .won }) { return .won }
        if records.contains(where: { $0.status == .prizeFloat }) { return .prizeFloat }
        if records.allSatisfy({ $0.status == .lost }) { return .lost }
        return .pending
    }

    static func group(_ records: [TicketRecord]) -> [TicketBatch] {
        let grouped = Dictionary(grouping: records, by: \.batchId)
        return grouped
            .map { TicketBatch(id: $0.key, records: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
