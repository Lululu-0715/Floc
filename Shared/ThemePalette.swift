import SwiftUI

/// 一套配色主题。
///
/// 主题由三样东西定义：
///   1. **渐变三色** —— 用于欢迎页/引导页的整页背景、图标块与主按钮；
///   2. **强调色** —— 全局 `.tint`，决定按钮文字、选中态、图标底色；
///   3. **名字** —— 走本地化查表（`nameKey` 就是简体中文原文）。
///
/// 色值直接取参考图里的十六进制，不做二次调色：用户是拿着那张图来的，
/// 看到的颜色必须和图里一致。唯一例外是 `accentHex` —— 它要在白色玻璃上
/// 当文字色用，原色（比如 #ff3d58、#fca731）对比度不够，所以另给一个
/// 略深的值。渐变用的仍是原色。
struct ThemePalette: Identifiable, Equatable, Hashable {

    let id: String

    /// 主题名的本地化 key。
    let nameKey: String

    /// 渐变停靠色（左上 → 右下）。**空数组表示「跟随系统」**，不铺渐变。
    let gradientHexes: [String]

    /// 强调色。
    let accentHex: String

    /// 是不是「系统默认」那一档。
    var isSystem: Bool { gradientHexes.isEmpty }

    var displayName: String { AppLocalization.string(nameKey) }

    var accent: Color { Color(hex: accentHex) ?? .blue }

    var gradientColors: [Color] { gradientHexes.compactMap(Color.init(hex:)) }

    /// 整页背景用的渐变。系统默认那一档返回 nil，调用方自行回落到系统底色。
    var gradient: LinearGradient? {
        let colors = gradientColors
        guard colors.count >= 2 else { return nil }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 图标块/主按钮用的渐变。只有一个色值时退回纯色渐变，保证类型稳定。
    var solidGradient: LinearGradient {
        let colors = gradientColors
        guard colors.count >= 2 else {
            return LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)
        }
        // 取前两色：第三个色在参考图里是收尾的浅色，铺到大按钮上会把
        // 白字吃掉（比如「玫红雪白」的 #f2f2f2）。
        return LinearGradient(colors: [colors[0], colors[1]],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 给设置页做色卡预览用的渐变（三色全用）。
    var previewGradient: LinearGradient {
        gradient ?? solidGradient
    }
}

/// 全部可选主题，顺序即设置页里的顺序。
enum ThemeCatalog {

    static let systemID = "system"

    /// 「跟随系统」+ 参考图里的六套。
    ///
    /// 默认给「跟随系统」而不是某一套彩色主题：没选过主题的用户升级上来
    /// 看到的必须还是原来的样子（1.0.10 及以前一直是系统蓝），
    /// 否则一次常规更新会突然把所有人的界面染成玫红。
    static let all: [ThemePalette] = [
        ThemePalette(id: systemID,
                     nameKey: "跟随系统",
                     gradientHexes: [],
                     accentHex: "#007aff"),

        ThemePalette(id: "rose",
                     nameKey: "玫红雪白",
                     gradientHexes: ["#ff3d58", "#ff9cab", "#f2f2f2"],
                     accentHex: "#e8455f"),

        ThemePalette(id: "mint",
                     nameKey: "薄荷孔雀绿",
                     gradientHexes: ["#9fffc3", "#47dca7", "#00af83"],
                     accentHex: "#00a37a"),

        ThemePalette(id: "night",
                     nameKey: "夜紫橙金",
                     gradientHexes: ["#302235", "#8c6553", "#fca731"],
                     accentHex: "#d98410"),

        ThemePalette(id: "lake",
                     nameKey: "湖蓝淡粉",
                     gradientHexes: ["#27a6cc", "#80bdf4", "#fcc5c5"],
                     accentHex: "#1f8fb5"),

        ThemePalette(id: "neon",
                     nameKey: "荧光水绿",
                     gradientHexes: ["#3afff2", "#31ddb9", "#26af84"],
                     accentHex: "#12a37c"),

        ThemePalette(id: "electric",
                     nameKey: "电光蓝紫",
                     gradientHexes: ["#00f6ff", "#2a8dde", "#18269e"],
                     accentHex: "#1f76d0"),
    ]

    /// 按 id 取主题，取不到回落到系统默认。
    ///
    /// 用 id 而不是下标存盘：以后在中间插入一套主题，老用户的选项不会串位。
    static func palette(id: String) -> ThemePalette {
        all.first { $0.id == id } ?? all[0]
    }
}

extension Color {

    /// 解析 `#rrggbb` / `rrggbb` / `#rgb` / `#rrggbbaa`。
    ///
    /// 写成 `init?` 而不是 `init`：色值全部硬编码在 `ThemeCatalog` 里，
    /// 万一写错一个字符，希望是「这一套整体退回系统蓝」，而不是崩在
    /// 取色值的那一行。
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }

        guard let value = UInt64(text, radix: 16) else { return nil }

        let r, g, b, a: Double
        switch text.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            return nil
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
