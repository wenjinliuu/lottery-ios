import Foundation

/// 一条奖级明细。
struct PrizeEntry: Codable, Hashable, Sendable {
    var prizeName: String = ""
    var require: String = ""
    var winningCount: Int = 0
    /// 单注奖金原文，可能带"万""亿"。
    var singleBonus: String = ""
    /// 大乐透追加奖金原文。
    var addBonus: String = ""

    var amount: Double { MoneyText.parse(singleBonus) }
    var additionalAmount: Double { MoneyText.parse(addBonus) }
}

/// 下一期的确认状态。日历 API 延迟时仓库会给出推算值。
enum NextDrawStatus: String, Codable, Sendable {
    /// 官方日历已确认。
    case confirmed
    /// 日历 API 延迟，仓库按周期推算。
    case inferred
    /// 官方基准期号变了，推算值不可信，需要用户确认。
    case review
    /// 拿不到下期数据。
    case unavailable

    var label: String {
        switch self {
        case .confirmed: "已确认"
        case .inferred: "预计"
        case .review: "待确认"
        case .unavailable: "暂无"
        }
    }
}

/// 一期开奖记录。
struct Draw: Codable, Hashable, Sendable, Identifiable {
    var id: String = ""
    var gameKey: GameKey = .ssq
    var gameName: String = ""
    var expect: String = ""
    var openDate: String = ""
    var deadline: String = ""
    /// 号码区值，键与 `GameKey.drawSections` 对应。
    var drawValues = NumberSet()
    var saleAmount: String = ""
    var totalMoney: String = ""
    var prizeList: [PrizeEntry] = []

    var nextExpect: String = ""
    var nextOpenDate: String = ""
    var nextOpenTime: String = ""
    var nextBuyEndTime: String = ""
    var nextStatus: NextDrawStatus = .confirmed
    var nextSource: String = ""
    var nextBasisIssue: String = ""
    var nextResolutionReason: String = ""
    var fetchedAt: String = ""

    var firstPrize: PrizeEntry? {
        prizeList.first { $0.prizeName.contains("一等奖") }
    }

    /// 开奖号码的扁平串，用于分享和列表副标题。
    var openCode: String {
        gameKey.drawSections
            .flatMap { drawValues[$0.key] }
            .map { String($0) }
            .joined(separator: ",")
    }

    var openDateValue: Date? { DateText.parse(openDate) }
}

// MARK: - 数据仓库 JSON

/// `public_data/latest.json` 与 `public_data/draws/<game>.json` 的原始结构。
struct RemoteDraw: Decodable {
    var lotteryType: String?
    var lotteryName: String?
    var issue: String?
    var drawDate: String?
    var deadline: String?
    var numbers: RemoteNumbers?
    var prizeDetails: [RemotePrizeDetail]?
    var salesAmount: FlexibleText?
    var prizePool: FlexibleText?
    var nextIssue: FlexibleText?
    var nextDrawDate: String?
    var nextOpenTime: String?
    var nextBuyEndTime: String?
    var nextStatus: String?
    var nextSource: String?
    var nextConfirmed: Bool?
    var nextBasisIssue: FlexibleText?
    var nextResolutionReason: String?
    var fetchedAt: String?

    enum CodingKeys: String, CodingKey {
        case lotteryType = "lottery_type"
        case lotteryName = "lottery_name"
        case issue
        case drawDate = "draw_date"
        case deadline
        case numbers
        case prizeDetails = "prize_details"
        case salesAmount = "sales_amount"
        case prizePool = "prize_pool"
        case nextIssue = "next_issue"
        case nextDrawDate = "next_draw_date"
        case nextOpenTime = "next_open_time"
        case nextBuyEndTime = "next_buy_end_time"
        case nextStatus = "next_status"
        case nextSource = "next_source"
        case nextConfirmed = "next_confirmed"
        case nextBasisIssue = "next_basis_issue"
        case nextResolutionReason = "next_resolution_reason"
        case fetchedAt = "fetched_at"
    }
}

struct RemoteNumbers: Decodable {
    var red: [Int]?
    var blue: [Int]?
    var front: [Int]?
    var back: [Int]?
    var nums: [Int]?
    var digits: [Int]?
    var basic: [Int]?
    var special: Int?
}

