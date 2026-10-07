import SwiftUI

/// 玻璃质感卡片。
///
/// iOS 15 上没有系统级的玻璃材质，这里用 Material 手工模拟：
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
        content
            .background(shape.fill(.ultraThinMaterial))
            .overlay(
                shape.stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: shadowRadius, y: 4)
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
/// 形状参数化的版本：圆角矩形和胶囊共用同一套材质、描边与投影。
///
/// 之前只支持圆角矩形，要做胶囊按钮就得再抄一份 modifier——材质或描边
/// 改一处漏一处几乎是必然，所以把形状提到泛型参数上。
struct MapGlassSurfaceModifier<S: Shape>: ViewModifier {

    var shape: S

    func body(content: Content) -> some View {
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
    func mapGlassCapsule() -> some View {
        modifier(MapGlassSurfaceModifier(shape: Capsule(style: .continuous)))
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
    /// 比同级浮层大 8pt：面板又宽又高，同样的绝对圆角在它身上看起来明显
    /// 比搜索框、图层切换「方」，两个数值一致反而不像一套东西。提到 28 之后
    /// 面板与内部的胶囊按钮弧度才读得出是同一族。
    static let mapPanelCornerRadius: CGFloat = 28

    /// 地图页浮层的投影半径。比卡片稍小，浮起感够用又不至于发糊。
    static let mapShadowRadius: CGFloat = 10

    /// 地图页浮层在材质之上再压一层的系统底色不透明度。
    ///
    /// 0 就是纯 material（旧版的行为，卫星图上小字会被纹理吃掉），
    /// 1 就是完全实心、没有玻璃感。0.55 是「看得清」和「还像玻璃」的折中。
    static let mapSurfaceTint: Double = 0.55
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
