import SwiftUI

/// 全应用共用的玻璃外观。
///
/// **这是全工程唯一允许出现 iOS 26 液态玻璃 API（`glassEffect` / `Glass`）的文件。**
/// 两个原因：
///   1. 界面侧只有三个入口（`glassCard` / `mapGlassSurface` / `mapGlassCapsule`），
///      散出去就会出现「改一处漏一处」的老问题；
///   2. `Tests/check_swift_sources.py` 第 9 项靠这个不变量做静态守卫 ——
///      任何绕过 `if #available(iOS 26, *)` 直接用玻璃 API 的写法都会被拦下，
///      同时它还会断言 `project.yml` 的 `deploymentTarget` 仍然是 iOS 15.0。
///
/// 分叉点是 `if #available(iOS 26.0, *)`，而不是提高 deploymentTarget：
/// **同一个二进制**在 iOS 26 及以上自动换成液态玻璃、在 iOS 15~18 维持原样。
/// 开关是「编译时用的 SDK」（Xcode 26 自带 iOS 26 SDK），不是运行系统版本。

/// 玻璃质感卡片。
///
/// iOS 26 及以上交给系统的液态玻璃（`.glassEffect`）——边缘高光、背景折射、
/// 深浅色适配全部由系统负责，这里不再自己描边、投影。
///
/// iOS 15 ~ 18 上没有系统级的玻璃材质，用 Material 手工模拟：
///
///   1. `.ultraThinMaterial` 提供底色与背景透射（真实感的来源）
///   2. 一圈 0.5pt 的**白色半透明描边**模拟玻璃边缘的高光反射
///   3. 一层柔和的外投影把卡片从背景里"抬"起来
///
/// 第 2 条最容易被省掉，但恰恰是它让平面材质读起来像一块玻璃而不是
/// 半透明色块，所以固定在 modifier 里，调用方无需重复。
///
/// 用法：
/// ```swift
/// content.glassCard()                       // 默认 16pt 圆角
/// content.glassCard(cornerRadius: 20)       // 胶囊或大圆角容器
/// ```
struct GlassCardModifier: ViewModifier {

    /// 圆角半径。地图上的浮层统一传 `GlassMetrics.mapCornerRadius`。
    var cornerRadius: CGFloat = GlassMetrics.cardCornerRadius

    /// 投影半径。放在地图上时调大一点，浮起感更明显。
    var shadowRadius: CGFloat = 12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(Glass.regular, in: shape)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
                .overlay(
                    shape.stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: shadowRadius, y: 4)
        }
    }
}

/// 地图浮层的玻璃背景。
///
/// 比 `glassCard()` 更不透明。卫星底图的纹理很碎，单靠 `.regularMaterial`
/// 透出来的瓦片细节会把文字吃掉，尤其是小字号的坐标和状态胶囊；
/// 所以在材质之上再压一层半透明的系统底色把内容衬出来。
///
/// 底色用 `systemBackground` 而不是写死白色：浅色模式下压白、
/// 深色模式下压黑，两种外观下都是「更实」的方向。
///
/// iOS 26 及以上走系统液态玻璃，但**保留这层「压底」的意图** ——
/// 用 `Glass.tint(Color(.systemBackground).opacity(...))` 表达，而不是
/// 在玻璃上再叠一层不透明色块（那会把折射和高光完全盖掉）。
/// 形状参数化的版本：圆角矩形和胶囊共用同一套材质、描边与投影。
///
/// 之前只支持圆角矩形，要做胶囊按钮就得再抄一份 modifier——材质或描边
/// 改一处漏一处几乎是必然，所以把形状提到泛型参数上。
struct MapGlassSurfaceModifier<S: Shape>: ViewModifier {

    var shape: S

    /// 这一层是不是**贴在另一块玻璃上**（底部面板里的动作按钮、状态行小圆钮）。
    ///
    /// iOS 26 的液态玻璃不能嵌套：内层会被外层吃掉，表现是按钮的底色整块
    /// 消失——1.0.10 第一版就踩了这个坑，底部面板的主按钮直接变成一片透明。
    /// 所以贴玻璃的那一档在 iOS 26 上不再叠玻璃，改用一层淡色填充把可点区域
    /// 画出来，玻璃感由外层面板负责。iOS 15~18 行为不变。
    var nested: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if nested {
                content
                    .background(shape.fill(Color.primary.opacity(GlassMetrics.mapCapsuleTint)))
            } else {
                content
                    .glassEffect(
                        Glass.regular.tint(
                            Color(.systemBackground).opacity(GlassMetrics.mapGlassTint)
                        ),
                        in: shape
                    )
            }
        } else {
            content
                .background(
                    ZStack {
                        shape.fill(.regularMaterial)
                        shape.fill(Color(.systemBackground).opacity(GlassMetrics.mapSurfaceTint))
                    }
                )
                .overlay(
                    shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: GlassMetrics.mapShadowRadius, y: 4)
        }
    }
}

extension View {

