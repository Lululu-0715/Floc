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
/// 用途是「面板要一直铺到屏幕物理下沿」那一类贴底 sheet（背景从 Home
/// 指示条底下穿过去）：这时四个角都圆就会在屏幕下方两个角上切出缺口，
/// 露出一块地图。
///
/// **1.0.13 起底部卡片改成四周留边 12pt 的悬浮卡片，改用标准的
/// `RoundedRectangle`，这里暂时没有调用点** —— 和 `mapGlassSheet()` 一起留着，
/// 见那边的说明。
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
    /// 1.0.12 的底部面板用它。1.0.13 起面板改成**四周留边 12pt、四角全圆**
    /// 的悬浮大卡片（走 `mapGlassSurface(cornerRadius: mapPanelCornerRadius)`），
    /// 所以**目前没有调用点** —— 留着是因为它和 `MapBottomSheetShape` 是一对
    /// 完整的形状实现，将来真要做贴底 sheet（比如可拖拽的面板）直接拿来用，
    /// 不必再写一遍「上圆下方」的路径与材质。
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
///
/// ## 圆角：六个固定档 + 一个跟着屏幕走的派生值
///
/// 收敛前全项目散着 11 个数值（4 / 9 / 10 / 12 / 13 / 14 / 15.5 / 16 / 18 / 20 / 28），
/// 相邻两档差 1~2pt，肉眼分不出、代码里却在「改一处漏一处」。
/// 1.0.12 按**语义**收敛成四档；1.0.13 为地图页改版与设置 Sheet 补到七档；
/// **1.0.14 把最后一档（地图底部大卡片）从固定值改成派生值** —— 它要跟
/// **屏幕圆角**同心，而屏幕圆角是逐机型不同的（见 `ScreenCornerRadius`），
/// 写死一个数只在一台机器上是对的。界面侧一律引用常量，**不再写裸数字**
/// （`Tests/check_swift_sources.py` 的第 10 项静态检查会拦住）。
///
/// | 档位 | 值 | 收编的旧值 / 用在哪 |
/// |------|-----|--------------------|
/// | `inlineCornerRadius` | 10 | 4 / 9 / 10 —— 标签、色板、图标底、徽标 |
/// | `cardCornerRadius` | 16 | 12 / 13 / 14 / 15.5 / 16 / 18 —— 卡片、分组容器、玻璃卡片 |
/// | `menuCornerRadius` | 18 | 新增 —— 图层菜单、弹出式菜单 |
/// | `mapCornerRadius` | 20 | 20 —— 地图**小浮层**（搜索框、图层切换、悬浮按钮） |
/// | `buttonCornerRadius` | 23 | 新增 —— 主按钮胶囊（46pt 高按钮的半高） |
/// | `heroCornerRadius` | 28 | 28 —— 欢迎页大图标等 hero 容器 |
///
/// 派生值只有一个：`mapPanelCornerRadius`（地图底部大卡片）=
/// **屏幕圆角 − `mapPanelEdgeInset`**。它之所以不能是固定档，是因为
/// 「同心」这个约束的另一半在**屏幕**手上 —— 16 Pro Max 是 62、15/16 是 55、
/// XR 是 41.5，同一个数字不可能跟所有屏幕都同心。
///
/// `mapCornerRadius` 与 `mapPanelCornerRadius` **不是一回事**，不许合并：
/// `mapCornerRadius` 是浮在地图上的一小块（边距小，圆角也小），
/// `mapPanelCornerRadius` 是左右贴屏幕边的大面（半径要跟屏幕圆角同心）。
///
/// 档位管的是「这一块自己该多圆」；**嵌套**的元素不该各挑一档，而要走
/// `concentric(outer:inset:)` —— 内层圆角 = 外层圆角 − 间距，两条弧才同心。
///
/// 胶囊类（`Capsule()` / `mapGlassCapsule()`）的圆角等于自身高度的一半，
/// 由系统算，通常不进这套档位；`buttonCornerRadius` 是唯一的例外 ——
/// 它写死的 23 就是「46pt 主按钮」的半高，用常量是为了给这个隐含依赖
/// 一个名字（按钮改高度，这里跟着改）。
enum GlassMetrics {

    /// **第 1 档**：内联小元素——标签底色、主题色板、36pt 图标底、日志级别徽标。
    ///
    /// 收编了原来的 4（日志徽标）/ 9（色板、图标底）/ 10（色块）。
    /// 这几处元素本身高度就只有 14~36pt，圆角差个 1~2pt 完全看不出来，
    /// 但多一个数值就多一处要同步。
    static let inlineCornerRadius: CGFloat = 10

    /// **第 2 档**：卡片类容器——引导步骤卡片、设置页分组、`glassCard()` 默认值。
    ///
    /// 收编了原来的 12 / 13 / 14 / 15.5 / 16 / 18。
    /// 取 16 而不是 14 或 18，是因为 16 正好夹在中间：玻璃卡片本来就 16
    /// **一处都不用动**，而 14 只是往圆的方向挪 2pt、18 往方 2pt，
    /// 两边视觉位移都最小。
    static let cardCornerRadius: CGFloat = 16

