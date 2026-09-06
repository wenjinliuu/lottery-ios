import SwiftUI

/// 一个号码区的选号盘。
/// 1–33 这类球区用网格点选；0–9 的数字型玩法按位选，允许重复。
struct NumberPadSection: View {
    let section: GameSection
    @Binding var selection: SectionSelection
    /// 这个号码区实际要选几个号。快乐8 由玩法决定，不等于 `section.count`。
    let required: Int
    let mode: EntryMode
    /// 胆拖模式下，当前点选的是胆码还是拖码。
    let danPicking: Bool

    private var isDigitSection: Bool { section.isPositional }

    /// 球的直径。跟着动态字体一起放大，字号调大时球不会把数字挤掉。
    @ScaledMetric(relativeTo: .body) private var ballSize: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isDigitSection {
                digitPickers
            } else {
                ballGrid
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(section.label)
                .font(.subheadline.weight(.bold))
                // 彩种色当文字用必须走自适应色：深色模式下 deep 端压在近黑底上只有 2.8:1
                .foregroundStyle(section.color.accentColor)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text("已选 \(selection.selected.count)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(selection.selected.count == required ? section.color.accentColor : .secondary)
        }
    }

    private var hint: String {
        switch mode {
        case .manual, .random:
            return "选 \(required) 个"
        case .system:
            return "至少 \(required) 个"
        case .dantuo:
            // 胆码要留出至少一个拖码的位置；拖码和胆码合计够 required 个才能展开
            guard danPicking else { return "拖码，与胆码合计至少 \(required) 个" }
            // 只选一个号的区（双色球蓝球）留不出拖码，本来就不支持胆码，
            // 别再显示"胆码最多 0 个"这种看不懂的提示
            return required > 1 ? "胆码最多 \(required - 1) 个" : "该区不设胆码"
        }
    }

    // MARK: - 球区

    /// 自适应列数。
    ///
    /// 原来写死 7 列 + 固定 38pt 的球：在 375pt 宽的机器上一行要 314pt，
    /// 而卡片里只剩 279pt，球会被挤出格子互相压在一起（快乐8 的 1–80 最明显）。
    /// 改成 adaptive 之后由系统按可用宽度决定放几列，永远不会溢出。
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: ballSize, maximum: ballSize + 8), spacing: 8, alignment: .center)]
    }

    private var ballGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(section.range), id: \.self) { value in
                let isSelected = selection.selected.contains(value)
                let isDan = selection.dan.contains(value)
                Button {
                    toggle(value)
                } label: {
                    BallView(value: value,
                             color: section.color,
                             size: ballSize,
                             isHit: isDan,
                             isHollow: !isSelected,
                             padded: section.range.upperBound > 9)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    if isDan {
                        Text("胆")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.white)
                            .padding(2)
                            .background(Circle().fill(Palette.danger))
                            .offset(x: 3, y: -3)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(Text(isDan ? "\(value) 胆码" : "\(value)"))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func toggle(_ value: Int) {
        var next = selection
        if mode == .dantuo && danPicking {
            if next.dan.contains(value) {
                next.dan.removeAll { $0 == value }
            } else {
                // 胆码数量必须少于该区所需个数，否则就没有拖码可选了
                guard next.dan.count < required - 1 else { return }
                next.dan.append(value)
                if !next.selected.contains(value) { next.selected.append(value) }
            }
        } else if next.selected.contains(value) {
            next.selected.removeAll { $0 == value }
            next.dan.removeAll { $0 == value }
        } else {
            // 普通单式选满就不再加
            if mode == .manual || mode == .random {
                guard next.selected.count < required else { return }
            }
            next.selected.append(value)
        }
        next.selected.sort()
        next.dan.sort()
        selection = next
    }

    // MARK: - 数字区

    /// 按位滚轮。
    ///
    /// 宽度必须等分：写死 58pt 时，排列5（5 位）要 330pt、七星彩前六位要 398pt，
    /// 都超过卡片里可用的宽度，右边几位直接被裁掉点不到。
    private var digitPickers: some View {
        HStack(spacing: 6) {
            ForEach(0..<required, id: \.self) { index in
                Picker("第 \(index + 1) 位", selection: digitBinding(index)) {
                    ForEach(Array(section.range), id: \.self) { value in
                        Text(String(value)).tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .clipped()
                .accessibilityLabel("第 \(index + 1) 位")
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func digitBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: {
                let values = selection.selected
                return index < values.count ? values[index] : section.range.lowerBound
            },
            set: { newValue in
                var values = selection.selected
                while values.count < required { values.append(section.range.lowerBound) }
                values[index] = newValue
                selection.selected = Array(values.prefix(required))
            }
        )
    }
}
