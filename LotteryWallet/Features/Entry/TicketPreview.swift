import SwiftUI

/// 录入页底部的整票预览。
///
/// 复式和胆拖**不能**按展开后的单注一注一注地画 —— 一张 7+2 的双色球复式
/// 展开是 14 注，真实票面上却只有两行号码。所以预览按票面的样子来：
/// 每个号码区一行，行首是票面上那个标签（红单／红复／红胆／红拖／前区胆…），
/// 注数和金额在后台照常按展开结果算。
struct TicketPreview {
    /// 一行里的一段号码。复式胆拖每行只有一段（红复、前区拖…），
    /// 手选一行是一整注，红球和蓝球是两段。
    struct Group: Identifiable {
        let id = UUID()
        let color: BallColor
        let values: [Int]
        var padded: Bool = true
    }

    struct Row: Identifiable {
        let id: Int
        let label: String
        let color: BallColor
        let values: [Int]
        var padded: Bool = true
        /// 为空时用 `color` + `values` 画单段，否则画多段。
        var groups: [Group] = []

        var isEmpty: Bool { groups.isEmpty ? values.isEmpty : groups.allSatisfy { $0.values.isEmpty } }
    }

    /// 票面右上角那句玩法，例如「双色球-复式」「大乐透-胆拖」。
    let title: String
    let rows: [Row]

    var isEmpty: Bool { rows.allSatisfy(\.isEmpty) }
}

enum TicketPreviewBuilder {
    /// 票面上号码区的中文前缀。只有双色球和大乐透支持复式胆拖，
    /// 所以这里只需要覆盖这两个。
    private static func prefix(_ game: GameKey, _ key: SectionKey) -> String {
        switch (game, key) {
        case (.ssq, .red): "红"
        case (.ssq, .blue): "蓝"
        case (.dlt, .front): "前区"
        case (.dlt, .back): "后区"
        default: ""
        }
    }

    /// 大乐透票面只写「前区 / 后区」，不标单复；双色球才写「红单 / 红复」。
    private static func marksSingleOrMultiple(_ game: GameKey) -> Bool { game == .ssq }

    // MARK: - 复式 / 胆拖

    static func make(game: GameKey,
                     mode: EntryMode,
                     playMode: String,
                     selections: [SectionKey: SectionSelection]) -> TicketPreview {
        var rows: [TicketPreview.Row] = []
        var names: [String] = []

        for section in game.sections {
            let selection = selections[section.key] ?? SectionSelection()
            let need = game.pickCount(for: section, playMode: playMode)
            let base = prefix(game, section.key).isEmpty ? section.label : prefix(game, section.key)
            let padded = section.range.upperBound > 9

            // 只选一个号的区（双色球蓝球）留不出拖码，票面上永远写「蓝单／蓝复」。
            if mode == .dantuo, need > 1 {
                rows.append(.init(id: rows.count, label: base + "胆", color: section.color,
                                  values: selection.dan.sorted(), padded: padded))
                rows.append(.init(id: rows.count, label: base + "拖", color: section.color,
                                  values: selection.tuo.sorted(), padded: padded))
                names.append(base + "胆拖")
            } else {
                let isMultiple = selection.selected.count > need
                let suffix = marksSingleOrMultiple(game) ? (isMultiple ? "复" : "单") : ""
                rows.append(.init(id: rows.count, label: base + suffix, color: section.color,
                                  values: selection.selected.sorted(), padded: padded))
                names.append(base + suffix)
            }
        }

        let title: String
        switch mode {
        case .dantuo: title = "\(game.label)-胆拖"
        case .system: title = "\(game.label)-复式"
        case .manual: title = "\(game.label)-单式"
        }
        // 双色球票面会把「红单蓝复」这种组合名印出来，大乐透不印。
        let combined = marksSingleOrMultiple(game) ? names.joined() : ""
        return TicketPreview(title: combined.isEmpty ? title : "\(title) · \(combined)", rows: rows)
    }

    // MARK: - 手选多注

    /// 手选攒下来的候选注：一行一注，行首是注序号，和真实的单式票一致。
    ///
    /// 一注里的多个号码区（红球+蓝球、前区+后区）画在**同一行**，
    /// 中间靠 `BallFlow` 的区间隙分开 —— 票面上就是这么印的。
    static func make(game: GameKey, lines: [NumberSet]) -> TicketPreview {
        let rows = lines.enumerated().map { index, numbers in
            TicketPreview.Row(id: index,
                              label: "\(index + 1).",
                              color: game.accent,
                              values: [],
                              padded: true,
                              groups: game.sections.compactMap { section in
                                  let values = numbers[section.key]
                                  guard !values.isEmpty else { return nil }
                                  return TicketPreview.Group(color: section.color,
                                                             values: section.isPositional ? values : values.sorted(),
                                                             padded: section.range.upperBound > 9)
                              })
        }
        return TicketPreview(title: "\(game.label)-单式 · \(lines.count) 注", rows: rows)
    }
}

/// 整票预览卡片。
struct TicketPreviewCard: View {
    let game: GameKey
    let preview: TicketPreview
    let count: Int
    let cost: Double
    var multiple: Int = 1
    /// 前几注是真正加进候选的、可以删。末尾那条可能是「当前选号」，
    /// 它还不在候选里，给它一个减号只会点了没反应。
    var removableCount: Int = 0
    /// 手选模式下逐注删除。
    var onRemoveLine: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TicketDivider(tint: game.tint).padding(.vertical, 10)
            rows
            TicketDivider(tint: game.tint).padding(.vertical, 10)
            footer
        }
        .contentCard()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(preview.title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(game.accent.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            Text("预览")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(preview.rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.label)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        // 标签宽度对齐：「前区拖」三个字最宽，按它定死，
                        // 号码球才会在各行左对齐，看起来才像一张票。
                        .frame(width: 42, alignment: .leading)
                        .padding(.top, 3)
                    if row.isEmpty {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 3)
                    } else if row.groups.isEmpty {
                        BallRowView(values: row.values, color: row.color, size: 26, padded: row.padded)
                    } else {
                        // 一整注：红球和蓝球排在同一行，中间留一段区间隙
                        HStack(alignment: .top, spacing: 7) {
                            ForEach(row.groups) { group in
                                BallRowView(values: group.values, color: group.color,
                                            size: 26, padded: group.padded)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if let onRemoveLine, let index = lineIndex(of: row) {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { onRemoveLine(index) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除第 \(index + 1) 注")
                    }
                }
            }
        }
    }

    /// 手选预览里行首是「3.」这样的注序号，从它反推是第几注。
    private func lineIndex(of row: TicketPreview.Row) -> Int? {
        guard row.label.hasSuffix("."), let number = Int(row.label.dropLast()) else { return nil }
        let index = number - 1
        return index < removableCount ? index : nil
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(count) 注")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
            if multiple > 1 {
                Text("× \(multiple) 倍")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(MoneyText.format(cost))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(game.accent.accentColor)
        }
    }
}
