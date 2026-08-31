import Foundation
import SwiftData

/// 票据核对状态。
enum RecordStatus: String, Codable, Sendable, CaseIterable {
    /// 还没开奖或还没核对。
    case pending
    /// 已中奖且奖金已确定。
    case won
    /// 未中奖。
    case lost
    /// 中奖了，但官方还没公布单注奖金。
    case prizeFloat = "prize_float"

    /// 已经有最终结论、不需要重复核对的状态。
    var isFinal: Bool { self != .pending }

    var label: String {
        switch self {
        case .pending: "待核对"
        case .won: "已中奖"
        case .lost: "未中奖"
        case .prizeFloat: "奖金待公布"
        }
    }
}

/// 录入方式。
enum EntryKind: String, Codable, Sendable {
    case random     // 机选
    case manual     // 手动单式
    case system     // 复式
    case dantuo     // 胆拖
    case scan       // 扫描导入

    var label: String {
        switch self {
        case .random: "随机"
        case .manual: "普通"
        case .system: "复式"
        case .dantuo: "胆拖"
        case .scan: "扫描"
        }
    }
}

/// 一注彩票记录。一次购买生成一个 `batchId`，一张电子票即一个 batch。
@Model
final class TicketRecord {
    @Attribute(.unique) var id: String
    var batchId: String
    var gameRaw: String
    var gameName: String
    var playMode: String
    /// 号码 JSON，与 web 版 `record.numbers` 同构，备份可以互导。
    var numbersData: Data
    var entryKindRaw: String
    var entryLabel: String

    /// 绑定的开奖期次。
    var targetExpect: String
    var targetOpenDate: String
    var targetOpenTime: String
    var targetBuyEndTime: String
    var targetSourceDrawId: String
    /// "confirmed" / "inferred"。
    var targetStatusRaw: String
    var targetSource: String
    var targetBasisIssue: String
    var targetResolutionReason: String
    /// 推算期次被官方数据纠正时，保留原始推算值用于提示。
    var originalTargetExpect: String
    var originalTargetOpenDate: String

    var price: Double
    var multiple: Int
    var statusRaw: String
    var resultText: String
    var prizeAmount: Double
    var source: String
    var createdAt: Date
    var updatedAt: Date

    init(id: String,
         batchId: String,
         game: GameKey,
         ticket: Ticket,
         entryKind: EntryKind,
         target: DrawTarget,
         price: Double,
         multiple: Int,
         source: String,
         createdAt: Date = Date()) {
        self.id = id
        self.batchId = batchId
        self.gameRaw = game.rawValue
        self.gameName = game.label
        self.playMode = ticket.playMode
        self.numbersData = (try? JSONEncoder().encode(ticket)) ?? Data()
        self.entryKindRaw = entryKind.rawValue
        self.entryLabel = ticket.entryLabel.isEmpty ? entryKind.label : ticket.entryLabel
        self.targetExpect = target.expect
        self.targetOpenDate = target.openDate
        self.targetOpenTime = target.openTime
        self.targetBuyEndTime = target.buyEndTime
        self.targetSourceDrawId = target.sourceDrawId
        self.targetStatusRaw = target.status.rawValue
        self.targetSource = target.source
        self.targetBasisIssue = target.basisIssue
        self.targetResolutionReason = target.resolutionReason
        self.originalTargetExpect = target.status == .inferred ? target.expect : ""
        self.originalTargetOpenDate = target.status == .inferred ? target.openDate : ""
        self.price = price
        self.multiple = multiple
        self.statusRaw = RecordStatus.pending.rawValue
        self.resultText = RecordStatus.pending.label
        self.prizeAmount = 0
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    // MARK: - 派生属性

    var game: GameKey {
        get { GameKey(rawValue: gameRaw) ?? .ssq }
        set { gameRaw = newValue.rawValue; gameName = newValue.label }
    }

    var status: RecordStatus {
        get { RecordStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var entryKind: EntryKind {
        get { EntryKind(rawValue: entryKindRaw) ?? .manual }
        set { entryKindRaw = newValue.rawValue }
    }

    var targetStatus: NextDrawStatus {
        get { NextDrawStatus(rawValue: targetStatusRaw) ?? .confirmed }
        set { targetStatusRaw = newValue.rawValue }
    }

    var ticket: Ticket {
        get { (try? JSONDecoder().decode(Ticket.self, from: numbersData)) ?? Ticket() }
        set { numbersData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// 这一注的投入金额。
    var cost: Double { price * Double(multiple) }

    /// 净盈亏，未开奖按 0 计。
    var netProfit: Double { prizeAmount - cost }

    /// 是否还需要核对。
    var needsEvaluation: Bool { !status.isFinal || status == .prizeFloat }
}

/// 录入时绑定的开奖期次。
struct DrawTarget: Hashable, Sendable {
    var expect: String = ""
    var openDate: String = ""
    var openTime: String = ""
    var buyEndTime: String = ""
    var sourceDrawId: String = ""
    var status: NextDrawStatus = .confirmed
    var source: String = ""
    var basisIssue: String = ""
    var resolutionReason: String = ""
    /// 数据不足时不允许保存，`message` 说明原因。
    var isAvailable: Bool = true
    var message: String = ""

    static func unavailable(_ message: String) -> DrawTarget {
        DrawTarget(isAvailable: false, message: message)
    }
}
