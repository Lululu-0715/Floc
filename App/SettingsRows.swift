import SwiftUI

/// 设置页的排版尺寸。
///
/// 之前行标题用系统默认字号、行内上下几乎不留白，一屏堆下来很挤，
/// 分组标题更是小到快看不见。这里把字号和留白都提到一处，
/// 之后调整只改这里。
enum SettingsMetrics {

    /// 行标题字号。比系统默认 body 稍大一点，配合 medium 字重更清楚。
    static let titleFont = Font.system(size: 17, weight: .medium)

    /// 行尾状态文字字号。
    static let valueFont = Font.system(size: 16)

    /// 行标题下方说明文字字号。
    static let subtitleFont = Font.system(size: 13)

    /// 分组标题字号。系统默认的分组标题只有 13pt，太弱。
    static let sectionHeaderFont = Font.system(size: 15, weight: .semibold)

    /// 行内上下留白。旧版贴着分隔线，行与行之间没有呼吸感。
    static let rowVerticalPadding: CGFloat = 5

    /// 行首图标与文字之间的间距。
    static let iconSpacing: CGFloat = 12

    /// 行首图标尺寸。
    static let iconSize: CGFloat = 36
}

/// 设置页分组标题。
///
/// 系统默认的大写小字标题在中文环境下既小又难读，这里统一换成
/// 15pt 半粗的自定义标题。
struct SettingsSectionHeader: View {

    let title: String

    var body: some View {
        Text(title)
            .font(SettingsMetrics.sectionHeaderFont)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.top, 4)
    }
}

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
                .frame(width: SettingsMetrics.iconSize, height: SettingsMetrics.iconSize)
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
        HStack(spacing: SettingsMetrics.iconSpacing) {
            SettingsIconBadge(systemImage: systemImage)

            Text(title)
                .font(SettingsMetrics.titleFont)

            Spacer(minLength: 8)

            Text(value)
                .font(monospacedValue
                      ? .system(size: 16, design: .monospaced)
                      : SettingsMetrics.valueFont)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
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
        HStack(spacing: SettingsMetrics.iconSpacing) {
            SettingsIconBadge(systemImage: systemImage)

            if let subtitle {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SettingsMetrics.titleFont)
                    Text(subtitle)
                        .font(SettingsMetrics.subtitleFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(title)
                    .font(SettingsMetrics.titleFont)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.blue)
                .disabled(!isEnabled)
        }
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
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
        HStack(spacing: SettingsMetrics.iconSpacing) {
            SettingsIconBadge(systemImage: systemImage, tint: tint)
            Text(title)
                .font(SettingsMetrics.titleFont)
                .foregroundStyle(isSecondary ? Color.secondary : Color.primary)
        }
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
    }
}
