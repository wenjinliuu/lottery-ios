import Foundation

/// 一注票的核对结果。
struct PrizeResult: Hashable, Sendable {
    /// 奖级名，未中奖时为"未中奖"。
    var prizeName: String
    /// 已确定的奖金（已乘倍数）。
    var amount: Double
    /// 浮动奖金：中了奖但官方还没公布单注奖金。
    var isFloating: Bool
    /// 每个号码区逐球命中标记，用于票面高亮。
    var matched: [SectionKey: [Bool]]

    var isWin: Bool { prizeName != PrizeRules.noPrizeName }

    static let none = PrizeResult(prizeName: PrizeRules.noPrizeName, amount: 0, isFloating: false, matched: [:])
}

/// 奖级判定，逐条对照 web 版 `web/rules.js`，两端结论必须一致。
enum PrizeRules {
    static let noPrizeName = "未中奖"

    // MARK: - 号码比对

    /// 可重复计数的交集大小。
    static func countMatches(_ ticket: [Int], _ draw: [Int]) -> Int {
        var counts: [Int: Int] = [:]
        for number in draw { counts[number, default: 0] += 1 }
        var total = 0
        for number in ticket where (counts[number] ?? 0) > 0 {
            counts[number]! -= 1
            total += 1
        }
        return total
    }

    /// 逐位命中标记，重复号只消耗一次。
    static func markMatches(_ ticket: [Int], _ draw: [Int]) -> [Bool] {
        var counts: [Int: Int] = [:]
        for number in draw { counts[number, default: 0] += 1 }
        return ticket.map { number in
            guard (counts[number] ?? 0) > 0 else { return false }
            counts[number]! -= 1
            return true
        }
    }

    static func multisetEqual(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.sorted() == rhs.sorted()
    }

    /// 组三形态：三位里恰好两位相同。
    static func isGroup3(_ numbers: [Int]) -> Bool {
        var counts: [Int: Int] = [:]
        for number in numbers { counts[number, default: 0] += 1 }
        return counts.values.sorted() == [1, 2]
    }

    // MARK: - 奖级名归一

