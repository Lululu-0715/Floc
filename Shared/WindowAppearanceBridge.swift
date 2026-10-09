import SwiftUI
import UIKit

/// 把外观档位（跟随系统 / 浅色 / 深色）同步到窗口**以及窗口里的每一个
/// 视图控制器**。
///
/// **为什么光有 `.preferredColorScheme` 不够。**
/// 那个修饰符挂在 `WindowGroup` 的根节点上（`App/FlocApp.swift`），而设置页
/// 是从地图页弹出来的 **sheet**。sheet 是独立的呈现上下文，根节点那份偏好
/// 只作用于窗口本身，**不会回灌进一个已经弹出来的 sheet**。用户看到的现象
/// 就是「在设置页里切成深色生效了，再切回浅色回不来，必须退出设置再进」。
///
/// **为什么只写窗口也不够（第一版就是这么挂的）。**
/// 只 `window.overrideUserInterfaceStyle = style` 时，窗口里的普通内容
/// （地图、根视图）确实会跟着变，但**正在显示的 sheet 纹丝不动**：
/// SwiftUI 弹出 sheet 时会给那个视图控制器写一份它自己的
/// `overrideUserInterfaceStyle`，而视图控制器上的设置**优先于窗口**，
/// 所以窗口改完，sheet 仍按自己那份旧的 trait 渲染。
/// 实测：切回浅色后地图变成浅色、设置页还是 `#2C2C2E` 深色卡片。
///
/// 因此这里把**整棵视图控制器树**都写一遍——根控制器、它的子控制器、
/// 以及一路 `presentedViewController`（sheet 就在这条链上）。视图控制器上的
/// 显式设置只影响自己的子树，正好一层层盖住那份陈旧的 trait。
struct WindowAppearanceBridge: UIViewRepresentable {

    let scheme: ColorScheme?

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let style: UIUserInterfaceStyle
        switch scheme {
        case .dark: style = .dark
        case .light: style = .light
        default: style = .unspecified
        }

        // 首帧这个视图还没进窗口层级，`window` 是 nil，推一帧再写。
        DispatchQueue.main.async {
            guard let window = uiView.window else { return }
            let changed = WindowAppearanceBridge.apply(style, in: window)
            guard changed else { return }
            RuntimeLogger.debug("APP", "Appearance", "窗口外观已同步", details: [
                "style": style == .dark ? "dark" : (style == .light ? "light" : "system"),
            ])
        }
    }

    /// 把外观写进窗口与它下面的每一个视图控制器。
    ///
    /// 返回值表示「这次真的改动了什么」，用来避免每帧刷日志——`updateUIView`
    /// 在根视图重算时会反复调用，值没变就不该再动一遍。
    @discardableResult
    static func apply(_ style: UIUserInterfaceStyle, in window: UIWindow) -> Bool {
        var changed = false

        if window.overrideUserInterfaceStyle != style {
            window.overrideUserInterfaceStyle = style
            changed = true
        }

        // 广度优先走一遍：根控制器 → 子控制器 → 被呈现的控制器。
        // sheet 不在 `children` 里，而是在 `presentedViewController` 上，
        // 漏掉这条边就等于没修。
        var queue: [UIViewController] = []
        if let root = window.rootViewController { queue.append(root) }

        while let controller = queue.popLast() {
            if controller.overrideUserInterfaceStyle != style {
                controller.overrideUserInterfaceStyle = style
                changed = true
            }
            queue.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController {
                queue.append(presented)
            }
        }

        return changed
    }
}

extension View {

    /// 在根节点挂一次，外观档位就会同步到窗口（含已弹出的 sheet）。
    func syncingWindowAppearance(_ scheme: ColorScheme?) -> some View {
        background(
            WindowAppearanceBridge(scheme: scheme)
                .allowsHitTesting(false)
        )
    }
}
