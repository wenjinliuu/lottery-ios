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
///
/// 设计要点：凡是渲染或统计要反复读的值，一律**落库存好**，
/// 不在视图里现算。早期版本把号码存成 JSON、把统计日期临时解析，
/// 导致列表每帧都要做成千上万次 JSONDecoder 和 DateFormatter 调用，
/// 记录一多就直接卡死主线程。
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
    /// "confirmed" / "inferred" / "review"。
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
    /// 中奖等级名，核对时写入，列表直接读，不再重算。
    var prizeName: String
    /// 逐球命中标记的编码，核对时写入，票面展开直接读。
    var matchedData: Data
    var source: String
    var createdAt: Date
    var updatedAt: Date

    /// 计入盈亏的日期（yyyy-MM-dd），写入时算好。
    /// 统计要按天分组，如果每次都去解析日期字符串，几百条记录就能拖垮一帧。
    var profitDay: String

    // MARK: - 解码缓存（不落库）

    @Transient private var ticketCache: Ticket?
    @Transient private var matchedCache: [SectionKey: [Bool]]?

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
        self.prizeName = ""
        self.matchedData = Data()
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.profitDay = TicketRecord.profitDay(openDate: target.openDate,
                                                openTime: target.openTime,
                                                createdAt: createdAt)
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

    /// 号码。首次访问解码一次，之后走内存缓存。
    var ticket: Ticket {
        get {
            if let ticketCache { return ticketCache }
            let decoded = (try? JSONDecoder().decode(Ticket.self, from: numbersData)) ?? Ticket()
            ticketCache = decoded
            return decoded
        }
        set {
            ticketCache = newValue
            numbersData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    /// 逐球命中标记。没核对过就是空字典。
    var matched: [SectionKey: [Bool]] {
        get {
            if let matchedCache { return matchedCache }
            guard !matchedData.isEmpty,
                  let decoded = try? JSONDecoder().decode([SectionKey: [Bool]].self, from: matchedData) else {
                matchedCache = [:]
                return [:]
            }
            matchedCache = decoded
            return decoded
        }
        set {
            matchedCache = newValue
            matchedData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    /// 这一注的投入金额。
    var cost: Double { price * Double(multiple) }

    /// 净盈亏，未开奖按 0 计。
    var netProfit: Double { prizeAmount - cost }

    /// 绑定期次变化后同步重算统计日期。
    func refreshProfitDay() {
        profitDay = TicketRecord.profitDay(openDate: targetOpenDate,
                                           openTime: targetOpenTime,
                                           createdAt: createdAt)
    }

    /// 计入盈亏的日期：优先绑定的开奖日，其次开奖时刻，最后记录创建日。
    static func profitDay(openDate: String, openTime: String, createdAt: Date) -> String {
        for candidate in [openDate, openTime] where !candidate.isEmpty {
            if let date = DateText.parse(candidate) { return DateText.day(date) }
        }
        return DateText.day(createdAt)
    }
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
