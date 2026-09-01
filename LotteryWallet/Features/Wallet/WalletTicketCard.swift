import SwiftUI
import SwiftData
import UIKit

/// 一张电子票。收起时只显示前两注，展开显示全部。
///
/// 这里刻意不做任何计算：命中标记、奖级、奖金都是核对时就写进记录的字段，
/// 视图只负责画。早期版本在 body 里对每条记录现算一遍判奖，
/// 列表一长每帧都要跑几百次规则判定。
struct WalletTicketCard: View {
    let batch: TicketBatch
    let isExpanded: Bool
    var onToggle: () -> Void
    var onDelete: () -> Void

    @Environment(DrawStore.self) private var drawStore
    @State private var isDeleteConfirmPresented = false

    private var game: GameKey { batch.game }
    private var draw: Draw? {
        guard let first = batch.first else { return nil }
        return drawStore.draw(for: game, expect: first.targetExpect)
    }

    private var visibleRecords: [TicketRecord] {
        isExpanded ? batch.records : Array(batch.records.prefix(2))
    }

    var body: some View {
        TicketPaper(game: game) {
            VStack(alignment: .leading, spacing: 0) {
                header
                meta
                TicketDivider(tint: game.tint).padding(.top, 10)
                lines
                TicketDivider(tint: game.tint)
                footer
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .contextMenu {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(game.label)
                    .font(.headline)
                Text(issueText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusChip(status: batch.status)
        }
    }

    private var issueText: String {
        var text = batch.expect.isEmpty ? "期号待定" : "第 \(batch.expect) 期"
        if !batch.openDate.isEmpty { text += " · \(DateText.monthDay(batch.openDate)) 开奖" }
        switch batch.first?.targetStatus {
        case .inferred: text += " · 预计"
        case .review: text += " · 待确认"
        default: break
        }
        return text
    }

    private var meta: some View {
        TicketMetaText(items: [
            "\(batch.records.count) 注",
            batch.multiple > 1 ? "\(batch.multiple) 倍" : "",
            batch.entryLabel,
            "投入 \(MoneyText.format(batch.cost))"
        ])
        .padding(.top, 8)
    }

    // MARK: - 号码

    private var lines: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                lineRow(index: index, record: record)
            }
            if !isExpanded && batch.records.count > 2 {
                Text("还有 \(batch.records.count - 2) 注 · 点按展开")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    private func lineRow(index: Int, record: TicketRecord) -> some View {
        let matched = record.matched
        return HStack(spacing: 9) {
            Text("\(index + 1)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 20)

            ScrollView(.horizontal, showsIndicators: false) {
                TicketNumbersView(
                    game: game,
                    ticket: record.ticket,
                    matched: matched,
                    size: 27,
                    dimUnmatched: !matched.isEmpty
                )
            }
            .scrollClipDisabled()

            Spacer(minLength: 0)

            if record.prizeAmount > 0 {
                Text("+\(MoneyText.compact(record.prizeAmount))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.profit)
            } else if record.status == .prizeFloat {
                Text("待公布")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(RecordStatus.prizeFloat.tint)
            }
        }
    }

    // MARK: - 票尾

    private var footer: some View {
        HStack(alignment: .bottom) {
            if let draw {
                VStack(alignment: .leading, spacing: 5) {
                    Text("开奖号码")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        DrawNumbersView(draw: draw, size: 23)
                    }
                    .scrollClipDisabled()
                }
            } else {
                Text("等待开奖")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(batch.status == .pending ? "待核对" : MoneyText.format(batch.netProfit))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(batch.status == .pending ? Color.secondary : Palette.profitColor(batch.netProfit))
                Text("盈亏")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 10)
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