    /// 套用玻璃卡片外观。
    func glassCard(cornerRadius: CGFloat = GlassMetrics.cardCornerRadius,
                   shadowRadius: CGFloat = 12) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, shadowRadius: shadowRadius))
    }

    /// 地图页浮层统一的玻璃外观。
    ///
    /// 地图上同时存在搜索框、图层切换、底部面板等多个浮层，圆角和材质
    /// 各自写一套很快就会走形（之前就出现过 12 / 14 / 20 混用、材质在
    /// regular 与 ultraThin 之间跳的情况）。统一从这里取。
    ///
    /// 用于**直接贴在地图上**的浮层；已经在大玻璃面板内部的元素走
    /// `mapGlassCapsule()`（那一档不能再叠玻璃）。
    func mapGlassSurface(cornerRadius: CGFloat = GlassMetrics.mapCornerRadius) -> some View {
        modifier(MapGlassSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ))
    }

    /// 胶囊版的地图浮层玻璃外观。
    ///
    /// 底部面板里的动作按钮用它：44pt 高的按钮配上 28pt 圆角，肉眼看已经
    /// 接近胶囊，但用 `Capsule` 语义更准，也不必让圆角跟着高度算。
    /// 34×34 的方形套上去就是一个圆，所以状态行里的圆形按钮也复用这套。
    ///
    /// **它只出现在 `mapGlassSurface()` 铺出来的底部面板内部**，所以默认
    /// `nested: true`。要拿它当独立浮层（直接贴在地图上）时传 `false`，
    /// 否则 iOS 26 上会少一层玻璃。
    func mapGlassCapsule(nested: Bool = true) -> some View {
        modifier(MapGlassSurfaceModifier(shape: Capsule(style: .continuous), nested: nested))
    }
}

/// 全应用共用的外观尺寸。
///
/// 集中在一处是为了让「同一个界面里的浮层长得一样」这件事可以被review：
/// 改一个数字，所有浮层一起变。
enum GlassMetrics {

    /// 设置页等卡片类容器的圆角。
    static let cardCornerRadius: CGFloat = 16

    /// 地图页浮层的统一圆角。图层切换、搜索框取这个值。
    static let mapCornerRadius: CGFloat = 20

    /// 底部面板的圆角。
    ///
    /// 比同级浮层大 14pt：面板又宽又高，同样的绝对圆角在它身上看起来明显
    /// 比搜索框、图层切换「方」，两个数值一致反而不像一套东西。
    ///
    /// 左右内边距在 1.0.6 收窄到 6pt 想贴屏幕圆角，但面板和上面那些浮层
    /// 对不齐反而显得"贴边"；1.0.7 把横向改回页面统一的 16pt 之后，
    /// 面板左右两条边与搜索框落在同一条竖线上，34 这一档仍然合适 ——
    /// 面板够宽够高，圆角小了四角会显得尖。
    static let mapPanelCornerRadius: CGFloat = 34

    /// 地图页浮层的投影半径。比卡片稍小，浮起感够用又不至于发糊。
    static let mapShadowRadius: CGFloat = 10

    /// 地图页浮层在材质之上再压一层的系统底色不透明度。
    ///
    /// 0 就是纯 material（旧版的行为，卫星图上小字会被纹理吃掉），
    /// 1 就是完全实心、没有玻璃感。0.55 是「看得清」和「还像玻璃」的折中。
    ///
    /// 只在 **iOS 15 ~ 18** 这条路径上生效。
    static let mapSurfaceTint: Double = 0.55

    /// iOS 26 液态玻璃的地图浮层染色强度。
    ///
    /// 语义与 `mapSurfaceTint` 相同（把浮层压实一点、压住卫星图的碎纹理），
    /// 但走的是 `Glass.tint(_:)` 而不是叠一层色块 —— 玻璃本身已经提供了
    /// 折射与高光，压得太狠反而会退回成一块不透明的板。
    /// 所以数值比 `mapSurfaceTint` 小一档。
    static let mapGlassTint: Double = 0.35

    /// iOS 26 上「贴在玻璃面板里的胶囊」的填充强度。
    ///
    /// 这一档**不能**再叠一层 `.glassEffect`（嵌套玻璃会被外层吃掉），
    /// 于是退回成一层淡色填充。取值对标 iOS 15~18 那套在白色面板上
    /// 呈现出来的浅灰：既画出可点区域，又不至于变成一块实心色块。
    static let mapCapsuleTint: Double = 0.08
}

/// 玻璃胶囊按钮组里的单个按钮。
///
/// 抽出来是因为「选中态填充 + 未选中态留白」这套状态在标准/卫星/混合
/// 三个按钮之间完全一致，写在循环里比复制三遍更不容易走形。
struct GlassSegmentButton: View {

    let systemImage: String
    let accessibilityLabel: String
    let isSelected: Bool
    /// 单个按钮的尺寸。横向排列时用扁一点，纵向排列时用方一点。
    var itemSize: CGSize = CGSize(width: 38, height: 32)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.7))
                .frame(width: itemSize.width, height: itemSize.height)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.blue : Color.clear)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
