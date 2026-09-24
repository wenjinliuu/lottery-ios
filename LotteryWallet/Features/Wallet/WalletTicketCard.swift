import SwiftUI
import UIKit

/// 票夹里的一张票据记录。5 注以内全展开，更多才折叠。
///
/// 这里**只读 `TicketCard` 这个纯值快照**，一个 SwiftData 属性都不碰 ——
/// 号码、命中标记、金额都是分组时算好的。早期版本直接持有托管对象，
/// 每次渲染都要遍历 + 解码，是票夹卡顿的根因。
struct WalletTicketCard: View {
    let card: TicketCard
    let isExpanded: Bool
    var onToggle: () -> Void
    var onDelete: () -> Void
    /// 长按「修改」。打开的是录入页那套完整工作台。
    var onEdit: (() -> Void)? = nil
    /// 这张票绑定期次的开奖号码，同样由外部提前取好。
    var draw: Draw?

    @Environment(ToastCenter.self) private var showToast
    @State private var isDeleteConfirmPresented = false

    /// 收起时画几注。5 注以内的票**一律全展开** —— 大多数票就是 1–5 注，
    /// 为了它们做一次折叠交互纯属多余。
    private static let collapsedLineLimit = 5

    private var game: GameKey { card.game }

    /// 点按能不能展开。
    ///
    /// **复式 / 胆拖一律可展开，跟注数无关。** 这两种票收起时只画整票那两行
    /// 号码，逐注号码只有展开才有 —— 原来的判据只看「注数 > 5」，于是
    /// 双色球 6 红 2 蓝（2 注）、2 胆 5 拖（5 注）、大乐透 1 胆 5 拖（5 注）
    /// 这些常见票型**永远看不到自己那几注号码**，点了也没反应。
    /// 常见胆拖有一半落在这个区间里。
    private var isCollapsible: Bool {
        card.count > Self.collapsedLineLimit || !card.whole.isEmpty
    }

    private var visibleLines: [TicketCard.Line] {
        Array(card.lines.prefix(isExpanded ? TicketCard.lineLimit : Self.collapsedLineLimit))
    }

    private var hiddenCount: Int {
        Swift.max(card.count - visibleLines.count, 0)
    }

    var body: some View {
        TicketPaper(game: game) {
            VStack(alignment: .leading, spacing: 0) {
                header
                meta
                TicketDivider(tint: game.tint).padding(.top, 10)
                // 复式 / 胆拖按整票画；单式仍然一注一行
                if card.whole.isEmpty {
                    lines
                } else if isExpanded {
                    // 展开时两样都给：上面是票面的样子，下面是展开的每一注，
                    // 想逐注核对的人还是找得到。
                    wholeTicket
                    TicketDivider(tint: game.tint)
                    lines
                } else {
                    wholeTicket
                }
                TicketDivider(tint: game.tint)
                footer
                disclaimer
            }
        }
        // 中奖的票自己一直在放小烟花，不用等用户去点。
        // 中奖是几个月才遇上一次的事，它值得一直亮着。
        .overlay {
            if card.status == .won {
                // 负 padding 把画布撑得比卡片大一圈，火星才能越出边缘一点点。
                // 幅度只有十几点，不会糊到隔壁卡片上（卡片间距 12）。
                TicketSparkleOverlay()
                    .padding(-TicketSparkleOverlay.overflow)
            }
        }
        .contentShape(Rectangle())
        // 点按**只负责展开 / 收起**。
        //
        // 这里原来还会放一轮盖住整个屏幕的烟花。问题是中奖的票在票夹里
        // 会一直待着，而展开收起是随手就点的动作 —— 于是每翻一次那张票
        // 就全屏炸一次，第三次之后只剩烦。庆祝该出现在「刚核出中奖」
        // 那一刻（见 `WalletView.check` / 扫描页 / 恢复备份后核对），
        // 那是一次性的、确实值得庆祝的时刻。
        //
        // 卡片自己那层小火星（`TicketSparkleOverlay`）留着：它一直亮着，
        // 只在卡片范围内，不打断任何操作。
        .onTapGesture {
            if isCollapsible { onToggle() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: isExpanded ? "收起" : "展开") {
            if isCollapsible { onToggle() }
        }
        .contextMenu {
            if let onEdit {
                Button("修改", systemImage: "square.and.pencil", action: onEdit)
            }
            Button("复制号码", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = card.copyText
                showToast("号码已复制", symbol: "doc.on.doc", feedback: .success)
            }
            Button("删除这张票", systemImage: "trash", role: .destructive) {
                isDeleteConfirmPresented = true
            }
        }
        .confirmationDialog("删除这张票？", isPresented: $isDeleteConfirmPresented, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("这张票的 \(card.count) 注记录会一起删除，且无法恢复。")
        }
    }

    // MARK: - 票头

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.label)
                    .font(.headline)
                    // 彩种名用彩种色。票面上唯一该带颜色的就是它和描边，
                    // 一列卡片刷下来靠这两处认彩种，比一块底色干净得多。
                    .foregroundStyle(game.accent.accentColor)
                Text(issueText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusChip(status: card.status)
            // 只有真的能折叠的票才给箭头。
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
        var text = card.expect.isEmpty ? "期号待定" : "第 \(card.expect) 期"
        if !card.openDate.isEmpty { text += " · \(DateText.monthDay(card.openDate)) 开奖" }
        switch card.targetStatus {
        case .inferred: text += " · 预计"
        case .review: text += " · 待确认"
        default: break
        }
        return text
    }

