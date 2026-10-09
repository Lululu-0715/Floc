import SwiftUI

/// 全应用共用的玻璃外观。
///
/// **这是全工程唯一允许出现 iOS 26 液态玻璃 API（`glassEffect` / `Glass`）的文件。**
/// 两个原因：
///   1. 界面侧只有四个入口（`glassCard` / `mapGlassSurface` / `mapGlassCapsule` /
///      `mapGlassSheet`），散出去就会出现「改一处漏一处」的老问题；
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
/// **`.interactive()` 是「Q 弹」的来源。** 没有它，`.glassEffect` 只是一层
/// 静态的折射材质：手指按下去玻璃一点反应都没有，观感就是「死」的。
/// 加上之后玻璃会跟着按压轻微隆起/回弹（`interactiveSpring` 那一套），
/// 摸起来才像果冻。1.0.10 漏了这一步，用户的原话是「一点都不 Q 弹」。
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

    /// 玻璃是否响应触摸。默认开——本工程的玻璃几乎都是可点元素的底板。
    var interactive: Bool = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    interactive ? Glass.regular.interactive() : Glass.regular,
                    in: shape
                )
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
    /// 所以贴玻璃的那一档在 iOS 26 上不再叠玻璃，改用一层淡色填充 + 一圈
    /// 亮边把可点区域画出来，玻璃感由外层面板负责。iOS 15~18 行为不变。
    var nested: Bool = false

    /// 这一层是不是可点元素的底板。地图页所有浮层都是，所以默认开。
    var interactive: Bool = true

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if nested {
                // 1.0.10 这里只填了一层 `Color.primary.opacity(0.08)`，
                // 在玻璃面板上几乎看不见 —— 按钮看起来"没被点亮"。
                // 现在补上主题色填充与一圈白色亮边，边界才立得住。
                content
                    .background(shape.fill(ThemeStore.shared.innerCapsuleFill))
                    .overlay(
                        // 用 `stroke` 而不是 `strokeBorder`：形状参数是泛型
                        // `S: Shape`，`strokeBorder` 只在 `InsettableShape` 上有。
                        shape.stroke(Color.white.opacity(0.45), lineWidth: 1)
                    )
                    // 见 `mapGlassSurface` 的说明：整块浮层都要挡住触摸。
                    .contentShape(shape)
            } else {
                content
                    .glassEffect(
                        (interactive
                         ? Glass.regular.interactive()
                         : Glass.regular)
                            .tint(ThemeStore.shared.glassTint),
                        in: shape
                    )
                    .contentShape(shape)
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
                .contentShape(shape)
        }
    }
}

/// 贴底 sheet 的形状：**只圆上沿两个角，下沿是直角**。
///
/// 底部的面板要一直铺到屏幕物理下沿（背景从 Home 指示条底下穿过去），
/// 这时候四个角都圆就会在屏幕下方两个角上切出缺口，露出一块地图。
///
/// 为什么不用系统的 `UnevenRoundedRectangle`：那是 iOS 16 才有的 API，
/// 本工程最低支持 15.0（见 `Tests/check_swift_sources.py` 第 9 项）。
struct MapBottomSheetShape: Shape {

    /// 上沿两个角的圆角。下沿恒为直角。
    var topCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        // 半径不能超过可用高度的一半，否则上下两段圆弧会互相穿透。
        let radius = min(max(topCornerRadius, 0), rect.height / 2)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension View {

    /// 套用玻璃卡片外观。
    func glassCard(cornerRadius: CGFloat = GlassMetrics.cardCornerRadius,
                   shadowRadius: CGFloat = 12,
                   interactive: Bool = true) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius,
                                   shadowRadius: shadowRadius,
                                   interactive: interactive))
    }

    /// 地图页浮层统一的玻璃外观。
    ///
    /// 地图上同时存在搜索框、图层切换、底部面板等多个浮层，圆角和材质
    /// 各自写一套很快就会走形（之前就出现过 12 / 14 / 20 混用、材质在
    /// regular 与 ultraThin 之间跳的情况）。统一从这里取。
    ///
    /// **整块浮层都参与命中测试**（modifier 里统一加了 `.contentShape(shape)`）。
    /// 这一条是 1.0.11 补的，用户反馈「点搜索框的 X 点不动、一点就变成地图选点」：
    /// 玻璃本身只用 `.background` 画了个底，**不扩大命中区域**，于是浮层上
    /// 除了真正的控件以外全是"洞"——点偏两三像素就穿透到下面的全屏地图，
    /// 被地图的单击手势当成一次选点。加上 contentShape 之后，
    /// 浮层范围内的空白点击会被浮层吃掉，不再误触地图。
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

    /// 贴底 sheet 的玻璃外观：**只圆上沿两个角**。
    ///
    /// 底部面板用它。和 `mapGlassSurface()` 是同一套材质/描边/投影，
    /// 只是把形状换成 `MapBottomSheetShape` —— 面板要一直铺到屏幕物理下沿，
    /// 下沿再圆就会在屏幕下面两个角切出缺口。
    ///
    /// 面板永远是「直接贴在地图上」的那一层，所以 `nested` 恒为 false。
    func mapGlassSheet(topCornerRadius: CGFloat = GlassMetrics.mapPanelCornerRadius) -> some View {
        modifier(MapGlassSurfaceModifier(
            shape: MapBottomSheetShape(topCornerRadius: topCornerRadius),
            nested: false
        ))
    }

    /// 按下时轻微缩小、松手弹回。
    ///
    /// 这是「Q 弹」的另一半来源：`.glassEffect(.interactive())` 让玻璃有触感，
    /// 但**玻璃背后的内容不会动**。按钮加一层缩放，按下去整块元素跟着
    /// 缩一点点再弹回来，手势才有回馈。
    ///
    /// 刻意不排除老系统：这不是「液态玻璃」的外观，是一次交互反馈，
    /// iOS 15~18 的用户一样受用（用户明确要求「Q 弹」）。
    func glassPressEffect(scale: CGFloat = 0.94) -> some View {
        modifier(GlassPressModifier(scale: scale))
    }
}

