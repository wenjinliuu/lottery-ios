import SwiftUI

/// 年月选择面板。年份左右翻，月份一个 3×4 的网格，外加「全年」和「全部」。
/// 首页下面那张概览卡用它选看哪一段。
struct PeriodPicker: View {
    @Binding var year: Int
    @Binding var month: Int?
    /// 「全部」：不限年份。选了它，年和月都不起作用。
    @Binding var isAll: Bool
    let years: [Int]

    @Environment(\.dismiss) private var dismiss

    private var minYear: Int { years.min() ?? year }
    private var maxYear: Int { years.max() ?? year }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                HStack {
                    stepButton("chevron.left", enabled: year > minYear) { year -= 1 }
                    Spacer()
                    Text("\(year) 年")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    stepButton("chevron.right", enabled: year < maxYear) { year += 1 }
                }
                .padding(.horizontal, 4)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(1...12, id: \.self) { item in
                        monthCell("\(item) 月", isOn: !isAll && month == item) { month = item; isAll = false }
                    }
                }

                HStack(spacing: 10) {
                    monthCell("全年", isOn: !isAll && month == nil, wide: true) { month = nil; isAll = false }
                    monthCell("全部", isOn: isAll, wide: true) { isAll = true }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Palette.canvas)
            .navigationTitle("选择统计区间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(360)])
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 40, height: 40)
                .background(Palette.card, in: Circle())
        }
        .buttonStyle(PressableIcon())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func monthCell(_ title: String, isOn: Bool, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isOn ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isOn ? Palette.onAccent : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: wide ? 44 : 40)
                .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Palette.card),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
