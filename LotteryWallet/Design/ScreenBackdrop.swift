import SwiftUI
import UIKit

/// 点开抽屉那一刻的屏幕快照。
///
/// 标签栏右侧独立「扫描」按钮使用系统 `Tab(role:)` 原生分离版式，
/// 点击瞬间系统会短暂切换到该 Tab 再回到原页；放一张 GPU 图层快照填住空档，
/// 既保留 100% 官方液态玻璃标签栏与分离圆钮，又消除弹抽屉前的闪烁。
enum ScreenBackdrop {
    @MainActor
    static func capture() -> UIView? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return nil }
        return window.snapshotView(afterScreenUpdates: false)
    }
}

/// 把 `ScreenBackdrop.capture()` 拿到的快照贴进 SwiftUI。
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
