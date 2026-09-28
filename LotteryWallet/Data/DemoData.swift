import Foundation
import SwiftData

/// `--demo-data` 启动时用的示例票据：截图、UI 测试和 Live Preview 都靠它。
///
/// 数据在 `DemoDataset`（由 `Scripts/make-demo-data.py` 生成）：2026-06-01 至 09-27
/// 每一期双色球、大乐透各一张票，开奖号码和奖金是 lottery-data-repo 里的真实数据。
///
/// **示例模式下库只在内存里**：不碰用户的本机库，不做自动备份，关掉 App 就没了。
/// 这样测试可以随便点、随便改，也不会把示例票写进谁的票夹。
@MainActor
enum DemoData {

    static let launchArgument = "--demo-data"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// 最近几张票保持「还没看过结果」，票夹角标和「新结果」分区才有东西可看。
    static let unseenBatchCount = 2

    /// 装着示例票据的内存库。
    static func makeContainer() -> ModelContainer {
        let configuration = ModelConfiguration(schema: ModelStore.schema, isStoredInMemoryOnly: true)
        // 内存库建不起来说明 schema 本身坏了，崩掉比显示一个空票夹更容易发现。
        let container = try! ModelContainer(for: ModelStore.schema, configurations: [configuration])
        for record in records() {
            container.mainContext.insert(record)
        }
        try? container.mainContext.save()
        return container
    }

    /// 示例模式下的偏好默认值。写进注册域：只对这次启动生效、不落盘，用户改过的值仍然优先。
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            // 示例票里「已读」状态是播种时定好的，不要被首次启动的回填全标成已读。
            "lottery.resultSeenBackfilled.v1": true,
            // 截图里不要出现「该备份了」的提醒。
            "lottery.lastBackupAt": Date().timeIntervalSince1970 - 3600,
        ])
    }

    // MARK: - 数据

    struct Dataset: Decodable {
        struct DrawItem: Decodable {
            struct Prize: Decodable {
                let name: String
                let amount: String
            }
            let game: String
            let issue: String
            let date: String
            let numbers: [String: [Int]]
            let prizes: [Prize]
        }
        struct TicketItem: Decodable {
            let game: String
            let issue: String
            let lines: [[String: [Int]]]
        }
        let draws: [DrawItem]
        let tickets: [TicketItem]
    }

    static func dataset() -> Dataset {
        // 生成的 JSON 是随 App 编译进来的，解不开只可能是生成脚本坏了。
        try! JSONDecoder().decode(Dataset.self, from: Data(DemoDataset.json.utf8))
    }

    /// 示例票对应的开奖。
    static func draws() -> [Draw] { draws(dataset()) }

    static func draws(_ dataset: Dataset) -> [Draw] {
        dataset.draws.compactMap { item in
            guard let game = GameKey(rawValue: item.game) else { return nil }
            var draw = Draw()
            draw.gameKey = game
            draw.gameName = game.label
            draw.expect = item.issue
            draw.openDate = item.date
            draw.id = [game.rawValue, item.issue, item.date].joined(separator: "_")
            draw.drawValues = numberSet(item.numbers)
            draw.prizeList = item.prizes.map { PrizeEntry(prizeName: $0.name, singleBonus: $0.amount) }
            return draw
        }
    }

    /// 播种用的记录，已经按真实开奖核对过：奖级、奖金、逐球命中都由 `PrizeRules` 判定。
    static func records() -> [TicketRecord] {
        let data = dataset()
        var drawIndex: [String: Draw] = [:]
        for draw in draws(data) { drawIndex["\(draw.gameKey.rawValue)_\(draw.expect)"] = draw }

        let tickets = data.tickets.sorted { lhs, rhs in
            (drawIndex["\(lhs.game)_\(lhs.issue)"]?.openDate ?? "", lhs.game)
                < (drawIndex["\(rhs.game)_\(rhs.issue)"]?.openDate ?? "", rhs.game)
        }
        var records: [TicketRecord] = []
        for (position, item) in tickets.enumerated() {
            guard let game = GameKey(rawValue: item.game),
                  let draw = drawIndex["\(item.game)_\(item.issue)"],
                  let openDay = DateText.parse(draw.openDate) else { continue }
            // 开奖当天中午录的票，同一天的两张票错开几分钟，票夹排序才稳定。
            let createdAt = openDay.addingTimeInterval(12 * 3600 + Double(position % 2) * 600)
            let isUnseen = position >= tickets.count - unseenBatchCount
            let batchId = "demo_\(game.rawValue)_\(item.issue)"
            let target = DrawTarget(expect: draw.expect,
                                    openDate: draw.openDate,
                                    openTime: "\(draw.openDate) 21:15:00",
                                    buyEndTime: "\(draw.openDate) 20:00:00",
                                    sourceDrawId: draw.id,
                                    status: .confirmed,
                                    source: "demo")
            for (index, line) in item.lines.enumerated() {
                let ticket = Ticket(numbers: numberSet(line),
                                    playMode: game.defaultPlayMode,
                                    entryLabel: EntryKind.manual.label)
                let record = TicketRecord(id: "\(batchId)_\(String(format: "%03d", index + 1))",
                                          batchId: batchId,
                                          game: game,
                                          ticket: ticket,
                                          entryKind: .manual,
                                          target: target,
                                          price: game.unitPrice,
                                          multiple: 1,
                                          source: "demo",
                                          createdAt: createdAt)
                let result = PrizeRules.evaluate(gameKey: game, ticket: ticket, draw: draw, multiple: 1)
                RecordService.write(result, from: draw, into: record,
                                    at: createdAt.addingTimeInterval(10 * 3600))
                record.resultSeenAt = isUnseen ? nil : createdAt.addingTimeInterval(20 * 3600)
                records.append(record)
            }
        }
        return records
    }

    private static func numberSet(_ raw: [String: [Int]]) -> NumberSet {
        var values: [SectionKey: [Int]] = [:]
        for (key, numbers) in raw {
            guard let section = SectionKey(rawValue: key) else { continue }
            values[section] = numbers
        }
        return NumberSet(values)
    }
}
