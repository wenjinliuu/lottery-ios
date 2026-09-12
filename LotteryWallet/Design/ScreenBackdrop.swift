import SwiftUI
import UIKit

/// 点开抽屉那一刻的屏幕快照。
///
/// 为什么需要它：
///
/// 标签栏右边那颗「扫描」借的是 `Tab(role: .search)` 的版式。试过几版之后可以确定 ——
/// 这个角色的选中态**没法在绑定里否决**，点下去的瞬间系统就把那一页切上来了，
/// 过一小会儿才退回去。快照要做的不是"显示背景"，而是**填住那个空档**：
/// 那一页摆着点击前的画面，等系统退回来，背后就是真正在动的页面
/// （中奖卡片的烟花照常在放，这一点已经在真机上确认过）。
///
/// 为什么不用 `UIGraphicsImageRenderer` + `drawHierarchy`：
///
/// 那一对是**软件重绘整棵视图树**，全屏一次要几十毫秒，而它恰好卡在点击到
/// 抽屉升起之间 —— 动画还没开始就先丢几帧，手上的感觉就是"一顿"。
/// `snapshotView` 走的是渲染服务已经有的图层内容，量级差一两个数量级。
enum ScreenBackdrop {
    @MainActor
    static func capture() -> UIView? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return nil }
        // `afterScreenUpdates: false` 要的是**此刻**这一帧。传 true 会先把待处理的
        // 更新提交一遍，而待处理的那一帧里标签栏已经切走了 —— 正是要躲开的东西。
        return window.snapshotView(afterScreenUpdates: false)
    }
}

/// 把 `ScreenBackdrop.capture()` 拿到的那张快照贴进 SwiftUI。
struct ScreenBackdropView: UIViewRepresentable {
    let snapshot: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.addSubview(snapshot)
        snapshot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            snapshot.topAnchor.constraint(equalTo: container.topAnchor),
            snapshot.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            snapshot.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            snapshot.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}


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
