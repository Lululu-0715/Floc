import SwiftUI

/// 引导第一步：选择运行模式。
struct ModeSelectionStep: View {

    @ObservedObject var setup: SetupCoordinator

    var body: some View {
        VStack(spacing: 14) {
            ForEach(ProxyRuntimeMode.allCases) { mode in
                ModeCard(
                    mode: mode,
                    isSelected: setup.runtimeMode.hasSelectedMode && setup.selectedMode == mode
                ) {
                    setup.select(mode)
                }
            }

            if setup.runtimeMode.hasSelectedMode {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                    Text(AppLocalization.string("不要同时开启应用内代理和第三方代理，两条链路会互相干扰。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct ModeCard: View {

    let mode: ProxyRuntimeMode
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.themeAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: mode.systemImage)
                    .font(.title2)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(isSelected ? Color.white : accent)
                    .background(
                        isSelected ? accent : accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text(mode.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(mode.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? accent : Color(.tertiaryLabel))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