    private var meta: some View {
        TicketMetaText(items: [
            "\(card.count) 注",
            card.multiple > 1 ? "\(card.multiple) 倍" : "",
            // playLabel 已经是「组选单式票」这种完整写法，entryLabel 再列一遍就是重复
            card.playLabel,
            "票面金额 \(MoneyText.format(card.cost))"
        ])
        .padding(.top, 8)
    }

    // MARK: - 号码

    /// 复式 / 胆拖按**整票**画，和实体票面一致。
    ///
    /// 一张 7+2 的双色球复式展开是 14 注，票面上却只有两行号码。
    /// 把 14 注一条条铺开，既对不上用户手里那张票，也根本看不过来 ——
    /// 胆拖更夸张，一张票能展开成上百注。
    ///
    /// **只是显示方式变了。** 底下的记录一注都没少，奖金和命中标记
    /// 全都是逐注算出来的，核对精度一点不受影响。
    @ViewBuilder
    private var wholeTicket: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(card.whole) { zone in
                if zone.dan.isEmpty {
                    wholeRow(zone, title: "复", values: zone.selected)
                } else {
                    wholeRow(zone, title: "胆", values: zone.selected.filter { zone.dan.contains($0) })
                    wholeRow(zone, title: "拖", values: zone.selected.filter { !zone.dan.contains($0) })
                }
            }
            wholeSummary
        }
        .padding(.vertical, 10)
    }

    /// 整票底下那行小结。
    ///
    /// 复式 / 胆拖票按整票画，**没有逐注的「+¥X」可看** —— 单式票每一注后面
    /// 都跟着金额，一眼就知道中了哪几注；复式票原来只在票尾给一个净收支，
    /// 用户看到「+¥15」根本不知道那是中了 1 注 20 块还是 3 注各 5 块。
    /// 一张 7+2 的复式展开是 14 注，中了几注是这张票最想知道的事。
    @ViewBuilder
    private var wholeSummary: some View {
        let hits = card.wonCount + card.pendingPrizeCount
        // 用 `Text` 相加而不是 HStack：这一行要能随字号换行，
        // 「中 2 注」和它后面的奖金不能在中间被拆成两段对不上。
        let head = Text("共 \(card.count) 注")
        if card.status.hasResult && hits > 0 {
            // 不要把这个局部量叫 `body` —— 会遮住 View 自己的 `body`。
            let summary = head
                + Text(" · ")
                + Text("中 \(hits) 注").fontWeight(.semibold).foregroundStyle(Palette.profit)
                + prizeText
            summary
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.top, 1)
        } else {
            (head + Text(card.status.hasResult ? " · 均未中奖" : " · 按每一注分别核对"))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.top, 1)
        }
    }

    /// 奖金那一段。中了但金额还没公布的注**单独说** —— 并进奖金里
    /// 会出现「中 3 注 · 奖金 ¥10」这种自相矛盾的话。
    private var prizeText: Text {
        var text = Text("")
        if card.wonCount > 0 {
            text = text + Text(" · ")
                + Text("奖金 \(MoneyText.format(card.prize))")
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.profit)
        }
        if card.pendingPrizeCount > 0 {
            text = text + Text(" · ")
                + Text(card.wonCount > 0 ? "另 \(card.pendingPrizeCount) 注待公布" : "奖金待公布")
                    .foregroundStyle(RecordStatus.prizeFloat.tint)
        }
        return text
    }

    private func wholeRow(_ zone: TicketCard.WholeZone, title: String, values: [Int]) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(TicketPreviewBuilder.prefix(game, zone.key) + title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
                .padding(.top, 4)
            TicketNumbersSnapshotView(
                game: game,
                numbers: [zone.key: values],
                matched: [zone.key: values.map { zone.hits.contains($0) }],
                size: 27,
                dimUnmatched: !zone.hits.isEmpty
            )
            Spacer(minLength: 0)
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(visibleLines.enumerated()), id: \.element.id) { index, line in
                lineRow(index: index, line: line)
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

    private func lineRow(index: Int, line: TicketCard.Line) -> some View {
        HStack(spacing: 9) {
            // 每一注前面是序号，和实体票面一致。
            //
            // 玩法默认标在卡片头部（「组选单式」），逐注不再重复。
            // 但福彩 3D 是例外：它的实体票**就是逐注印玩法**的，
            // 号码柱前面写着「组六:」「组三:」，一张票上可以混着来。
            // 那种票只在头部标就和手里的纸对不上了，所以这一栏跟着出现。
            Text("\(index + 1)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 20)

            if !line.playLabel.isEmpty {
                Text(line.playLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(game.accent.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(game.tint.opacity(0.16), in: Capsule())
                    .fixedSize()
            }

            TicketNumbersSnapshotView(
                game: game,
                numbers: line.numbers,
                matched: line.matched,
                size: 27,
                dimUnmatched: line.hasResult
            )

            Spacer(minLength: 0)

            if line.prizeAmount > 0 {
                Text("+\(MoneyText.compactYuan(line.prizeAmount))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.profit)
            } else if line.status == .prizeFloat {
                Text("待公布")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(RecordStatus.prizeFloat.tint)
            }
        }
    }

    // MARK: - 票尾

    /// 票尾：左边开奖号码，右边收支，一行放完。
    ///
    /// 这里踩过一次坑。最早两列是横排的，开奖号码最后一颗球会被挤到第二行、
    /// 甚至溢出票面 —— 原因是 `BallFlow` 在 `.unspecified` 提案下报的是
    /// **单行摊开的宽度**，HStack 拿这个当理想宽度去和右边那列分配，
    /// 号码列就被压掉一截。当时改成了上下两段，代价是白白多占一行高度。
    ///
    /// 正确的做法是把右边那列 `fixedSize` 掉：它先拿走自己真正需要的宽度，
    /// 剩下的**全部**给号码列，号码列再在这个确定的宽度里排版。
    private var footer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(draw == nil ? "等待开奖" : "开奖号码")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let draw {
                    DrawNumbersView(draw: draw, size: 22)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text("收支")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(card.status == .pending ? "待核对" : MoneyText.format(card.netProfit))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(card.status == .pending ? Color.secondary : Palette.profitColor(card.netProfit))
            }
            .fixedSize()
        }
        .padding(.top, 10)
    }

    /// 每张票底部都要有的一行小字。
    ///
    /// 放在卡片**里面**而不是页面某处：用户截图、分享、或者只是盯着某一张票看的
    /// 时候，这句话都得跟着那张票 —— 兑奖依据是他手里那张纸，不是这里的记录。
    private var disclaimer: some View {
        DisclaimerNote(text: Disclaimer.card)
            .padding(.top, 8)
    }
}
