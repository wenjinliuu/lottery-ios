import SwiftUI

/// 全应用的免责提示文案与样式。
///
/// 集中放在这里，不让每个页面各写各的：这些话是给审核看、也是给用户兜底的，
/// 散在十几处迟早会出现口径不一致 —— 一处说「以官方为准」、另一处说
/// 「本应用保证准确」，那才是真的风险。
///
/// 口径只有三条，反复用的就是这三条：
/// 1. 号码以**用户手里的实体票**为准（识别和录入都可能出错）。
/// 2. 开奖信息与中奖结果以**官方公布**为准。
/// 3. 本应用**不销售、不代购、不兑奖**。
enum Disclaimer {
    /// 票夹卡片底部那一行。最短，因为每张卡片都要出现。
    static let card = "号码以实体票为准，中奖结果以官方兑奖为准"

    /// 扫描入口。用户还没拍照，先把预期摆正：这东西会出错，你得自己核。
    static let scanIntro = "识别结果可能有误，保存前请对照实体票逐注核对。本应用不销售、不代购彩票。"

    /// 裁切页。这一步决定识别成不成，提醒框准一点。
    static let crop = "请把整张票面框进方框内，识别结果仍需您自行核对"

    /// 复核页。这是最后一道关口，措辞要最重。
    static let review = "以下号码由本机识别得出，可能与票面不符。请逐注核对后再保存 —— 保存后的记录仅供个人查询，兑奖一律以实体票和官方结果为准。"

    /// 手动录入。
    static let entry = "请按实体票面如实录入。本应用不销售、不代购彩票，记录仅供个人核对使用。"

    /// 首页开奖号码下方那一行（原来就有，收编进来统一管理）。
    static let draw = "开奖信息仅供参考，请以官方公布为准"
}

/// 卡片、页脚里那种一行小字的免责提示。
struct DisclaimerNote: View {
    let text: String
    var icon: String?
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            Text(text)
                .font(.system(size: 10))
                .multilineTextAlignment(alignment == .center ? .center : .leading)
            if alignment == .center { Spacer(minLength: 0) }
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 录入流程里那种需要被看见的提示块 —— 比一行小字重，但不抢主操作。
struct DisclaimerBanner: View {
    let text: String
    var icon: String = "exclamationmark.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.warning)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
