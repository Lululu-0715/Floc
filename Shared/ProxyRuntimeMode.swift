import Foundation

/// 运行模式。
///
/// 两种模式的差别是本质性的，不是「高级 / 简单」的关系：
///   - localProxy：拦截工作在设备内的 Go 代理里完成，覆盖范围限于当前 Wi-Fi，
///     App 关闭后即失效。需要装 CA。
///   - thirdParty：拦截工作交给用户自己的代理客户端（Shadowrocket 等），
///     覆盖范围取决于客户端（可以走蜂窝网络），App 只负责把坐标写过去。
enum ProxyRuntimeMode: String, CaseIterable, Codable, Identifiable {
    case localProxy
    case thirdParty

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localProxy: return AppLocalization.string("应用内代理")
        case .thirdParty: return AppLocalization.string("第三方代理")
        }
    }

    var summary: String {
        switch self {
        case .localProxy:
            return AppLocalization.string("在设备内运行拦截代理，只覆盖当前 Wi-Fi，需要安装并信任证书。")
        case .thirdParty:
            return AppLocalization.string("由你自己的代理客户端执行拦截，可覆盖蜂窝网络，无需安装本应用证书。")
        }
    }

    var systemImage: String {
        switch self {
        case .localProxy: return "wifi.router"
        case .thirdParty: return "shield.lefthalf.filled"
        }
    }
}

/// 运行模式的选择与初始化状态。
///
/// 「初始化状态」是按模式分别记录的：用户可能先用了应用内代理完成配置，
/// 后来换成第三方代理，此时两种模式的引导进度应当各自保留。
@MainActor
final class RuntimeModeStore: ObservableObject {

    static let shared = RuntimeModeStore()

    private enum Key {
        static let mode = "proxyRuntimeMode"
        static let hasSelected = "hasSelectedRuntimeMode"
        static let localProxyInitialized = "localProxyInitialized"
        static let thirdPartyInitialized = "thirdPartyInitialized"
        static let legacyMigrationDone = "runtimeModeMigrationCompleted"
        static let legacySetupCompleted = "setupCompleted"
    }

    @Published private(set) var mode: ProxyRuntimeMode
    @Published private(set) var hasSelectedMode: Bool
    @Published private(set) var localProxyInitialized: Bool
    @Published private(set) var thirdPartyInitialized: Bool

    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults

    init(
        defaults: UserDefaults = AppGroup.defaults,
        legacyDefaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
        self.mode = defaults.string(forKey: Key.mode)
            .flatMap(ProxyRuntimeMode.init(rawValue:)) ?? .localProxy
        self.hasSelectedMode = defaults.bool(forKey: Key.hasSelected)
        self.localProxyInitialized = defaults.bool(forKey: Key.localProxyInitialized)
        self.thirdPartyInitialized = defaults.bool(forKey: Key.thirdPartyInitialized)
        migrateLegacyStateIfNeeded()
    }

    func select(_ mode: ProxyRuntimeMode) {
        let changed = self.mode != mode
        self.mode = mode
        hasSelectedMode = true
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(true, forKey: Key.hasSelected)
        migrateLegacyStateIfNeeded()

        if changed {
            RuntimeLogger.info("APP", "Mode", "运行模式已切换", details: [
                "mode": mode.displayName,
            ])
        }
    }

    func isInitialized(_ mode: ProxyRuntimeMode) -> Bool {
        switch mode {
        case .localProxy: return localProxyInitialized
        case .thirdParty: return thirdPartyInitialized
        }
    }

    func markInitialized(_ mode: ProxyRuntimeMode) {
        setInitialized(true, for: mode)
    }

    func resetInitialization(_ mode: ProxyRuntimeMode) {
        setInitialized(false, for: mode)
    }

    private func setInitialized(_ value: Bool, for mode: ProxyRuntimeMode) {
        switch mode {
        case .localProxy:
            localProxyInitialized = value
            defaults.set(value, forKey: Key.localProxyInitialized)
        case .thirdParty:
            thirdPartyInitialized = value
            defaults.set(value, forKey: Key.thirdPartyInitialized)
        }
    }

    /// 老版本只用一个 `setupCompleted` 布尔值记录引导状态。
    /// 这里把它迁移到当前所选模式上，避免老用户升级后被重新引导一遍。
    private func migrateLegacyStateIfNeeded() {
        guard hasSelectedMode, !defaults.bool(forKey: Key.legacyMigrationDone) else { return }
        if legacyDefaults.bool(forKey: Key.legacySetupCompleted) {
            setInitialized(true, for: mode)
            RuntimeLogger.info("APP", "Mode", "已迁移旧版引导状态", details: [
                "mode": mode.displayName,
            ])
        }
        defaults.set(true, forKey: Key.legacyMigrationDone)
    }
}
