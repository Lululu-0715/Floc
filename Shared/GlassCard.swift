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

    /// 圆角半径。地图上的胶囊控件传 20，卡片类容器用默认值。
    var cornerRadius: CGFloat = 16

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

extension View {

    /// 套用玻璃卡片外观。
    func glassCard(cornerRadius: CGFloat = 16, shadowRadius: CGFloat = 12) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, shadowRadius: shadowRadius))
    }
}

/// 玻璃胶囊按钮组里的单个按钮。
///
/// 抽出来是因为「选中态填充 + 未选中态留白」这套状态在标准/卫星/混合
/// 三个按钮之间完全一致，写在循环里比复制三遍更不容易走形。
struct GlassSegmentButton: View {

    let systemImage: String
    let accessibilityLabel: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.7))
                .frame(width: 38, height: 32)
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
