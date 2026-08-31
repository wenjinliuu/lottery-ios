import SwiftUI

/// 一个号码区的选号盘。
/// 1–33 这类球区用网格点选；0–9 的数字型玩法按位选，允许重复。
struct NumberPadSection: View {
    let section: GameSection
    @Binding var selection: SectionSelection
    let mode: EntryMode
    /// 胆拖模式下，当前点选的是胆码还是拖码。
    let danPicking: Bool

    private var isDigitSection: Bool { section.isPositional }

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
        HStack(alignment: .firstTextBaseline) {
            Text(section.label)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(section.color.deep)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("已选 \(selection.selected.count)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var hint: String {
        switch mode {
        case .manual, .random:
            return "选 \(section.count) 个"
        case .system:
            return "至少 \(section.count) 个"
        case .dantuo:
            return danPicking ? "胆码最多 \(section.count - 1) 个" : "拖码，与胆码合计超过 \(section.count) 个"
        }
    }

    // MARK: - 球区

    private var ballGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
            ForEach(Array(section.range), id: \.self) { value in
                let isSelected = selection.selected.contains(value)
                let isDan = selection.dan.contains(value)
                Button {
                    toggle(value)
                } label: {
                    BallView(value: value,
                             color: section.color,
                             size: 38,
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
                            .background(Circle().fill(Color.red))
                            .offset(x: 3, y: -3)
                    }
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: selection)
    }

    private func toggle(_ value: Int) {
        var next = selection
        if mode == .dantuo && danPicking {
            if next.dan.contains(value) {
                next.dan.removeAll { $0 == value }
            } else {
                // 胆码数量必须少于该区所需个数，否则就没有拖码可选了
                guard next.dan.count < section.count - 1 else { return }
                next.dan.append(value)
                if !next.selected.contains(value) { next.selected.append(value) }
            }
        } else if next.selected.contains(value) {
            next.selected.removeAll { $0 == value }
            next.dan.removeAll { $0 == value }
        } else {
            // 普通单式选满就不再加
            if mode == .manual || mode == .random {
                guard next.selected.count < section.count else { return }
            }
            next.selected.append(value)
        }
        next.selected.sort()
        next.dan.sort()
        selection = next
    }

    // MARK: - 数字区

    private var digitPickers: some View {
        HStack(spacing: 10) {
            ForEach(0..<section.count, id: \.self) { index in
                Picker("", selection: digitBinding(index)) {
                    ForEach(Array(section.range), id: \.self) { value in
                        Text(String(value)).tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: 58, height: 96)
                .clipped()
            }
            Spacer(minLength: 0)
        }
    }

    private func digitBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: {
                let values = selection.selected
                return index < values.count ? values[index] : section.range.lowerBound
            },
            set: { newValue in
                var values = selection.selected
                while values.count < section.count { values.append(section.range.lowerBound) }
                values[index] = newValue
                selection.selected = values
            }
        )
    }
}
