import SafariServices
import SwiftUI

/// 应用内浏览器。
///
/// 用于打开教程、仓库页面等外部链接，避免跳出应用。
struct SafariView: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = .systemBlue
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// 可被 `.sheet(item:)` 使用的 Safari 目标。
struct SafariDestination: Identifiable {
    let id = UUID()
    let url: URL
}

/// 首次使用时的提示卡片。
///
/// 只在用户第一次执行某个操作时出现，之后不再打扰。
struct TipCard: View {

    enum Kind: String, CaseIterable {
        case enableSpoofing
        case disableSpoofing
        case disableWiFiProxy
        case thirdPartyMode
        case certificateTrust

        var title: String {
            switch self {
            case .enableSpoofing: return AppLocalization.string("开启前请确认")
            case .disableSpoofing: return AppLocalization.string("如何彻底恢复真实位置")
            case .disableWiFiProxy: return AppLocalization.string("关闭 WiFi 代理")
            case .thirdPartyMode: return AppLocalization.string("第三方模式说明")
            case .certificateTrust: return AppLocalization.string("关于证书信任")
            }
        }

        var message: String {
            switch self {
            case .enableSpoofing:
                return AppLocalization.string("开启后定位响应会被改写。部分应用有独立的定位缓存或校验策略，可能需要等待缓存刷新或重启目标应用。")
            case .disableSpoofing:
                return AppLocalization.string("停止虚拟定位后，还需要关闭 Wi-Fi 的手动代理配置。如果系统仍显示旧位置，等待缓存刷新，必要时重启设备。")
            case .disableWiFiProxy:
                return AppLocalization.string("停止虚拟定位后，请到「设置 → 无线局域网 → 当前网络 → 配置代理」中改回「关闭」，否则流量仍会指向已停止的本机代理。")
            case .thirdPartyMode:
                return AppLocalization.string("本应用只负责把坐标写给你的代理客户端，拦截与规则由客户端执行。应用关闭后客户端里的配置可能继续生效。")
            case .certificateTrust:
                return AppLocalization.string("安装描述文件后，还需要在「设置 → 通用 → 关于本机 → 证书信任设置」中手动开启完全信任，否则拦截不会生效。")
            }
        }

        var systemImage: String {
            switch self {
            case .enableSpoofing: return "info.circle"
            case .disableSpoofing: return "arrow.uturn.backward.circle"
            case .disableWiFiProxy: return "wifi.slash"
            case .thirdPartyMode: return "shield.lefthalf.filled"
            case .certificateTrust: return "lock.shield"
            }
        }

        /// 设置页「说明」分组里的入口名称。
        ///
        /// 与 `title` 分开：`title` 是弹层里的即时提示，用第二人称的口吻
        /// （「开启前请确认」）；这里的入口是一份目录项，用名词短语更整齐，
        /// 也和「生效 / 失效」这对概念对齐。
        var settingsLabel: String {
            switch self {
            case .enableSpoofing: return AppLocalization.string("生效说明")
            case .disableSpoofing: return AppLocalization.string("失效说明")
            case .disableWiFiProxy: return AppLocalization.string("关闭 WiFi 代理")
            case .thirdPartyMode, .certificateTrust: return title
            }
        }
    }

    let kind: Kind
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 5) {
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                Text(kind.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 记录哪些提示已经展示过，避免重复打扰。
struct TipPreferences {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    func hasShown(_ kind: TipCard.Kind) -> Bool {
        defaults.bool(forKey: key(for: kind))
    }

    func markShown(_ kind: TipCard.Kind) {
        defaults.set(true, forKey: key(for: kind))
    }

    func reset() {
        TipCard.Kind.allCases.forEach { defaults.removeObject(forKey: key(for: $0)) }
    }

    private func key(for kind: TipCard.Kind) -> String {
        "tipShown.\(kind.rawValue)"
    }
}

/// 提示的详情页。
///
/// 设置页的「说明」分组点进来的落地页：同一份文案在弹层里只够看一眼，
/// 这里给足版面把它读清楚。
struct TipDetailView: View {

    let kind: TipCard.Kind

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                        .overlay(
                            Image(systemName: kind.systemImage)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(.white)
                        )

                    Text(kind.settingsLabel)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(kind.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .glassCard()
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(kind.settingsLabel)
        .navigationBarTitleDisplayMode(.inline)
    }
}
