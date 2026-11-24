import Foundation

/// Local handoff between the app and the notification service. The wallet database stays in
/// its original sandbox. Only tickets waiting for a draw are copied into the App Group.
struct DrawNotificationStore {
    static let appGroup = "group.com.wenjinliu.lotterywallet"

    let directory: URL

    static var shared: Self? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { Self(directory: $0.appendingPathComponent("DrawNotifications", isDirectory: true)) }
    }

    struct PendingTicket: Codable {
        let game: GameKey
        let issue: String
        let date: String
        let numbers: Data
        let multiple: Int
        let cost: Double

        func matches(_ draw: Draw) -> Bool {
            game == draw.gameKey && issue == draw.expect &&
                (date.isEmpty || date == draw.openDate)
        }
    }

    struct Summary: Equatable {
        var purchased = 0
        var winners = 0
        var floatingNames: [String] = []
        var estimated = false
        var cost = 0.0
        var prize = 0.0

        var body: String {
            let purchase = "\(purchased) 注 · 投入 \(MoneyText.format(cost))"
            guard winners > 0 else { return "\(purchase) · 未中奖" }
            let win = "中 \(winners) 注"
            var parts = [purchase, win]
            if prize > 0 {
                let label = estimated ? "预计奖金" : (floatingNames.isEmpty ? "奖金" : "固定奖")
                parts.append("\(label) \(MoneyText.format(prize))")
            }
            parts += floatingNames
            return parts.joined(separator: " · ")
        }

        mutating func add(_ result: PrizeResult, draw: Draw, ticket: Ticket, multiple: Int, cost: Double) {
            purchased += 1
            self.cost += cost
            guard result.isWin else { return }
            winners += 1
            guard let unit = PrizeRules.ordinaryUnitPrize(game: draw.gameKey, result: result, ticket: ticket) else {
                if !floatingNames.contains(result.prizeName) { floatingNames.append(result.prizeName) }
                return
            }
            let official = draw.prizeList.first {
                PrizeRules.canonicalPrizeName($0.prizeName.isEmpty ? $0.require : $0.prizeName)
                    == PrizeRules.canonicalPrizeName(result.prizeName) && $0.amount > 0
            }?.amount
            estimated = estimated || official == nil
            prize += (official ?? Double(unit)) * Double(min(max(multiple, 1), 99))
        }
    }

    func replacePendingTickets(_ tickets: [PendingTicket]) throws {
        try write(tickets, to: directory.appendingPathComponent("pending.json"))
    }

    /// Evaluates only this issue. Invalid or unreadable local data must not produce a result.
    func summary(for draw: Draw) throws -> Summary? {
        guard Self.isComplete(draw) else { return nil }
        let data = try Data(contentsOf: directory.appendingPathComponent("pending.json"))
        let tickets = try JSONDecoder().decode([PendingTicket].self, from: data).filter { $0.matches(draw) }
        guard !tickets.isEmpty else { return nil }

        var summary = Summary()
        for entry in tickets {
            let ticket = try JSONDecoder().decode(Ticket.self, from: entry.numbers)
            let result = PrizeRules.evaluate(gameKey: entry.game, ticket: ticket, draw: draw, multiple: entry.multiple)
            summary.add(result, draw: draw, ticket: ticket, multiple: entry.multiple, cost: entry.cost)
        }
        return summary
    }

    /// Store the authoritative draw before displaying a result so the main app can apply it
    /// to current wallet records during a background wake or when it next becomes active.
    func record(_ draw: Draw) throws {
        let key = DrawPushPayload.identifier(game: draw.gameKey, issue: draw.expect)
        try write(draw, to: receipts.appendingPathComponent(key).appendingPathExtension("json"))
    }

    func receiptFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: receipts.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    static func isComplete(_ draw: Draw) -> Bool {
        guard !draw.expect.isEmpty, draw.expect.utf8.count <= 32,
              draw.expect.utf8.allSatisfy({ (48...57).contains($0) }),
              DateText.parse(draw.openDate) != nil else { return false }
        return draw.gameKey.drawSections.allSatisfy { section in
            let numbers = draw.drawValues[section.key]
            return numbers.count == section.count && numbers.allSatisfy { section.range.contains($0) } &&
                (section.isPositional || Set(numbers).count == numbers.count)
        }
    }

    private var receipts: URL { directory.appendingPathComponent("Results", isDirectory: true) }

    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var localDirectory = directory
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try localDirectory.setResourceValues(properties)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
