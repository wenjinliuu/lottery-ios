import UIKit

/// 关掉 UIKit 那套「弹出模态时把背后整片染灰」的行为。
///
/// 它本身是个合理的约定（提示背后不可交互），但在我们这里有两个实际毛病：
///
/// 1. **恢复得不跟手。** 手指把抽屉往下拖着关的时候，灰色要等转场彻底结束
///    才褪；点遮罩关就是瞬间恢复。同一个动作两种手感。
/// 2. **有的地方压根恢复不了。** 设置里「外观」那一行，Picker 右侧显示当前
///    选项的那个图标，抽屉关掉之后一直卡在灰色（文字倒是恢复了）。
///
/// 把 tintAdjustmentMode 从 .automatic 改成 .normal，整套染灰就不再发生 ——
/// 没有染灰，自然没有"恢复不了"和"恢复慢"。
enum TintDimming {
    @MainActor
    static func disable() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.tintAdjustmentMode = .normal
            }
        }
    }
}
