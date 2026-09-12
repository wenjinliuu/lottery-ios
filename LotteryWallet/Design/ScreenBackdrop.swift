import SwiftUI
import UIKit

/// 点开抽屉那一刻的屏幕快照。
///
/// 为什么需要它：
///
/// 标签栏右边那颗「扫描」借的是 `Tab(role: .search)` 的版式。试过两版之后可以
/// 确定 —— **这个角色的选中态是没法在绑定里否决的**。点下去的瞬间系统就把那一页
/// 切上来了，我们在 setter 里怎么写都拦不住（抽屉能弹出，说明 setter 确实跑了；
/// 页面还是切过去了，说明回退被无视了）。
///
/// 那就不跟它较劲：既然那一页一定会显示，就让它和用户点击前看到的画面**一模一样**。
/// 点击的同一帧把屏幕截下来，当作那一页的内容。
///
/// 抽屉本来就是模态的，背景静止才是对的 —— 系统自己的 sheet 也是拿一张静止的
/// 背景在演。而且抽屉面板压住了屏幕下半截，截图里那条标签栏根本露不出来，
/// 不会出现两条标签栏叠在一起。
enum ScreenBackdrop {
    @MainActor
    static func capture() -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            // `afterScreenUpdates: false` 是关键：要的是**此刻**这一帧。
            // 传 true 会先把待处理的更新提交一遍 —— 而待处理的那一帧里，
            // 标签栏已经切到扫描页了，截出来正好是我们要躲开的东西。
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}
