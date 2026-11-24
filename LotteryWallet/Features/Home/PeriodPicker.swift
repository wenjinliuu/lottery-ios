import SwiftUI

/// 年月选择面板：年份支持一键切换与左右翻页，点击月份 / 全年 / 全部即刻生效并自动收起，
/// 省去选完再伸手点右上角「完成」的多余步骤。
struct PeriodPicker: View {
    @Binding var year: Int
    @Binding var month: Int?
    /// 「全部」：不限年份。选了它，年和月都不起作用。
    @Binding var isAll: Bool
    let years: [Int]
    var latest: Date? = nil

    @Environment(\.dismiss) private var dismiss

    private var sortedYears: [Int] {
        Array(Set(years + [year])).sorted(by: >)
    }

    private var minYear: Int { sortedYears.min() ?? year }
    private var maxYear: Int { sortedYears.max() ?? year }

    private var latestParts: (year: Int, month: Int)? {
        guard let latest else { return nil }
        let cal = Calendar.chinaCalendar
        return (cal.component(.year, from: latest), cal.component(.month, from: latest))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // 年份步进 + 快速年份切换行
                HStack(spacing: 10) {
                    stepButton("chevron.left", enabled: year > minYear) { year -= 1 }
                    Spacer(minLength: 4)
                    Text("\(year) 年")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer(minLength: 4)
                    stepButton("chevron.right", enabled: year < maxYear) {
                        year += 1
                        if let latestParts, year == latestParts.year, let selected = month {
                            month = min(selected, latestParts.month)
                        }
                    }
                }

                if sortedYears.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        GlassGroup(spacing: 8) {
                            HStack(spacing: 8) {
                                ForEach(sortedYears, id: \.self) { item in
                                    let isSelectedYear = !isAll && year == item
                                    Button {
                                        withAnimation(.snappy(duration: 0.25)) {
                                            year = item
                                            if let latestParts, year == latestParts.year, let selected = month {
                                                month = min(selected, latestParts.month)
                                            }
                                        }
                                    } label: {
                                        Text("\(String(item)) 年")
                                            .font(.caption.weight(.semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(isSelectedYear ? Palette.onAccent : Color.primary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .glassEffect(
                                                isSelectedYear
                                                    ? GlassStyle.prominent(tint: .accentColor, interactive: true)
                                                    : GlassStyle.pill(tint: nil, interactive: true),
                                                in: Capsule()
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .scrollClipDisabled()
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(1...12, id: \.self) { item in
                        let isFuture = latestParts.map { year == $0.year && item > $0.month } ?? false
                        monthCell("\(item) 月", isOn: !isAll && month == item, disabled: isFuture) {
                            month = item
                            isAll = false
                            dismiss()
                        }
                        .disabled(isFuture)
                    }
                }

                HStack(spacing: 10) {
                    monthCell("全年", isOn: !isAll && month == nil, wide: true) {
                        month = nil
                        isAll = false
                        dismiss()
                    }
                    monthCell("全部", isOn: isAll, wide: true) {
                        isAll = true
                        dismiss()
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Palette.canvas)
            .navigationTitle("选择统计区间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let latestParts, isAll || year != latestParts.year || month != latestParts.month {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("回到本月") {
                            year = latestParts.year
                            month = latestParts.month
                            isAll = false
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(sortedYears.count > 1 ? 408 : 368)])
        .presentationBackground(Palette.canvas)
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                .frame(width: 38, height: 38)
                .glassCircle(tint: enabled ? .accentColor : nil, interactive: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func monthCell(_ title: String,
                           isOn: Bool,
                           wide: Bool = false,
                           disabled: Bool = false,
                           action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isOn ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(isOn ? Palette.onAccent : (disabled ? Color.secondary.opacity(0.45) : Color.primary))
                .frame(maxWidth: .infinity)
                .frame(height: wide ? 44 : 40)
                .background {
                    if isOn {
                        shape.fill(Color.accentColor)
                    } else {
                        shape.fill(Palette.card)
                            .overlay(shape.strokeBorder(Palette.cardBorder, lineWidth: 1))
                            .shadow(color: Color.black.opacity(0.035), radius: 4, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
