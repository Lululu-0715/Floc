import SwiftUI

/// 配色主题的存储与派生样式。
///
/// 和 `AppearanceStore`（浅色/深色）分开管理：那两个是**系统外观**，
/// 这个是**品牌配色**，可以各选各的（深色 + 玫红雪白是合法组合）。
/// 存盘用主题 id 字符串，添加新主题不会影响老数据。
@MainActor
final class ThemeStore: ObservableObject {

    static let shared = ThemeStore()

    private enum Key {
        static let themeID = "appThemeID"
    }

    private let defaults: UserDefaults

    @Published var palette: ThemePalette {
        didSet {
            guard palette != oldValue else { return }
            defaults.set(palette.id, forKey: Key.themeID)
            RuntimeLogger.info("APP", "Theme", "配色主题已切换", details: [
                "theme": palette.id,
            ])
        }
    }

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Key.themeID) ?? ThemeCatalog.systemID
        palette = ThemeCatalog.palette(id: stored)
    }

    /// 全局强调色。
    var accent: Color { palette.accent }

    /// 是否选了一套带渐变的彩色主题。
    var isThemed: Bool { !palette.isSystem }

    /// 整页背景渐变（系统默认那一档为 nil）。
    var gradient: LinearGradient? { palette.gradient }

    /// 玻璃浮层在 iOS 26 上的染色。
    ///
    /// 有主题时用主题首色，让浮层带一点主题的色偏——参考图里那块胶囊之所以
    /// 看起来「有味道」，靠的就是底色透过玻璃映上来。饱和度压得很低
    /// （0.22），玻璃本身还要负责折射与高光，染重了会退回成一块色板。
    var glassTint: Color {
        guard isThemed, let first = palette.gradientColors.first else {
            return Color(.systemBackground).opacity(GlassMetrics.mapGlassTint)
        }
        return first.opacity(GlassMetrics.themedGlassTint)
    }

    /// 贴在玻璃面板内部的胶囊填充。
    ///
    /// iOS 26 上这层**不能再叠一次玻璃**（嵌套玻璃会被外层吃掉），所以用
    /// 一层带主题色偏的淡填充代替。系统默认主题时退回中性灰，
    /// 与 1.0.10 的观感一致。
    var innerCapsuleFill: AnyShapeStyle {
        guard isThemed else {
            return AnyShapeStyle(Color.primary.opacity(GlassMetrics.mapCapsuleTint))
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: palette.gradientColors.prefix(2).map {
                    $0.opacity(GlassMetrics.themedCapsuleTint)
                },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    /// 页面背景渐变的浓度。
    ///
    /// 深色模式下要更浓一点，否则彩色压到黑底上几乎看不出来。
    /// 数值刻意保守：背景上还有正文，染太深会先把可读性搞掉。
    func backgroundOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.42 : 0.30
    }
}

/// 「账号」分组卡片的底色：跟随配色主题。
///
/// 分组列表的卡片底色本来由系统给（`secondarySystemGroupedBackground`），
/// 跟主题没有任何关系。这里在系统底色**之上**再铺一层很淡的主题渐变：
/// 保留系统色提供的对比度（正文、分隔线、次要文字全靠它），只让卡片带一点
/// 主题的色偏。直接拿主题色当底色的话，浅色主题下深色正文还能看，
/// 深色主题配浅字就会糊成一片。
///
/// 「跟随系统」这一档不染色 —— 和整页背景的处理保持一致。
struct ThemedGroupedCardBackground: View {

    @ObservedObject private var theme = ThemeStore.shared

    /// 染色浓度。比整页背景（0.30 / 0.42）更淡：卡片面积小、上面压着
    /// 正文和图标，染重了会先把可读性搞掉。
    private static let tintOpacity: Double = 0.22

    var body: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)

            if let gradient = theme.gradient {
                gradient.opacity(Self.tintOpacity)
            }
        }
    }
}

/// 整页主题背景。
///
/// 铺在系统分组底色之上：主题只负责**染色**，不负责提供对比度，
/// 所以正文颜色、分隔线、分组卡片全都照旧由系统色负责。
struct ThemedBackground: View {

    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)

            if let gradient = theme.gradient {
                gradient
                    .opacity(theme.backgroundOpacity(for: colorScheme))
                    // 顶部浓、往下淡：标题区染上主题色，长正文区域保持干净。
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0.0),
                                .init(color: .white.opacity(0.75), location: 0.45),
                                .init(color: .white.opacity(0.35), location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 强调色的环境传递

/// 主题强调色。
///
/// **为什么不用 `Color.accentColor`**：那个静态色读的是资源目录里的
/// AccentColor，跟 `.tint()` 完全是两回事。1.0.11 第一版只在根节点挂了
/// `.tint(主题色)`，结果地图上的图层切换按钮、状态胶囊还是系统蓝
/// —— 实拍一眼就看出来了。
///
/// **为什么不改成 `ThemeStore.shared.accent`**：那样视图不会因为主题变化
/// 重新求值（`GlassSegmentButton` 这种叶子视图的入参没变，SwiftUI 会跳过
/// 它的 body）。走环境值最稳：值一变，**只有真正读了它的视图**重新求值。
///
/// 默认值是系统蓝，和以前的外观完全一致。
private struct ThemeAccentKey: EnvironmentKey {
    static let defaultValue: Color = .blue
}

extension EnvironmentValues {
    var themeAccent: Color {
        get { self[ThemeAccentKey.self] }
        set { self[ThemeAccentKey.self] = newValue }
    }
}
