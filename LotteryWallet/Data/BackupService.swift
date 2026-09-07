import Foundation
import SwiftData

/// 备份导出 / 导入。
///
/// 文件格式与 web 版 `lottery-backup-*.json` 保持字段一致，两端可以互导。
/// 唯一的差别：web 版的 `checksum` 依赖 JSON.stringify 的逐字节结果，
/// Swift 无法复现，所以 iOS 导出不写 checksum（web 端只在存在时才校验），
/// iOS 导入也不校验 checksum，只做结构与数值校验。
@MainActor
struct BackupService {
    let context: ModelContext

    static let formatVersion = 2

    // MARK: - 导出

    func exportData(records: [TicketRecord]) throws -> Data {
        let payload: [String: Any] = [
            "version": Self.formatVersion,
            "appVersion": AppInfo.version,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "recordCount": records.count,
            "platform": "ios",
            "records": records.map(Self.dictionary(from:))
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    static func suggestedFileName(now: Date = Date()) -> String {
        "lottery-backup-\(DateText.day(now)).json"
    }

    /// 转成与 web 版同构的记录字典。
    private static func dictionary(from record: TicketRecord) -> [String: Any] {
        let ticket = record.ticket
        var numbers: [String: Any] = [:]
        for (key, values) in ticket.numbers.values {
            // 单值区回写成裸数字，和 web 版一致
            if key == .tail || key == .special, let single = values.first {
                numbers[key.rawValue] = single
            } else {
                numbers[key.rawValue] = values
            }
        }
        if !ticket.playMode.isEmpty { numbers["playMode"] = ticket.playMode }
        if let playCount = ticket.playCount { numbers["playCount"] = playCount }
        if ticket.addOn { numbers["addOn"] = true }

        let iso = ISO8601DateFormatter()
        return [
            "id": record.id,
            "batchId": record.batchId,
            "gameKey": record.gameRaw,
            "gameName": record.gameName,
            "playMode": record.playMode,
            "expect": record.targetExpect,
            "openDate": record.targetOpenDate,
            "targetExpect": record.targetExpect,
            "targetOpenDate": record.targetOpenDate,
            "targetOpenTime": record.targetOpenTime,
            "targetBuyEndTime": record.targetBuyEndTime,
            "targetSourceDrawId": record.targetSourceDrawId,
            "targetStatus": record.targetStatusRaw,
            "targetSource": record.targetSource,
            "targetConfirmed": record.targetStatus == .confirmed,
            "targetBasisIssue": record.targetBasisIssue,
            "targetResolutionReason": record.targetResolutionReason,
            "originalTargetExpect": record.originalTargetExpect,
            "originalTargetOpenDate": record.originalTargetOpenDate,
            "numbers": numbers,
            "entryKind": record.entryKindRaw,
            "entryLabel": record.entryLabel,
            "price": record.price,
            "multiple": record.multiple,
            "status": record.statusRaw,
            // 命中标记要一起带走。它虽然是核对算出来的派生数据，但要重算就得
            // 拿到那一期的开奖号 —— 而备份可能是几个月后、在另一台机器上恢复的，
            // 那时候旧期次的开奖数据未必还取得到。少了它，整票的号码球就没有
            // 命中效果，看起来像从来没核对过。
            "matched": record.matched.reduce(into: [String: [Bool]]()) { $0[$1.key.rawValue] = $1.value },
            "resultText": record.resultText,
            "prizeAmount": record.prizeAmount,
            "prizeName": record.prizeName,
            "source": record.source,
            "createdAt": iso.string(from: record.createdAt),
            "updatedAt": iso.string(from: record.updatedAt)
        ]
    }

    // MARK: - 导入

    enum ImportError: LocalizedError {
        case malformed
        case empty

        var errorDescription: String? {
            switch self {
            case .malformed: return "备份文件格式不正确"
            case .empty: return "备份文件里没有彩票记录"
            }
        }
    }

    /// 按 id 覆盖同名记录，其余追加。返回新增与覆盖的条数。
    ///
    /// 已有记录由这里自己查，不再让调用方把 `@Query` 的结果传进来 ——
    /// 视图里的查询结果可能滞后，拿它去判重会插入重复 id 而在保存时抛错。
    @discardableResult
    func importData(_ data: Data) throws -> (inserted: Int, updated: Int) {
        let existing = (try? context.fetch(FetchDescriptor<TicketRecord>())) ?? []
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["records"] as? [[String: Any]] else {
            throw ImportError.malformed
        }
        guard !rows.isEmpty else { throw ImportError.empty }

        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var inserted = 0
        var updated = 0

        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty,
                  let gameRaw = row["gameKey"] as? String,
                  let game = GameKey(rawValue: gameRaw) else { continue }

            let ticket = Self.ticket(from: row["numbers"] as? [String: Any] ?? [:],
                                     fallbackPlayMode: row["playMode"] as? String ?? "",
                                     entryLabel: row["entryLabel"] as? String ?? "")
            let target = DrawTarget(
                expect: string(row["targetExpect"]) ?? string(row["expect"]) ?? "",
                openDate: string(row["targetOpenDate"]) ?? string(row["openDate"]) ?? "",
                openTime: string(row["targetOpenTime"]) ?? "",
                buyEndTime: string(row["targetBuyEndTime"]) ?? "",
                sourceDrawId: string(row["targetSourceDrawId"]) ?? "",
                status: NextDrawStatus(rawValue: string(row["targetStatus"]) ?? "") ?? .confirmed,
                source: string(row["targetSource"]) ?? "",
                basisIssue: string(row["targetBasisIssue"]) ?? "",
                resolutionReason: string(row["targetResolutionReason"]) ?? ""
            )
            let createdAt = DateText.parse(string(row["createdAt"]) ?? "") ?? Date()

            let record = byID[id] ?? TicketRecord(
                id: id,
                batchId: string(row["batchId"]) ?? id,
                game: game,
                ticket: ticket,
                entryKind: EntryKind(rawValue: string(row["entryKind"]) ?? "") ?? .manual,
                target: target,
                price: number(row["price"]) ?? game.unitPrice,
                multiple: Int(number(row["multiple"]) ?? 1),
                source: string(row["source"]) ?? "backup",
                createdAt: createdAt
            )
            if byID[id] == nil {
                context.insert(record)
                byID[id] = record
                inserted += 1
            } else {
                updated += 1
            }

            // 覆盖导入时也把结果字段带上，避免重新核对前显示成待核对。
            record.ticket = ticket
            record.game = game
            record.playMode = string(row["playMode"]) ?? ticket.playMode
            record.entryLabel = string(row["entryLabel"]) ?? record.entryLabel
            record.price = number(row["price"]) ?? record.price
            record.multiple = Int(number(row["multiple"]) ?? Double(record.multiple))
            record.statusRaw = string(row["status"]) ?? RecordStatus.pending.rawValue
            record.resultText = string(row["resultText"]) ?? RecordStatus.pending.label
            record.prizeAmount = number(row["prizeAmount"]) ?? 0
            record.originalTargetExpect = string(row["originalTargetExpect"]) ?? ""
            record.originalTargetOpenDate = string(row["originalTargetOpenDate"]) ?? ""
            record.targetExpect = target.expect
            record.targetOpenDate = target.openDate
            record.targetOpenTime = target.openTime
            record.targetBuyEndTime = target.buyEndTime
            record.targetSourceDrawId = target.sourceDrawId
            record.targetStatusRaw = target.status.rawValue
            record.targetSource = target.source
            record.targetBasisIssue = target.basisIssue
            record.targetResolutionReason = target.resolutionReason
            record.prizeName = string(row["prizeName"]) ?? ""
            // 命中标记优先从备份带回来。带不回来（老版本备份里没有这个字段）
            // 也不要紧，启动时的核对流程会按开奖号补一次 —— 但那一步需要能
            // 取到对应期次的开奖数据，所以能带就带。
            record.matched = matchedFlags(row["matched"])
            record.refreshProfitDay()
            record.updatedAt = DateText.parse(string(row["updatedAt"]) ?? "") ?? Date()
        }

        try context.save()
        return (inserted, updated)
    }

    /// 备份里的命中标记：`{"red": [true, false, ...], "blue": [true]}`。
    private static func matchedFlags(_ value: Any?) -> [SectionKey: [Bool]] {
        guard let raw = value as? [String: Any] else { return [:] }
        var result: [SectionKey: [Bool]] = [:]
        for (key, flags) in raw {
            guard let section = SectionKey(rawValue: key) else { continue }
            if let list = flags as? [Bool] {
                result[section] = list
            } else if let numbers = flags as? [NSNumber] {
                result[section] = numbers.map { $0.boolValue }
            }
        }
        return result
    }

    private static func ticket(from numbers: [String: Any], fallbackPlayMode: String, entryLabel: String) -> Ticket {
        var set = NumberSet()
        for (key, value) in numbers {
            guard let section = SectionKey(rawValue: key) else { continue }
            if let list = value as? [Int] {
                set[section] = list
            } else if let list = value as? [NSNumber] {
                set[section] = list.map(\.intValue)
            } else if let single = value as? NSNumber {
                set[section] = [single.intValue]
            }
        }
        var ticket = Ticket(numbers: set,
                            playMode: numbers["playMode"] as? String ?? fallbackPlayMode,
                            entryLabel: entryLabel)
        ticket.playCount = (numbers["playCount"] as? NSNumber)?.intValue
        ticket.addOn = (numbers["addOn"] as? NSNumber)?.boolValue ?? (ticket.playMode == "add")
        return ticket
    }

    private func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
