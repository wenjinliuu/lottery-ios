import SwiftUI
import UIKit

/// 改一注号码。**录入页、扫描复核页、票夹修改三处共用这一个。**
///
/// ## 为什么必须是同一个
///
/// 「改一注号码」在这三个地方是完全相同的一件事：按玩法选够号、选够了才能
/// 落下。上一版它只在扫描页有一份实现，而那份实现把「要选几个」写成了
/// `section.count` —— 快乐8 选五的票让用户去点 20 个号，选够 5 个之后
/// 「完成」还是灰的，整张票改不动。
///
/// 那个错误之所以能活下来，是因为八个彩种里只有快乐8 的
/// `section.count` 和实际要选的个数不一样，另外七个碰巧都对。分散成三份
/// 实现，就是三次犯同一个错的机会。
///
/// ## 要选几个，只有一个答案
///
/// `GameKey.pickCount(for:playMode:)`。这个视图自己不做任何推断 ——
/// 玩法由调用方给，个数由那个函数算。
struct TicketLineEditor: View {
    let game: GameKey
    /// 决定每个号码区选几个。快乐8 的「选五」「选八」差别全在这里。
    let playMode: String
    let title: String
    /// 票面参照图。改号的时候人是**盯着票面**在核对的，
    /// 让他翻回上一页看图再改是最容易改错的做法。录入页没有图。
    var image: UIImage?
    /// 允许某一位停在「没认出来」（问号）上。只有扫描复核页会打开。
    var allowsUnknown: Bool = false
    /// 进来时这一注是什么。
    let initial: NumberSet
    let onCancel: () -> Void
    let onDone: (NumberSet) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var showToast
    @State private var selections: [SectionKey: SectionSelection] = [:]

    private func required(_ section: GameSection) -> Int {
        game.pickCount(for: section, playMode: playMode)
    }

    /// 选够了没有。
    ///
    /// 两个条件缺一不可：**个数按玩法算**，而且**不能有问号**。
    /// 光数个数不够 —— 识别出来的那一注位数本来就是齐的，只是其中某一位
    /// 是问号，不查这个用户一路点「完成」就把 −1 存进去了。
    private var isComplete: Bool {
        game.sections.allSatisfy { section in
            let values = selections[section.key]?.selected ?? []
            return values.count == required(section) && !values.contains { $0 < 0 }
        }
    }

    /// 还差什么。灰着的「完成」必须说得出理由 —— 上一版就是因为它不说话，
    /// 用户只能以为按钮坏了。
    private var blockingReason: String? {
        for section in game.sections {
            let values = selections[section.key]?.selected ?? []
            let need = required(section)
            if values.contains(where: { $0 < 0 }) {
                return "\(section.label)还有没认出来的位，补齐才能完成"
            }
            if values.count < need {
                return "\(section.label)还差 \(need - values.count) 个号"
            }
            if values.count > need {
                return "\(section.label)选多了，只要 \(need) 个"
            }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if image != nil {
                    TicketReferenceImage(image: image, expands: true)
                        .frame(maxHeight: .infinity)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(game.sections) { section in
                            NumberPadSection(section: section,
                                             selection: binding(for: section.key),
                                             required: required(section),
                                             mode: .manual,
                                             danPicking: false,
                                             allowsUnknown: allowsUnknown,
                                             onReject: { showToast($0, symbol: "hand.raised", feedback: .warning) })
                        }
                    }
                    .contentCard()
                }
                // 有图的时候号码盘先拿走它要的高度，剩下的全给图；
                // 没图的时候号码盘自己铺满。
                .layoutPriority(image == nil ? 0 : 1)
                .frame(maxHeight: image == nil ? .infinity : nil)

                if let blockingReason {
                    Text(blockingReason)
                        .font(.caption)
                        .foregroundStyle(Palette.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        var numbers = NumberSet()
                        for section in game.sections {
                            let values = selections[section.key]?.selected ?? []
                            // 数字型玩法按位，顺序就是号码本身，不能排序。
                            numbers[section.key] = section.isPositional ? values : values.sorted()
                        }
                        onDone(numbers)
                        dismiss()
                    }
                    .disabled(!isComplete)
                }
            }
            .onAppear { load() }
        }
    }

    private func load() {
        var next: [SectionKey: SectionSelection] = [:]
        for section in game.sections {
            var values = initial[section.key]
            // 数字型玩法的滚轮**永远显示着一个值**，所以位数必须先补齐，
            // 否则界面上明明写着 0 0 0，`isComplete` 却说还差三位。
            if section.isPositional {
                let filler = allowsUnknown ? NumberSet.unknown : section.range.lowerBound
                while values.count < required(section) { values.append(filler) }
                values = Array(values.prefix(required(section)))
            }
            next[section.key] = SectionSelection(selected: values)
        }
        selections = next
    }

    private func binding(for key: SectionKey) -> Binding<SectionSelection> {
        Binding(get: { selections[key] ?? SectionSelection() },
                set: { selections[key] = $0 })
    }
}

/// 改号页面顶上的票面参照图。可捏合放大 —— 要核对的就是那几行小字。
///
/// 原来是扫描页的私有类型。逐注编辑器三处共用之后跟着挪到这里，
/// **一个字都没改** —— 它本来就是对的，重写一遍只会把细节写丢。
struct TicketReferenceImage: View {
    var image: UIImage?
    /// 是否吃掉版面上剩下的全部高度。
    ///
    /// 改号的时候人是**盯着票面**在改的，图越大越好认。号码盘的高度是定死的
    /// （几行球就是几行），所以正确的分法是：号码盘贴底、按自己需要的高度占位，
    /// 剩下多少全给图 —— 而不是给图一个 210 的死高度、底下空一大片。
    var expands = false
    @State private var isZoomPresented = false

    var body: some View {
        if let image {
            Button { isZoomPresented = true } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: expands ? .infinity : 210)
                    Label("放大", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(8)
                }
                .frame(maxWidth: .infinity)
                .background(Palette.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.separator))
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $isZoomPresented) {
                PhotoZoomView(image: image)
            }
        }
    }
}
