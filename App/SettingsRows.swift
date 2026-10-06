import SwiftUI

/// 设置页行首的蓝色圆形图标。
///
/// 36×36 的实心圆 + 白色 SF Symbol。所有设置行都以它开头，扫视时
/// 可以靠颜色和图形快速定位到目标分组，不必逐字读标题。
struct SettingsIconBadge: View {

    let systemImage: String
    var tint: Color = .blue

    var body: some View {
        ZStack {
            Circle()
                .fill(tint)
                .frame(width: 36, height: 36)
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

/// 只读状态行：图标 + 标题 + 右侧灰色文字。
///
/// 刻意**不加箭头**——箭头在 iOS 里表示"可以点进去"，这里只是陈述
/// 当前状态，加了会诱导用户去点一个点不动的行。
struct SettingsStatusRow: View {

    let systemImage: String
    let title: String
    let value: String
    var valueColor: Color = .secondary
    /// 文件名、标识符这类技术性取值用等宽字体，避免 `l`/`1`、`O`/`0` 看混。
    var monospacedValue: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconBadge(systemImage: systemImage)

            Text(title)

            Spacer(minLength: 8)

            Text(value)
                .font(monospacedValue ? .body.monospaced() : .body)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 开关行：图标 + 标题（可带说明）+ 右侧 Toggle。
struct SettingsToggleRow: View {

    let systemImage: String
    let title: String
    /// 标题下方的补充说明，用于「实验性功能」这类需要解释的开关。
    var subtitle: String?
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconBadge(systemImage: systemImage)

            if let subtitle {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(title)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.blue)
                .disabled(!isEnabled)
        }
    }
}

/// 可点行（按钮 / 跳转）的标签内容。
///
/// `NavigationLink` 会自动补上右侧箭头；`Button` 则需要调用方自己
/// 决定要不要箭头，所以这里只管左边那段。
struct SettingsLabel: View {

    let systemImage: String
    let title: String
    /// 跳转类入口用灰色文字，与「可点但不强调」的层级一致。
    var isSecondary: Bool = false
    var tint: Color = .blue

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconBadge(systemImage: systemImage, tint: tint)
            Text(title)
                .foregroundStyle(isSecondary ? Color.secondary : Color.primary)
        }
    }
}
