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
    /// 号码区值，键与 `GameKey.drawSections` 对应。
    var drawValues = NumberSet()
    var saleAmount: String = ""
    var totalMoney: String = ""
    var prizeList: [PrizeEntry] = []

    // 「下一期是哪期」曾经也挂在这里（`nextExpect` / `nextOpenTime` / …），
    // 每一条开奖记录都带一份。V2 把它挪进了 `bootstrap.schedule`，
    // 一个彩种一份 —— 见 `DrawSchedule`。这里不再重复保存。

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

// MARK: - 线上数据的共用零件

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

