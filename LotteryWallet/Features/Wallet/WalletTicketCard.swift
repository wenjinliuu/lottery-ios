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

    /// 收起时画几注。5 注以内的票**一律全展开** —— 大多数票就是 1–5 注，
    /// 为了它们做一次折叠交互纯属多余，用户还得多点一下才能看全自己的号码。
    private static let collapsedLineLimit = 5
    /// 展开时最多画这么多注。复式一张票可以到 2000 注，
    /// 全画出来就是 2000 行，点开的一瞬间主线程直接停住。
    private static let expandedLineLimit = 50

    private var game: GameKey { batch.game }
    private var draw: Draw? {
        guard let first = batch.first else { return nil }
        return drawStore.draw(for: game, expect: first.targetExpect)
    }

    /// 5 注以内没有「折叠」这个状态，点按也不做任何事。
    private var isCollapsible: Bool { batch.records.count > Self.collapsedLineLimit }

    private var visibleRecords: [TicketRecord] {
        let limit = isExpanded ? Self.expandedLineLimit : Self.collapsedLineLimit
        return Array(batch.records.prefix(limit))
    }

    /// 收起 / 展开状态下没画出来的注数。
    private var hiddenCount: Int {
        Swift.max(batch.records.count - visibleRecords.count, 0)
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
        .onTapGesture { if isCollapsible { onToggle() } }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: isExpanded ? "收起" : "展开") {
            if isCollapsible { onToggle() }
        }
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
            // 只有真的能折叠的票才给箭头。5 注以内的票本来就全展开，
            // 挂个点不动的箭头反而是误导。
            if isCollapsible {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
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
            if hiddenCount > 0 {
                Text(isExpanded
                     ? "另有 \(hiddenCount) 注未显示 · 长按可复制全部号码"
                     : "还有 \(hiddenCount) 注 · 点按展开")
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

            // 不再套横向 ScrollView：号码放不下就自动缩小球径，
            // 一行一个滚动视图既卡又让人以为号码被裁了。
            TicketNumbersView(
                game: game,
                ticket: record.ticket,
                matched: matched,
                size: 27,
                dimUnmatched: !matched.isEmpty
            )

            Spacer(minLength: 0)

            if record.prizeAmount > 0 {
                Text("+\(MoneyText.compactYuan(record.prizeAmount))")
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
                    DrawNumbersView(draw: draw, size: 23)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
