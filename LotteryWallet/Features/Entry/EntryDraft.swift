import Foundation
import SwiftData

/// 把一张已经存进票夹的票还原成「录入页能编辑的状态」。
///
/// 修改一张票和新录一张票，用的是同一个工作台（`EntryFlowView`）——
/// 界面、校验、展开规则都不该有第二套。差别只在于：进页面时要先把
/// 这张票已有的内容填回去，保存时走 `RecordService.replace` 而不是 `save`。
///
/// **必须从记录本身还原，不能从 `TicketCard` 还原。** 那是个渲染快照，
/// `lines` 只截了前几注（复式票能展开到 2000 注），拿它当数据源会丢号码。
struct EntryDraft: Identifiable {
    var id: String { batchId }

    let batchId: String
    /// 原样留住，修改不该让这张票在票夹里跳位置。
    let createdAt: Date
    let game: GameKey
    let shape: TicketShape
    let playMode: String
    let multiple: Int
    let expect: String
    let entryKind: EntryKind
    let source: String

    /// 单式票的每一注。复式/胆拖为空。
    let lines: [NumberSet]
    /// 复式/胆拖的整票选号。单式为空。
    let selections: [SectionKey: SectionSelection]

    /// 从一整批记录还原。
    ///
    /// 复式和胆拖不能拿展开后的注去还原选号 —— 那是笛卡尔积的结果，
    /// 逐注塞回选号盘会得到一堆重复号。它们的整票选号本来就藏在注里：
    /// **某个区所有注的并集**是这个区选的号，**所有注的交集**是胆码。
    /// 这套推导票夹里已经在用（`TicketCard.wholeZones`），这里同源。
    init?(records: [TicketRecord]) {
        guard let first = records.first else { return nil }
        batchId = first.batchId
        createdAt = first.createdAt
        game = first.game
        multiple = first.multiple
        expect = first.targetExpect
        entryKind = first.entryKind
        source = first.source
        shape = TicketShape.from(entryLabel: first.entryLabel)

        // 大乐透的「追加」存在 addOn 上，其余彩种的玩法存在 playMode 上。
        if first.game == .dlt {
            playMode = first.ticket.addOn ? "add" : "normal"
        } else {
            playMode = first.playMode
        }

        switch shape {
        case .single:
            lines = records.map(\.ticket.numbers)
            selections = [:]
        case .system, .dantuo:
            lines = []
            var zones: [SectionKey: SectionSelection] = [:]
            for section in first.game.sections {
                var union: Set<Int> = []
                var intersection: Set<Int>?
                for record in records {
                    let values = Set(record.ticket.numbers[section.key])
                    union.formUnion(values)
                    intersection = intersection.map { $0.intersection(values) } ?? values
                }
                guard !union.isEmpty else { continue }
                var selection = SectionSelection(selected: union.sorted())
                if shape == .dantuo {
                    // 交集就是每一注都出现的号 —— 也就是胆码。
                    // 但整个区都被交集覆盖时说明这个区是定选的，不是胆拖，
                    // 那种情况下没有胆码可言。
                    let dan = intersection ?? []
                    if dan.count < union.count { selection.dan = dan.sorted() }
                }
                zones[section.key] = selection
            }
            selections = zones
        }
    }

    /// 按 batchId 把一整批记录捞出来再还原。
    @MainActor
    static func load(batchId: String, context: ModelContext) -> EntryDraft? {
        let descriptor = FetchDescriptor<TicketRecord>(
            predicate: #Predicate { $0.batchId == batchId },
            sortBy: [SortDescriptor(\TicketRecord.id)]
        )
        guard let records = try? context.fetch(descriptor), !records.isEmpty else { return nil }
        return EntryDraft(records: records)
    }
}
