import SwiftUI
import SwiftData
import UIKit

/// 一张电子票。收起时只显示前两注，展开显示全部并带逐球命中高亮。
struct WalletTicketCard: View {
    let batch: TicketBatch
    let isExpanded: Bool
    var onToggle: () -> Void
    var onDelete: () -> Void

    @Environment(DrawStore.self) private var drawStore
    @Environment(\.modelContext) private var context
    @State private var isDeleteConfirmPresented = false

    private var game: GameKey { batch.game }
    private var draw: Draw? {
        batch.first.flatMap { drawStore.draw(matching: $0) }
    }

    private var visibleRecords: [TicketRecord] {
        isExpanded ? batch.records : Array(batch.records.prefix(2))
    }

    var body: some View {
        TicketPaper(game: game) {
            VStack(alignment: .leading, spacing: 0) {
                header
                meta
                TicketDivider(tint: game.tint)
                    .padding(.top, 11)
                lines
                TicketDivider(tint: game.tint)
                footer
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .contextMenu {
            Button("展开/收起", systemImage: "rectangle.expand.vertical", action: onToggle)
            Button("复制号码", systemImage: "doc.on.doc") { copyNumbers() }
            Button("删除这张票", systemImage: "trash", role: .destructive) {
                isDeleteConfirmPresented = true
            }
        }
        .confirmationDialog("删除这张票？", isPresented: $isDeleteConfirmPresented, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("这张票的 \(batch.records.count) 注记录会一起删除，且无法恢复。")
        }
    }

    // MARK: - 票头

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(game.label)
                    .font(.title3.weight(.heavy))
                Text(issueText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusChip(status: batch.status)
        }
    }

    private var issueText: String {
        var text = batch.expect.isEmpty ? "期号待定" : "第 \(batch.expect) 期"
        if !batch.openDate.isEmpty { text += " · \(DateText.monthDay(batch.openDate)) 开奖" }
        if batch.first?.targetStatus == .inferred { text += " · 预计" }
        if batch.first?.targetStatus == .review { text += " · 待确认" }
        return text
    }

    private var meta: some View {
        TicketMetaText(items: [
            "\(batch.records.count) 注",
            batch.multiple > 1 ? "\(batch.multiple) 倍" : "",
            batch.entryLabel,
            "投入 \(MoneyText.format(batch.cost))",
            DateText.friendly(DateText.day(batch.createdAt))
        ])
        .padding(.top, 11)
    }

    // MARK: - 号码

    private var lines: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                lineRow(index: index, record: record)
            }
            if !isExpanded && batch.records.count > 2 {
                Text("还有 \(batch.records.count - 2) 注 · 点按展开")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    private func lineRow(index: Int, record: TicketRecord) -> some View {
        let outcome = matchResult(for: record)
        return HStack(alignment: .center, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 23, height: 23)
                .background(Circle().fill(game.tint.opacity(0.10)))

            ScrollView(.horizontal, showsIndicators: false) {
                TicketNumbersView(
                    game: game,
                    ticket: record.ticket,
                    matched: outcome,
                    size: 28,
                    dimUnmatched: !outcome.isEmpty
                )
            }
            .scrollClipDisabled()

            Spacer(minLength: 0)

            if record.prizeAmount > 0 {
                Text("+\(MoneyText.compact(record.prizeAmount))")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.profit)
            } else if record.status == .prizeFloat {
                Text("待公布")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RecordStatus.prizeFloat.tint)
            }
        }
    }

    /// 只有开奖后才做逐球高亮，未开奖保持素色。
    private func matchResult(for record: TicketRecord) -> [SectionKey: [Bool]] {
        guard isExpanded || record.status.isFinal, let draw else { return [:] }
        return PrizeRules.evaluate(gameKey: game, ticket: record.ticket, draw: draw, multiple: record.multiple).matched
    }

    // MARK: - 票尾

    private var footer: some View {
        HStack {
            if let draw {
                VStack(alignment: .leading, spacing: 5) {
                    Text("开奖号码")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        DrawNumbersView(draw: draw, size: 24)
                    }
                    .scrollClipDisabled()
                }
            } else {
                Text("等待开奖")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(batch.status == .pending ? "待核对" : MoneyText.format(batch.netProfit))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(batch.status == .pending ? Color.secondary : Palette.profitColor(batch.netProfit))
                Text("盈亏")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
    }

    private func copyNumbers() {
        let text = batch.records.enumerated().map { index, record in
            let numbers = game.sections.compactMap { section -> String? in
                let values = record.ticket[section.key]
                guard !values.isEmpty else { return nil }
                return values.map { String(format: section.range.upperBound > 9 ? "%02d" : "%d", $0) }
                    .joined(separator: " ")
            }.joined(separator: " + ")
            return "\(index + 1). \(numbers)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = "\(game.label) 第\(batch.expect)期\n\(text)"
    }
}
