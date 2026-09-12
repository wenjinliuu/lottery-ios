import Foundation
import SwiftData

/// 票据的保存、核对与期次校正。所有操作都在主线程的 ModelContext 上执行，
/// 因此这里的每个循环都要保证是 O(记录数)：开奖走 DrawStore 的索引，
/// 号码走 TicketRecord 的解码缓存，不做任何逐条的线性查找。
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
        let descriptor = FetchDescriptor<TicketRecord>(predicate: #Predicate { $0.batchId == batchId })
        for record in (try? context.fetch(descriptor)) ?? [] {
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

    /// 对一注记录求值并把结果写回记录本身。
    /// 结果落库之后，票夹列表直接读字段渲染，不再在视图里重算。
    @discardableResult
    func apply(_ record: TicketRecord) -> Bool {
        guard let draw = drawStore.draw(matching: record) else { return false }
        let result = PrizeRules.evaluate(gameKey: record.game,
                                         ticket: record.ticket,
                                         draw: draw,
                                         multiple: record.multiple)
        let status: RecordStatus = result.isFloating ? .prizeFloat : (result.amount > 0 ? .won : .lost)
        let text: String
        if result.isFloating {
            text = "\(result.prizeName)，奖金浮动"
        } else if result.amount > 0 {
            text = "中奖 \(MoneyText.format(result.amount))"
        } else {
            text = "未中奖"
        }

        // 结论没变就不写库，避免无谓的脏数据和界面刷新
        guard record.status != status
                || record.prizeAmount != result.amount
                || record.prizeName != result.prizeName
                || !record.hasMatches else { return false }

        record.status = status
        record.resultText = text
        record.prizeAmount = result.amount
        record.prizeName = result.prizeName
        record.matched = result.matched
        if !draw.expect.isEmpty { record.targetExpect = draw.expect }
        if !draw.openDate.isEmpty { record.targetOpenDate = draw.openDate }
        record.targetSourceDrawId = draw.id
        record.refreshProfitDay()
        record.updatedAt = Date()
        return true
    }

    /// 批量核对。已经有最终结论的记录不再重复计算，
    /// 但"奖金浮动"会一直复核，直到官方公布单注奖金。
    ///
    /// 还有第三种要复核的：**命中标记缺失的已结算记录**。
    /// 备份恢复时 `statusRaw` 是照抄回来的（won / lost），`matchedData` 却是空的
    /// —— 原本指望重新核对补上，但这里的 guard 又把已结算的记录跳过去了，
    /// 于是那批票的命中标记永远补不回来。票面渲染拿"有没有命中标记"当
    /// "有没有核对过"，结果导入的老票整排号码球全是满色，看起来像全中了。
    @discardableResult
    func checkAll(_ records: [TicketRecord]? = nil) throws -> (checked: Int, won: Int) {
        let targets = records ?? allRecords()
        var checked = 0
        var won = 0
        var repaired = 0
        for record in targets {
            if record.status == .pending || record.status == .prizeFloat {
                guard apply(record) else { continue }
                checked += 1
                if record.status == .won { won += 1 }
            } else if !record.hasMatches {
                if repairMatches(record) { repaired += 1 }
            }
        }
        if checked > 0 || repaired > 0 { try context.save() }
        return (checked, won)
    }

    // MARK: - 已读

    /// 把这些电子票的结果标记成「用户已经看过」。
    ///
    /// 只有已经出结果的才写。等开奖的票没有结果可看，提前标上会让它
    /// 出结果的那一刻直接沉进历史区 —— 正好是这次要修的那个毛病。
    @discardableResult
    func markResultsSeen(batchIds: Set<String>, at moment: Date = Date()) -> Int {
        guard !batchIds.isEmpty else { return 0 }
        let now = moment
        var touched = 0
        for record in allRecords()
        where batchIds.contains(record.batchId) && record.resultSeenAt == nil && record.status.hasResult {
            record.resultSeenAt = now
            touched += 1
        }
        // 这里刻意**不动** updatedAt：已读是阅读状态，不是这条记录的内容变化。
        if touched > 0 { try? context.save() }
        return touched
    }

    /// 升级到带已读状态的版本时，把历史记录一次性标成已看过。
    ///
    /// 不做这一步的话，老用户升级后一进票夹，几百张陈年老票全挤在
    /// 「新结果」区、角标显示 300+ —— 全是他早就看过的东西。
    @discardableResult
    func backfillSeenForExistingRecords(at moment: Date = Date()) -> Int {
        var touched = 0
        for record in allRecords() where record.resultSeenAt == nil && record.status.hasResult {
            // 用当初核对写库的时刻，而不是现在 —— 这样它在历史区里的位置也合理
            record.resultSeenAt = record.updatedAt
            touched += 1
        }
        if touched > 0 { try? context.save() }
        return touched
    }

    /// 只补命中标记，**不动**状态和奖金。
    ///
    /// 这一步刻意不走 `apply`。已结算的记录里状态和奖金是当初核对出来、
    /// 用户也已经看过的事实；重算一遍等于拿今天的开奖数据去覆盖它，
    /// 只要有一处对不上（最典型的是大乐透追加：奖池行缺了追加那一档，
    /// `PrizeRules` 会算出 0 元），一张真的中过奖的票就会被改成「未中奖」。
    /// 补标记是为了让号码球显示正确，不该有能力改写账目。
    @discardableResult
    func repairMatches(_ record: TicketRecord) -> Bool {
        guard !record.hasMatches,
              let draw = drawStore.draw(matching: record) else { return false }
        let result = PrizeRules.evaluate(gameKey: record.game,
                                         ticket: record.ticket,
                                         draw: draw,
                                         multiple: record.multiple)
        guard !result.matched.isEmpty else { return false }
        record.matched = result.matched
        return true
    }

    /// 需要补命中标记的记录横跨哪些「彩种 × 年份」。
    ///
    /// 导入恢复的记录状态是 won / lost，命中标记却是空的。要把标记补回来
    /// 就得先拿到那一期的开奖号，而它多半已经不在最近 50 期里了。
    func archivesNeedingMatchRepair() -> [GameKey: Set<Int>] {
        var wanted: [GameKey: Set<Int>] = [:]
        for record in allRecords() where !record.hasMatches && record.status.isFinal {
            let day = record.targetOpenDate.isEmpty ? DateText.day(record.createdAt) : record.targetOpenDate
            guard let year = Int(day.prefix(4)) else { continue }
            wanted[record.game, default: []].insert(year)
        }
        return wanted
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
    func reconcileInferredTargets(_ records: [TicketRecord]? = nil) throws -> Reconciliation {
        var summary = Reconciliation()
        // 每个彩种的官方下期信息只查一次，不要在循环里反复算
        var officialByGame: [GameKey: DrawTarget] = [:]

        for record in records ?? allRecords() {
            guard !record.status.isFinal, record.targetStatus == .inferred else { continue }
            if drawStore.draw(for: record.game, expect: record.targetExpect) != nil { continue }

            let official: DrawTarget?
            if let cached = officialByGame[record.game] {
                official = cached
            } else {
                let resolved = drawStore.nextDrawMetadata(for: record.game)
                if let resolved { officialByGame[record.game] = resolved }
                official = resolved
            }
            guard let official, official.status == .confirmed else { continue }

            // 官方基准期号和录入时不一致，说明推算前提变了，交给用户确认
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
            record.refreshProfitDay()
            record.updatedAt = Date()
        }
        if summary.changed { try context.save() }
        return summary
    }
}

/// 一张电子票的**渲染快照**。
///
/// 票夹卡顿的根因是这里：早期版本让视图直接持有 `[TicketRecord]`（SwiftData
/// 托管对象），号码、命中标记、金额全在 `body` 里现取现解码。三个后果：
/// 1. 每次渲染都在遍历托管对象，复式票 2000 注就是几千次托管属性访问；
/// 2. `record.ticket` 的 getter 会写 `@Transient` 缓存 —— 那是个**被 Observation
///    追踪的属性**，等于「渲染时修改被观察状态」，直接触发额外的失效重绘；
/// 3. JSONDecoder 在滚动过程中被反复调用。
///
/// 现在全部提前算成纯值，渲染时一个 SwiftData 属性都不碰。
/// 这和 `ProfitStats` 里 `SettledEntry` 是同一个原则。
struct TicketCard: Identifiable, Hashable {
    /// 一次购买展开成的一注。
    struct Line: Identifiable, Hashable {
        let id: String
        let numbers: [SectionKey: [Int]]
        let matched: [SectionKey: [Bool]]
        let prizeAmount: Double
        let status: RecordStatus
        /// 这一注是否已经核对过 —— 也就是**有没有命中标记可以拿来渲染**。
        ///
        /// 导入恢复的老票状态是 won / lost，命中标记却是空的，
        /// 那时候整注号码会被当成"还没开奖"按满色画出来，看着像全中了。
        /// 这个问题的正解是把标记补回来（见 `checkAll` 里的
        /// `needsMatchRepair`），而不是在这里拿状态硬当"已核对"——
        /// 那样只会在标记补上之前把整注画成全灰，中奖票尤其离谱。
        let hasResult: Bool
        /// 这一注自己印的玩法（`组六` / `组三` / `单选`）。
        ///
        /// 只有**票面逐注印玩法**的彩种才有值。福彩 3D 就是这么打的：
        /// 号码柱前面明明白白印着「组六:」「组三:」，一张票上可以混着来。
        /// 票夹要跟票面长一样，这一栏就必须跟着出现。
        /// 排列3 的组三/组六 是按号码推出来的、票面并没有印，
        /// 所以只在一张票上真的混了两种时才标出来。
        let playLabel: String
    }

    let id: String
    let game: GameKey
    let status: RecordStatus
    let expect: String
    let openDate: String
    let targetStatus: NextDrawStatus
    let multiple: Int
    let entryLabel: String
    /// 玩法：大乐透的追加、快乐8 的选几、3D 的直选组三组六。
    let playLabel: String
    let count: Int
    let cost: Double
    let prize: Double
    let createdAt: Date
    /// 只快照要画的前几注。复式一张票可以到 2000 注，全快照没有意义。
    let lines: [Line]
    /// 复制号码用的全文，同样提前拼好。
    let copyText: String
    /// 已经出结果、但用户还没看过。票夹靠它把「新结果」单独分一区。
    let isNewResult: Bool
    /// 复式 / 胆拖票的**整票选号**。单式票为空。
    ///
    /// 票夹要像实体票那样显示：一排红球里标出胆码，而不是把 100 注号码
    /// 一条条铺开 —— 用户手里就是一张复式票，铺成 100 行既对不上票面，
    /// 也根本看不过来。
    ///
    /// **核对仍然按每一注算**：底下的记录一注都没少，奖金、命中标记
    /// 全都是逐注算出来的，这里只是换个方式显示。
    let whole: [WholeZone]

    /// 整票里的一个号码区。
    struct WholeZone: Identifiable, Hashable {
        let key: SectionKey
        /// 这个区选了哪些号，升序。
        let selected: [Int]
        /// 其中哪些是胆码。复式票为空。
        let dan: Set<Int>
        /// 开出来命中的号。
        let hits: Set<Int>
        var id: String { key.rawValue }
    }

    var netProfit: Double { prize - cost }

    /// 每一注要不要各自标玩法。
    ///
    /// 福彩 3D 永远要：实体票的号码柱前面就印着「组六:」「组三:」，
    /// 票夹里不标就和手里那张纸对不上。其余彩种只在一张票上真的混了
    /// 两种玩法时才标 —— 票头那句「组选单式」已经说清楚的事，
    /// 逐注再写一遍只是噪声。
    static func showsLineModes(_ records: [TicketRecord], game: GameKey) -> Bool {
        let modes = Set(records.map(\.playMode).filter { !$0.isEmpty })
        guard !modes.isEmpty else { return false }
        return game == .fc3d || modes.count > 1
    }

    /// 把历史上各种写法的 `entryLabel` 折成票面用词。
    ///
    /// 老记录里存的可能是录入方式（扫描 / 手选）或者录入页的用词（普通），
    /// 票面上一律叫「单式」。
    static func shapeLabel(_ raw: String, addOn: Bool) -> String {
        switch raw {
        case "复式", "胆拖": return raw
        default: return "单式"
        }
    }

    /// 从展开的每一注反推整票选号。
    ///
    /// 不需要给记录加字段 —— 这些信息本来就藏在注里：
    /// **某个区所有注的并集**就是这个区选的号；**所有注的交集**就是胆码
    /// （胆码按定义出现在每一注里，拖码只出现在一部分注里）。
    /// 复式票没有胆码，交集自然是空的（除非那个区正好选满，
    /// 那它本来也就等于单式，不影响显示）。
    static func wholeZones(_ records: [TicketRecord], game: GameKey) -> [WholeZone] {
        guard records.count > 1 else { return [] }
        var zones: [WholeZone] = []
        for section in game.sections {
            var union: Set<Int> = []
            var intersection: Set<Int>?
            var hits: Set<Int> = []
            for record in records {
                let values = record.ticket[section.key]
                guard !values.isEmpty else { continue }
                union.formUnion(values)
                intersection = intersection.map { $0.intersection(values) } ?? Set(values)
                let flags = record.matched[section.key] ?? []
                for (index, value) in values.enumerated() where index < flags.count && flags[index] {
                    hits.insert(value)
                }
            }
            guard !union.isEmpty else { continue }
            let dan = intersection ?? []
            zones.append(WholeZone(key: section.key,
                                   selected: union.sorted(),
                                   // 整个区都被"交集"覆盖说明这个区是定选的，
                                   // 那不是胆码，是这一区本来就没有可选余地
                                   dan: dan.count == union.count ? [] : dan,
                                   hits: hits))
        }
        // **注数必须正好等于这组选号的展开数**，否则这不是一张复式/胆拖票。
        //
        // 只看「有没有某个区多选了」是不够的：手选两注 1-6 和 7-12，
        // 红球并集是 12 个，同样"多选了"，会被画成一张 12 选 6 的复式 ——
        // 而那其实是两注互不相干的单式。
        // 真正的复式/胆拖，展开数和记录条数必然对得上（7 红复式展开 7 注，
        // 2 胆 5 拖选 4 展开 5 注）；拿两注拼出来的并集展开是 924 注，对不上。
        return combinations(of: zones, game: game) == records.count ? zones : []
    }

    private static func combinations(of zones: [WholeZone], game: GameKey) -> Int {
        var total = 1
        for section in game.sections {
            guard let zone = zones.first(where: { $0.key == section.key }) else { continue }
            // 胆码是定下的，真正要组合的是拖码里挑剩下的那几个位置
            let free = zone.selected.count - zone.dan.count
            let need = section.count - zone.dan.count
            guard need >= 0 else { return 0 }
            total *= TicketBuilder.binomial(free, need)
            if total == 0 { return 0 }
        }
        return total
    }

    /// 快照时最多留几注。收起看 5 注、展开看 50 注，再多也不画。
    static let lineLimit = 50
}

/// 一张电子票 = 同一次购买的一组记录。
/// 一张电子票 = 同一次购买的一组记录。
struct TicketBatch: Identifiable, Hashable {
    let id: String
    let records: [TicketRecord]
    let status: RecordStatus

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
    private static func status(of records: [TicketRecord]) -> RecordStatus {
        if records.contains(where: { $0.status == .won }) { return .won }
        if records.contains(where: { $0.status == .prizeFloat }) { return .prizeFloat }
        if records.allSatisfy({ $0.status == .lost }) { return .lost }
        return .pending
    }

    /// 分组只在记录变化时做一次，结果缓存在视图状态里，不要放进 body。
    static func group(_ records: [TicketRecord]) -> [TicketBatch] {
        var order: [String] = []
        var buckets: [String: [TicketRecord]] = [:]
        for record in records {
            if buckets[record.batchId] == nil { order.append(record.batchId) }
            buckets[record.batchId, default: []].append(record)
        }
        return order.compactMap { key in
            guard let items = buckets[key] else { return nil }
            let sorted = items.sorted { $0.id < $1.id }
            return TicketBatch(id: key, records: sorted, status: status(of: sorted))
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}


extension TicketCard {
    /// 把一批记录抽成渲染快照。只在记录变化时跑一次。
    init(batch: TicketBatch) {
        let records = batch.records
        let first = records.first
        id = batch.id
        game = batch.game
        status = batch.status
        expect = batch.expect
        openDate = batch.openDate
        targetStatus = first?.targetStatus ?? .confirmed
        multiple = batch.multiple
        entryLabel = batch.entryLabel
        // 票面那句话，比如「组选单式」「选八单式」「追加单式」。
        // 玩法取**整张票里所有注**的集合 —— 3D 和排列3 一张票上可以混玩法，
        // 只看第一注会把「组选」说成「组六」。
        playLabel = batch.game.ticketLabel(
            modes: Set(records.map(\.playMode)),
            shape: TicketCard.shapeLabel(batch.entryLabel, addOn: first?.ticket.addOn ?? false)
        )
        count = records.count
        createdAt = batch.createdAt
        // 整张票里只要还有一注的结果没被看过，这张票就还算「新结果」。
        // 已经出结果才谈得上看没看 —— 没开奖的票不该占着新结果那一区。
        isNewResult = batch.status.hasResult && records.contains { $0.resultSeenAt == nil }
        whole = TicketCard.wholeZones(records, game: batch.game)

        var costSum = 0.0
        var prizeSum = 0.0
        for record in records {
            costSum += record.cost
            prizeSum += record.prizeAmount
        }
        cost = costSum
        prize = prizeSum

        let key = batch.game
        let showsLineMode = TicketCard.showsLineModes(records, game: batch.game)
        lines = records.prefix(TicketCard.lineLimit).map { record in
            Line(id: record.id,
                 numbers: record.ticket.numbers.values,
                 matched: record.matched,
                 prizeAmount: record.prizeAmount,
                 status: record.status,
                 hasResult: !record.matched.isEmpty,
                 playLabel: showsLineMode
                     ? batch.game.playLabel(playMode: record.playMode, addOn: record.ticket.addOn)
                     : "")
        }

        // 复制文本同样只取前 `lineLimit` 注。这里是主线程上重建快照的路径，
        // 一张 2000 注的复式票要是全拼出来，正是这次重构想干掉的那种开销 ——
        // 而且没人会去读一份两千行的号码。
        let copyRecords = Array(records.prefix(TicketCard.lineLimit))
        let body = copyRecords.enumerated().map { index, record -> String in
            let numbers = key.sections.compactMap { section -> String? in
                let values = record.ticket[section.key]
                guard !values.isEmpty else { return nil }
                return values.map { String(format: section.range.upperBound > 9 ? "%02d" : "%d", $0) }
                    .joined(separator: " ")
            }.joined(separator: " + ")
            return "\(index + 1). \(numbers)"
        }.joined(separator: "\n")
        let omitted = records.count - copyRecords.count
        copyText = "\(key.label) 第\(batch.expect)期\n\(body)"
            + (omitted > 0 ? "\n…另有 \(omitted) 注未列出" : "")
    }

    /// 票夹的三个分区。
    ///
    /// 老版本只分「待核对 / 已核对」两段，漏掉了中间那个真正要紧的状态：
    /// **已经出结果、但用户还没看过**。结果一落地，票就按开奖日降序插回历史堆里，
    /// 首屏只画 10 张，于是刚核对完的那张常常当场掉出屏幕 ——
    /// 用户打开 App 想看的恰恰就是它。
    enum Zone: Int, CaseIterable {
        /// 出了结果，用户还没看过。**排在最上面** ——
        /// 打开 App 的第一诉求是「昨晚那张中没中」，不是「明天开哪几期」。
        case fresh = 0
        /// 还没开奖 / 还没核对出结果。
        case waiting = 1
        /// 看过了，归档。
        case history = 2

        var title: String {
            switch self {
            case .fresh: "新结果"
            case .waiting: "等开奖"
            case .history: "已看过"
            }
        }
    }

    var zone: Zone {
        guard status.hasResult else { return .waiting }
        return isNewResult ? .fresh : .history
    }

    /// 票夹的排序键。
    ///
    /// 等开奖那一区**开奖日升序** —— 最近就要开的排最上，它是唯一还要人操心的。
    /// 另外两区都是**开奖日降序**，刚出结果的在上。同一天之内按创建时间倒序。
    var sortKey: (group: Int, date: String, created: Date) {
        let day = openDate.isEmpty ? DateText.day(createdAt) : openDate
        return (zone.rawValue, day, createdAt)
    }

    static func orderForWallet(_ cards: [TicketCard]) -> [TicketCard] {
        cards.sorted { lhs, rhs in
            let a = lhs.sortKey, b = rhs.sortKey
            if a.group != b.group { return a.group < b.group }
            if a.date != b.date {
                // 等开奖升序（快开的在上），出了结果的降序（刚开的在上）
                return a.group == Zone.waiting.rawValue ? a.date < b.date : a.date > b.date
            }
            return a.created > b.created
        }
    }

    static func snapshot(_ records: [TicketRecord]) -> [TicketCard] {
        TicketBatch.group(records).map(TicketCard.init(batch:))
    }
}
