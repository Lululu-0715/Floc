import Foundation

/// 运行模式。
///
/// 拦截工作在设备内的 Go 代理里完成，覆盖范围限于当前 Wi-Fi，
/// App 关闭后即失效；需要把 CA 装进系统并开启完全信任。
///
/// **1.0.8 起只剩这一档。** 原来还有 `thirdParty`：把坐标写进
/// Shadowrocket / Surge 等客户端，由客户端执行拦截。它被移除是因为那套
/// 链路有两个绕不过去的毛病：
///
///   1. **拉不到就是静默失效。** 模块文件与两个 `.js` 都由手机上的客户端
///      运行时去远端拉，拉不到时模块开关看着还是开的、也不会报错，
///      表现只是「过一会自己恢复真实位置」，排查成本极高。
///   2. **同一套改写逻辑维护两份。** 一份 Go（`Core/wloc.go`）一份 JS
///      （`ThirdParty/ProxyScripts/wloc.js`），改一边忘一边就是
///      「某个客户端能用、某个不能」。现在只有 Go 那一份。
///
/// 枚举本身保留而不是删干净，是为了让老用户的偏好数据有个去处：
/// 本机存着 `proxyRuntimeMode = thirdParty` 的机器升级上来，
/// 迁移逻辑会把这一档收敛到 `.localProxy`，不必清数据。
///
/// 只剩一个取值之后，原来那套给模式选择界面用的 `displayName` / `summary` /
/// `systemImage` 已经没有调用方，一并删掉——界面上「应用内代理」这个词在
/// 引导页与设置页各自有自己的常量，不从这里取。
enum ProxyRuntimeMode: String {
    case localProxy
}

/// 运行模式的初始化状态。
///
/// 只回答一个问题：**这台设备上的代理环境配好了没有**。
/// 答案决定应用是停在引导流程里，还是直接进主界面。
@MainActor
final class RuntimeModeStore: ObservableObject {

    static let shared = RuntimeModeStore()

    private enum Key {
        static let mode = "proxyRuntimeMode"
        /// 老版本（有两档模式时）记录「是否已经选过模式」。
        /// 现在没有可选的模式了，不再读写；这里只留下一处说明，
        /// 免得后来人看到偏好里这个键以为它还有用。
        static let hasSelected = "hasSelectedRuntimeMode"
        static let localProxyInitialized = "localProxyInitialized"
        static let legacyMigrationDone = "runtimeModeMigrationCompleted"
        static let legacySetupCompleted = "setupCompleted"
    }

    /// 唯一的运行模式，不再是可变状态。
    let mode: ProxyRuntimeMode = .localProxy

    @Published private(set) var isInitialized: Bool

    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults

    init(
        defaults: UserDefaults = AppGroup.defaults,
        legacyDefaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
        self.isInitialized = defaults.bool(forKey: Key.localProxyInitialized)
        normalizeStoredMode()
    }

    /// 把偏好里存的模式字符串归一到唯一档位。
    ///
    /// 老机器上这里存着 `thirdParty`。它已经不是一个合法的取值了，
    /// 留在里面只会让「读不出来」这件事在下次改动时再咬人一口。
    ///
    /// **刻意不动 `localProxyInitialized`**：从第三方模式切过来的用户，
    /// 本机的证书和 Wi-Fi 代理从来没配过，直接当他「已经配好」会让应用
    /// 一路绿灯而定位纹丝不动。让他重走一遍引导（也就三步）才是对的；
    /// 而本来就用过应用内代理的用户，这个标记本来就是 true，不会被重复引导。
    private func normalizeStoredMode() {
        let stored = defaults.string(forKey: Key.mode)
        if stored != ProxyRuntimeMode.localProxy.rawValue {
            defaults.set(ProxyRuntimeMode.localProxy.rawValue, forKey: Key.mode)
        }
        migrateLegacyStateIfNeeded()
    }

    /// 更早的版本只用一个 `setupCompleted` 布尔值记录引导状态，
    /// 且那时只有应用内代理这一种链路。这里把它迁移过来，
    /// 避免老用户升级后被重新引导一遍。
    private func migrateLegacyStateIfNeeded() {
        guard !defaults.bool(forKey: Key.legacyMigrationDone) else { return }
        if legacyDefaults.bool(forKey: Key.legacySetupCompleted) {
            isInitialized = true
            defaults.set(true, forKey: Key.localProxyInitialized)
            RuntimeLogger.info("APP", "Mode", "已迁移旧版引导状态")
        }
        defaults.set(true, forKey: Key.legacyMigrationDone)
    }

    func markInitialized() {
        isInitialized = true
        defaults.set(true, forKey: Key.localProxyInitialized)
    }

    func resetInitialization() {
        isInitialized = false
        defaults.set(false, forKey: Key.localProxyInitialized)
    }
}
