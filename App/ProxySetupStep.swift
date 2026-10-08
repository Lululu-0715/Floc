import SwiftUI

/// 引导第二步：配置应用内代理环境。
///
/// 1.0.8 起只剩应用内代理这一条链路，所以这一步不再分模式。
struct ProxySetupStep: View {

    @ObservedObject var setup: SetupCoordinator
    @ObservedObject private var proxy = ProxyManager.shared

    @State private var isStarting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StatusCard(
                title: AppLocalization.string("代理服务"),
                value: proxy.status.displayText,
                isGood: proxy.status.isRunning,
                icon: "bolt.horizontal.circle"
            )

            if case .failed(let reason) = proxy.status {
                InlineAlert(text: reason, style: .error)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(AppLocalization.string("配置步骤"))
                    .font(.headline)

                ForEach(Array(proxy.setupInstructions.enumerated()), id: \.offset) { index, instruction in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 20, height: 20)
                            .background(Color.accentColor.opacity(0.15), in: Circle())
                            .foregroundStyle(Color.accentColor)
                        Text(instruction)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 10) {
                Button {
                    if let url = proxy.certificateDownloadURL {
                        CertificateTrustVerifier.openCertificateDownload(url: url)
                    }
                } label: {
                    Label(AppLocalization.string("下载证书"), systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .disabled(proxy.certificateDownloadURL == nil)

                Button {
                    SystemSettingsNavigator.openCertificateTrustSettings()
                } label: {
                    Label(AppLocalization.string("信任设置"), systemImage: "lock.shield")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }

            Button {
                SystemSettingsNavigator.openWiFiSettings()
            } label: {
                Label(AppLocalization.string("前往 Wi-Fi 设置"), systemImage: "wifi")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)

            if !proxy.status.isRunning {
                Button {
                    Task { await startLocalProxy() }
                } label: {
                    HStack {
                        if isStarting { ProgressView().tint(.white) }
                        Text(AppLocalization.string("启动代理服务"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStarting)
            }
        }
        .task {
            // 进入本步就把代理起起来，这样证书服务可用，用户能立刻去装证书。
            // 先实测一次端口：状态可能停在 .running 而进程实际已被系统回收。
            proxy.syncStatusWithReality()
            if !proxy.status.isRunning {
                await startLocalProxy()
            }
        }
    }

    private func startLocalProxy() async {
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }

        do {
            try await proxy.start(
                latitude: 0,
                longitude: 0,
                enabled: false,
                accuracy: 25,
                motionRadius: 0
            )
        } catch {
            errorMessage = error.localizedDescription
            RuntimeLogger.error("APP", "Setup", "启动代理失败", details: [
                "error": error.localizedDescription,
            ])
        }
    }
}

/// 状态卡片。
struct StatusCard: View {

    let title: String
    let value: String
    let isGood: Bool
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(isGood ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
            }

            Spacer()

            Circle()
                .fill(isGood ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 内联提示条。
struct InlineAlert: View {

    enum Style {
        case error, warning, info

        var color: Color {
            switch self {
            case .error: return .red
            case .warning: return .orange
            case .info: return .blue
            }
        }

        var icon: String {
            switch self {
            case .error: return "xmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    /// 提示条的呈现方式。
    enum Presentation {
        /// 表单 / 引导页里的内联提示：图标在左、文字左对齐、贴在页面里。
        case inline
        /// 地图页浮层上的横幅：整体居中，圆角与地图页其他浮层一致，
        /// 并套同一层玻璃底——否则贴在卫星图上读不清。
        case mapBanner
    }

    let text: String
    let style: Style
    var presentation: Presentation = .inline

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .inline:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.icon)
                    .foregroundStyle(style.color)
                Text(text)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(style.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

        case .mapBanner:
            VStack(spacing: 6) {
                Image(systemName: style.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(style.color)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: GlassMetrics.mapCornerRadius, style: .continuous)
                    .fill(style.color.opacity(0.10))
            )
            .mapGlassSurface()
        }
    }
}