    static func canonicalPrizeName(_ raw: String) -> String {
        var text = raw
        for (pattern, replacement) in [("组选[3三]奖?", "组三"), ("组选[6六]奖?", "组六"), ("直选奖", "直选")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    static func hasPrize(named prizeName: String, in draw: Draw?) -> Bool {
        guard let draw else { return false }
        let target = canonicalPrizeName(prizeName)
        return draw.prizeList.contains { canonicalPrizeName($0.prizeName) == target }
    }

    // MARK: - 各彩种判奖

    private static func floating(_ name: String, _ matched: [SectionKey: [Bool]]) -> PrizeResult {
        PrizeResult(prizeName: name, amount: 0, isFloating: true, matched: matched)
    }

    private static func none(_ matched: [SectionKey: [Bool]]) -> PrizeResult {
        PrizeResult(prizeName: noPrizeName, amount: 0, isFloating: false, matched: matched)
    }

    static func evaluateSSQ(ticket: Ticket, draw: Draw) -> PrizeResult {
        let red = countMatches(ticket[.red], draw.drawValues[.red])
        let blueHit = ticket.numbers.first(.blue) != nil && ticket.numbers.first(.blue) == draw.drawValues.first(.blue)
        let matched: [SectionKey: [Bool]] = [
            .red: markMatches(ticket[.red], draw.drawValues[.red]),
            .blue: [blueHit]
        ]
        switch (red, blueHit) {
        case (6, true): return floating("一等奖", matched)
        case (6, false): return floating("二等奖", matched)
        case (5, true): return floating("三等奖", matched)
        case (5, false), (4, true): return floating("四等奖", matched)
        case (4, false), (3, true): return floating("五等奖", matched)
        case (0, true), (1, true), (2, true): return floating("六等奖", matched)
        case (3, false) where hasPrize(named: "福运奖", in: draw): return floating("福运奖", matched)
        default: return none(matched)
        }
    }

    static func evaluateDLT(ticket: Ticket, draw: Draw) -> PrizeResult {
        let front = countMatches(ticket[.front], draw.drawValues[.front])
        let back = countMatches(ticket[.back], draw.drawValues[.back])
        let matched: [SectionKey: [Bool]] = [
            .front: markMatches(ticket[.front], draw.drawValues[.front]),
            .back: markMatches(ticket[.back], draw.drawValues[.back])
        ]
        switch (front, back) {
        case (5, 2): return floating("一等奖", matched)
        case (5, 1): return floating("二等奖", matched)
        case (5, 0), (4, 2): return floating("三等奖", matched)
        case (4, 1): return floating("四等奖", matched)
        case (4, 0), (3, 2): return floating("五等奖", matched)
        case (3, 1), (2, 2): return floating("六等奖", matched)
        case (3, 0), (2, 1), (1, 2), (0, 2): return floating("七等奖", matched)
        default: return none(matched)
        }
    }

    static func evaluateK8(ticket: Ticket, draw: Draw) -> PrizeResult {
        let hits = countMatches(ticket[.nums], draw.drawValues[.nums])
        let matched: [SectionKey: [Bool]] = [.nums: markMatches(ticket[.nums], draw.drawValues[.nums])]
        let playCount = ticket.playCount ?? Int(ticket.playMode) ?? ticket[.nums].count
        guard let entry = findK8PrizeEntry(draw.prizeList, playCount: playCount, hits: hits) else {
            return none(matched)
        }
        return floating(entry.prizeName, matched)
    }

    /// 快乐8 的奖级名形如"选七中五"，中英文数字都要认。
    static func findK8PrizeEntry(_ prizeList: [PrizeEntry], playCount: Int, hits: Int) -> PrizeEntry? {
        let playChinese = ChineseNumber.text(playCount)
        let hitsChinese = ChineseNumber.text(hits)
        return prizeList.first { entry in
            let name = entry.prizeName.isEmpty ? entry.require : entry.prizeName
            let matchesPlay = name.contains("选\(playCount)") || name.contains("选\(playChinese)")
            let matchesHits = name.contains("中\(hits)") || name.contains("中\(hitsChinese)")
            return matchesPlay && matchesHits
        }
    }

    static func evaluateDigit(ticket: Ticket, draw: Draw) -> PrizeResult {
        let numbers = ticket[.nums3]
        let drawNumbers = draw.drawValues[.nums]
        if ticket.playMode == "single" {
            let flags = numbers.enumerated().map { index, value in
                index < drawNumbers.count && value == drawNumbers[index]
            }
            let matched: [SectionKey: [Bool]] = [.nums3: flags]
            return flags.count == drawNumbers.count && flags.allSatisfy { $0 }
                ? floating("直选", matched)
                : none(matched)
        }
        let matched: [SectionKey: [Bool]] = [.nums3: markMatches(numbers, drawNumbers)]
        if ticket.playMode == "group3" {
            return isGroup3(drawNumbers) && multisetEqual(numbers, drawNumbers)
                ? floating("组三", matched)
                : none(matched)
        }
        return Set(drawNumbers).count == 3 && multisetEqual(numbers, drawNumbers)
            ? floating("组六", matched)
            : none(matched)
    }

    static func evaluatePL5(ticket: Ticket, draw: Draw) -> PrizeResult {
        let numbers = ticket[.nums5]
        let drawNumbers = draw.drawValues[.nums]
        let flags = numbers.enumerated().map { index, value in
            index < drawNumbers.count && value == drawNumbers[index]
        }
        let matched: [SectionKey: [Bool]] = [.nums5: flags]
        return flags.count == drawNumbers.count && flags.allSatisfy { $0 }
            ? floating("一等奖", matched)
            : none(matched)
    }

    static func evaluateQLC(ticket: Ticket, draw: Draw) -> PrizeResult {
        let basic = draw.drawValues[.nums7]
        let special = draw.drawValues.first(.special)
        let front = countMatches(ticket[.nums7], basic)
        let specialHit = special.map { ticket[.nums7].contains($0) } ?? false
        let matched: [SectionKey: [Bool]] = [
            .nums7: markMatches(ticket[.nums7], basic + (special.map { [$0] } ?? []))
        ]
        switch (front, specialHit) {
        case (7, _): return floating("一等奖", matched)
        case (6, true): return floating("二等奖", matched)
        case (6, false): return floating("三等奖", matched)
        case (5, true): return floating("四等奖", matched)
        case (5, false): return floating("五等奖", matched)
        case (4, true): return floating("六等奖", matched)
        case (4, false): return floating("七等奖", matched)
        default: return none(matched)
        }
    }

    static func evaluateQXC(ticket: Ticket, draw: Draw) -> PrizeResult {
        let drawMain = draw.drawValues[.nums6]
        let mainFlags = ticket[.nums6].enumerated().map { index, value in
            index < drawMain.count && value == drawMain[index]
        }
        let mainCount = mainFlags.filter { $0 }.count
        let tailHit = ticket.numbers.first(.tail) != nil && ticket.numbers.first(.tail) == draw.drawValues.first(.tail)
        let matched: [SectionKey: [Bool]] = [.nums6: mainFlags, .tail: [tailHit]]
        if mainCount == 6 && tailHit { return floating("一等奖", matched) }
        if mainCount == 6 { return floating("二等奖", matched) }
        if mainCount == 5 && tailHit { return floating("三等奖", matched) }
        if mainCount == 5 || (mainCount == 4 && tailHit) { return floating("四等奖", matched) }
        if mainCount == 4 || (mainCount == 3 && tailHit) { return floating("五等奖", matched) }
        if mainCount == 3 || tailHit { return floating("六等奖", matched) }
        return none(matched)
    }

    // MARK: - 浮动奖金落地

    static func findPrizeAmount(in prizeList: [PrizeEntry], prizeName: String, gameKey: GameKey, playCount: Int?) -> Double {
        let candidates = prizeList.filter { entry in
            let name = entry.prizeName.isEmpty ? entry.require : entry.prizeName
            if gameKey == .k8 {
                let count = playCount ?? 0
                let lastNumber = prizeName.split(whereSeparator: { !$0.isNumber }).last.map(String.init) ?? ""
                let hitsChinese = Int(lastNumber).map { ChineseNumber.text($0) } ?? ""
                let matchesPlay = name.contains("选\(count)") || name.contains("选\(ChineseNumber.text(count))")
                let matchesHits = name.contains("中\(lastNumber)") || (!hitsChinese.isEmpty && name.contains("中\(hitsChinese)"))
                return matchesPlay && matchesHits
            }
            let normalizedName = canonicalPrizeName(name)
            let normalizedTarget = canonicalPrizeName(prizeName)
            return normalizedName.contains(normalizedTarget)
                && (prizeName.contains("追加") || !name.contains("追加"))
        }
        for candidate in candidates where candidate.amount > 0 {
            return candidate.amount
        }
        return 0
    }

    private static func findDLTAddOnAmount(_ prizeList: [PrizeEntry], prizeName: String) -> Double {
        for entry in prizeList {
            let name = entry.prizeName.isEmpty ? entry.require : entry.prizeName
            guard name.contains("追加"), name.contains(prizeName), entry.amount > 0 else { continue }
            return entry.amount
        }
        return 0
    }

    /// 部分数据源把追加奖金放在同一条记录的 `additional_amount` 里。
    private static func findDLTInlineAddOnAmount(_ prizeList: [PrizeEntry], prizeName: String) -> Double {
        prizeList.first {
            let name = $0.prizeName.isEmpty ? $0.require : $0.prizeName
            return name.contains(prizeName) && !$0.addBonus.isEmpty
        }?.additionalAmount ?? 0
    }

    static func resolveFloatingAmount(draw: Draw?, prizeName: String, gameKey: GameKey, ticket: Ticket) -> Double {
        guard let draw, !draw.prizeList.isEmpty else { return 0 }
        let base = findPrizeAmount(in: draw.prizeList, prizeName: prizeName, gameKey: gameKey, playCount: ticket.playCount)
        let isAddOn = ticket.addOn || ticket.playMode == "add"
        guard gameKey == .dlt, isAddOn, ["一等奖", "二等奖"].contains(prizeName) else { return base }
        var addOn = findPrizeAmount(in: draw.prizeList, prizeName: "\(prizeName)追加", gameKey: gameKey, playCount: nil)
        if addOn == 0 { addOn = findPrizeAmount(in: draw.prizeList, prizeName: "追加\(prizeName)", gameKey: gameKey, playCount: nil) }
        if addOn == 0 { addOn = findDLTInlineAddOnAmount(draw.prizeList, prizeName: prizeName) }
        if addOn == 0 { addOn = findDLTAddOnAmount(draw.prizeList, prizeName: prizeName) }
        // 追加票的奖金必须"基本 + 追加"都拿到才算确定，否则继续按浮动展示。
        return addOn > 0 ? base + addOn : 0
    }

    // MARK: - 统一入口

    static func evaluate(gameKey: GameKey, ticket: Ticket, draw: Draw, multiple: Int = 1) -> PrizeResult {
        var result: PrizeResult
        switch gameKey {
        case .ssq: result = evaluateSSQ(ticket: ticket, draw: draw)
        case .dlt: result = evaluateDLT(ticket: ticket, draw: draw)
        case .k8: result = evaluateK8(ticket: ticket, draw: draw)
        case .fc3d, .pl3: result = evaluateDigit(ticket: ticket, draw: draw)
        case .pl5: result = evaluatePL5(ticket: ticket, draw: draw)
        case .qlc: result = evaluateQLC(ticket: ticket, draw: draw)
        case .qxc: result = evaluateQXC(ticket: ticket, draw: draw)
        }
        let multiplier = Double(min(max(multiple, 1), 99))
        guard result.isFloating else {
            result.amount *= multiplier
            return result
        }
        let resolved = resolveFloatingAmount(draw: draw, prizeName: result.prizeName, gameKey: gameKey, ticket: ticket)
        if resolved > 0 {
            result.isFloating = false
            result.amount = resolved * multiplier
        } else {
            result.amount = 0
        }
        return result
    }
}