struct RemotePrizeDetail: Decodable {
    var prizeName: String?
    var prizeLevel: String?
    var require: String?
    var winningCount: Int?
    var prizeAmount: FlexibleText?
    var additionalAmount: FlexibleText?

    enum CodingKeys: String, CodingKey {
        case prizeName = "prize_name"
        case prizeLevel = "prize_level"
        case require
        case winningCount = "winning_count"
        case prizeAmount = "prize_amount"
        case additionalAmount = "additional_amount"
    }
}

/// 仓库里同一个字段有时是字符串有时是数字，统一按字符串读。
struct FlexibleText: Decodable, Hashable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Double.self) {
            value = number == number.rounded() ? String(Int(number)) : String(number)
        } else {
            value = ""
        }
    }
}

extension Optional where Wrapped == FlexibleText {
    var text: String { self?.value ?? "" }
}

extension Draw {
    /// 把仓库 JSON 转换成本地模型，逻辑与 web 版 `convertRemoteDraw` 保持一致。
    init?(remote: RemoteDraw, gameKey overrideKey: GameKey? = nil) {
        guard let key = overrideKey ?? GameKey.fromRemoteKey(remote.lotteryType ?? "") else { return nil }
        self.init()
        gameKey = key
        expect = remote.issue ?? ""
        openDate = remote.drawDate ?? ""
        id = [key.rawValue, expect, openDate].filter { !$0.isEmpty }.joined(separator: "_")
        gameName = remote.lotteryName ?? key.label
        deadline = remote.deadline ?? ""
        drawValues = Draw.convertNumbers(gameKey: key, numbers: remote.numbers)
        saleAmount = remote.salesAmount.text
        totalMoney = remote.prizePool.text
        prizeList = (remote.prizeDetails ?? []).map { detail in
            PrizeEntry(prizeName: detail.prizeName ?? detail.prizeLevel ?? "",
                       require: detail.require ?? "",
                       winningCount: detail.winningCount ?? 0,
                       singleBonus: detail.prizeAmount.text,
                       addBonus: detail.additionalAmount.text)
        }
        nextExpect = remote.nextIssue.text
        nextOpenDate = remote.nextDrawDate ?? ""
        nextOpenTime = remote.nextOpenTime ?? ""
        nextBuyEndTime = remote.nextBuyEndTime ?? ""
        let statusText = remote.nextStatus ?? (remote.nextConfirmed == false ? "inferred" : "confirmed")
        nextStatus = NextDrawStatus(rawValue: statusText) ?? .confirmed
        nextSource = remote.nextSource ?? "class_api"
        nextBasisIssue = remote.nextBasisIssue.text.isEmpty ? expect : remote.nextBasisIssue.text
        nextResolutionReason = remote.nextResolutionReason ?? ""
        fetchedAt = remote.fetchedAt ?? ""
    }

    static func convertNumbers(gameKey: GameKey, numbers: RemoteNumbers?) -> NumberSet {
        guard let numbers else { return NumberSet() }
        switch gameKey {
        case .ssq:
            return NumberSet([.red: numbers.red ?? [], .blue: numbers.blue ?? []])
        case .dlt:
            return NumberSet([.front: numbers.front ?? [], .back: numbers.back ?? []])
        case .k8:
            return NumberSet([.nums: numbers.nums ?? []])
        case .fc3d, .pl3, .pl5:
            return NumberSet([.nums: numbers.digits ?? []])
        case .qlc:
            var set = NumberSet([.nums7: numbers.basic ?? []])
            if let special = numbers.special { set[.special] = [special] }
            return set
        case .qxc:
            let digits = numbers.digits ?? []
            var set = NumberSet([.nums6: Array(digits.prefix(6))])
            if digits.count > 6 { set[.tail] = [digits[6]] }
            return set
        }
    }
}

/// `latest.json` 顶层结构。
struct RemoteLatestPayload: Decodable {
    var updatedAt: String?
    var draws: [String: RemoteDraw]?

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case draws
    }
}

/// `draws/<game>.json` 顶层结构。
struct RemoteHistoryPayload: Decodable {
    var updatedAt: String?
    var draws: [RemoteDraw]?

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case draws
    }
}