    /// **第 3 档**：图层菜单、弹出式菜单这类「从某个按钮上长出来」的浮层。
    ///
    /// 夹在卡片（16）和地图小浮层（20）之间：比卡片圆一点才好跟卡片区分，
    /// 又比浮层方一点，不至于像颗药丸。
    static let menuCornerRadius: CGFloat = 18

    /// **第 4 档**：地图页**小浮层**的统一圆角 —— 图层切换、搜索框、悬浮按钮。
    ///
    /// 别跟 `mapPanelCornerRadius`（地图底部大卡片，= 屏幕圆角 − 12）搞混：
    /// 这一档是浮在地图上的**小块**，四周留了边，圆角就得小；
    /// 那一档是左右贴屏幕边的**大面**，半径要跟屏幕圆角同心。两个值差一倍多。
    static let mapCornerRadius: CGFloat = 20

    /// **第 5 档**：主按钮胶囊的圆角。
    ///
    /// 23 就是「46pt 高的按钮」的半高 —— 写成常量而不是丢给 `Capsule()`，
    /// 是为了让「按钮高度 → 圆角」这个隐含依赖有个名字：按钮改高度，
    /// 这里跟着改，静态检查也会盯着它别被就地改掉。
    static let buttonCornerRadius: CGFloat = 23

    /// **第 6 档**：hero 级大容器，目前只有欢迎页那颗 96pt 的图标底板。
    static let heroCornerRadius: CGFloat = 28

    /// 卡片（地图页底部大卡片）到屏幕外沿的留边。
    ///
    /// **同心圆角就是这个值**：两条弧共圆心 ⟺ 半径差 = 两者的间距。
    /// 卡片四周留 12pt，所以「卡片圆角 = 屏幕圆角 − 12」才跟屏幕同心 ——
    /// 1.0.13 及以前卡片圆角写死 44（= 55 − 12），而 55 只是 15/16 那一代的
    /// 屏幕圆角，于是 16 Pro Max（62）上圆心整整错开 6pt：
    /// 拐角那条缝一头宽一头窄，用户一眼看出「不是同心圆角」。
    static let mapPanelEdgeInset: CGFloat = 12

    /// 地图页**底部大卡片**的圆角：**跟着屏幕圆角走**，不是固定档。
    ///
    /// 卡片四周留 12pt（`mapPanelEdgeInset`），所以只要半径 = 屏幕圆角 − 12，
    /// 卡片的两条弧就跟屏幕的两条弧共享圆心。16 Pro Max（屏幕 62）得 50、
    /// 15/16（55）得 43、XR（41.5）得 29.5 —— 每台机器都是真同心。
    ///
    /// 屏幕圆角的取法、兜底与下限见 `ScreenCornerRadius`。
    ///
    /// **刻意不写成 `mapCornerRadius` 的别名**：别名一旦加回来，这张大卡片
    /// 会瞬间塌成地图小浮层的圆角（第 10 项静态检查会拦）。
    static var mapPanelCornerRadius: CGFloat {
        ScreenCornerRadius.value - mapPanelEdgeInset
    }

    /// 大卡片**内容**四周的留边：由「内层跟着卡片同心」反推出来的。
    ///
    /// 内层圆角 = 卡片圆角 − 留边；而卡片里最圆的那个内层是 46pt 的主按钮，
    /// 它的圆角不能超过自身半高 23（超了会被系统夹回胶囊，两条弧的圆心就散了），
    /// 所以 留边 = 卡片圆角 − 23 —— 这个值正好让内层两条弧**相切**而非错开。
    /// 16 Pro Max 上就是 50 − 23 = 27（1.0.13 是 44 − 24 = 20 的近似值）。
    ///
    /// 下限 20：老机型屏幕圆角小，算出来可能不到 20，文字就贴边了
    /// （那种机器上内层会比 `buttonCornerRadius` 更圆一点点，同心让位给可读性）。
    static var mapPanelContentInset: CGFloat {
        max(mapPanelCornerRadius - buttonCornerRadius, 20)
    }

    /// **同心圆角**：内层元素贴着外层容器时，它自己的圆角 = 外层圆角 − 两者间距。
    ///
    /// 两条弧共用同一个圆心，中间那条缝才会**处处等宽**（不然拐角处会一头
    /// 宽一头窄，就是「不同心」）。跟屏幕同心的 `mapPanelCornerRadius`
    /// （屏幕圆角 − 12）是同一条式子，这里只是把它写成可复用的形式。
    ///
    /// **不是一档**：它是从已有档位**推出来**的一个值，不进
    /// `CORNER_RADIUS_TIERS` 登记表，也不受「各档两两不同」约束 ——
    /// 第 10 项静态检查只认 `static let *CornerRadius: CGFloat = <数字>`。
    ///
    /// 用之前先想想间距够不够：内层是按钮的话，算出超过它**半高**的值没有意义，
    /// 系统会把它夹回胶囊，同心也就名存实亡。地图页大卡片里那个 46pt 的主按钮
    /// 就是这个道理 —— 留边取的是 `mapPanelContentInset`（= 卡片圆角 − 23），
    /// 算出来的内层圆角正好等于 23，两条弧相切。
    static func concentric(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, 0)
    }

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