/// `glassPressEffect()` 的实现。用 `ButtonStyle` 而不是
/// `simultaneousGesture`：后者会和按钮自身的点击手势抢事件，
/// 长按类按钮（如「实时位置」）尤其容易失灵。
struct GlassPressModifier: ViewModifier {

    var scale: CGFloat

    func body(content: Content) -> some View {
        content.buttonStyle(GlassPressButtonStyle(scale: scale))
    }
}

/// 按下缩放 + 弹性回弹的按钮样式。
struct GlassPressButtonStyle: ButtonStyle {

    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(
                .spring(response: 0.26, dampingFraction: 0.6),
                value: configuration.isPressed
            )
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

    /// 底部面板**上沿两个角**的圆角。下沿两个角是直角（面板贴到屏幕底边，
    /// 圆角会切出缺口）。
    ///
    /// 1.0.12 起面板改成**贴底三面齐平**的 sheet（左/右/下边距全为 0），
    /// 参照 Apple 地图：整块面板压到屏幕边缘，只有上沿是圆的。
    /// 改成 sheet 之后原来那套「面板又宽又高所以要 34」的理由不成立了——
    /// 只有两个角可见，而参考图量下来是 20 上下（约 18pt），正好回到
    /// 地图浮层同一档，四个浮层从此是一个数值。
    static let mapPanelCornerRadius: CGFloat = 20

    /// 地图页浮层的投影半径。比卡片稍小，浮起感够用又不至于发糊。
    static let mapShadowRadius: CGFloat = 10

    /// 地图页浮层在材质之上再压一层的系统底色不透明度。
    ///
    /// 0 就是纯 material（旧版的行为，卫星图上小字会被纹理吃掉），
    /// 1 就是完全实心、没有玻璃感。0.55 是「看得清」和「还像玻璃」的折中。
    ///
    /// 只在 **iOS 15 ~ 18** 这条路径上生效。
    static let mapSurfaceTint: Double = 0.55

    /// iOS 26 液态玻璃的地图浮层染色强度（**未选主题**时用）。
    ///
    /// 语义与 `mapSurfaceTint` 相同（把浮层压实一点、压住卫星图的碎纹理），
    /// 但走的是 `Glass.tint(_:)` 而不是叠一层色块 —— 玻璃本身已经提供了
    /// 折射与高光，压得太狠反而会退回成一块不透明的板。
    /// 所以数值比 `mapSurfaceTint` 小一档。
    static let mapGlassTint: Double = 0.35

    /// 选了彩色主题时，玻璃改用主题首色染色，浓度取这个值。
    ///
    /// 比 `mapGlassTint` 低不少：那 0.35 是拿**系统底色**（白/黑）压的，
    /// 相当于「加厚」；这里是拿一个**饱和色**染，同样数值会直接把玻璃
    /// 变成一块彩色板。0.22 刚好能看出色偏又留得住折射。
    static let themedGlassTint: Double = 0.22

    /// 选了彩色主题时，玻璃面板内部胶囊的填充浓度。
    static let themedCapsuleTint: Double = 0.30

    /// iOS 26 上「贴在玻璃面板里的胶囊」的填充强度（**未选主题**时用）。
    ///
    /// 这一档**不能**再叠一层 `.glassEffect`（嵌套玻璃会被外层吃掉），
    /// 于是退回成一层淡色填充 + 一圈白色亮边。1.0.10 只填了 0.08 的灰、
    /// 没有亮边，结果按钮在玻璃面板上几乎看不出来，用户反馈「点不亮」。
    static let mapCapsuleTint: Double = 0.12
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

    /// 选中态的底色跟着主题走。
    @Environment(\.themeAccent) private var accent

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.7))
                .frame(width: itemSize.width, height: itemSize.height)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? accent : Color.clear)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .glassPressEffect(scale: 0.88)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
