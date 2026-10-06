import Foundation
import Network
import SystemConfiguration.CaptiveNetwork

/// 网络状态监听。
///
/// 主要用于两件事：
///   1. 拿到当前 Wi-Fi 名称，在引导文案里明确指出该去哪一页配置代理；
///   2. Wi-Fi 切换时触发代理链路重新验证（手动代理配置是跟着网络走的）。
@MainActor
final class NetworkMonitor {

    /// Wi-Fi 名称变化时的回调。
    var onWiFiChanged: ((String) -> Void)?

    /// 当前是否处于 Wi-Fi 连接。
    private(set) var isOnWiFi = false

    /// 当前 Wi-Fi 名称，取不到时为空串。
    private(set) var currentWiFiName: String = ""

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "com.fff.loc.network")
    private var lastSSID = ""

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let name = WiFiInfoProvider.currentSSID() ?? ""
            Task { @MainActor in
                guard let self else { return }
                let changed = self.isOnWiFi != satisfied || self.lastSSID != name
                self.isOnWiFi = satisfied
                self.currentWiFiName = name
                if changed {
                    self.lastSSID = name
                    RuntimeLogger.info("APP", "Network", "Wi-Fi 状态变化", details: [
                        "connected": String(satisfied),
                        "ssid": name.isEmpty ? "<未知>" : name,
                    ])
                    self.onWiFiChanged?(name)
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// 主动刷新一次 Wi-Fi 名称。
    func refresh() {
        currentWiFiName = WiFiInfoProvider.currentSSID() ?? ""
    }
}

/// SSID 读取实现。
///
/// `CNCopyCurrentNetworkInfo` 从 iOS 13 起需要定位权限和
/// `com.apple.developer.networking.wifi-info` entitlement，两者缺一都会返回 nil。
/// 取不到名称不影响核心功能，只影响引导文案的精确度，因此这里静默降级。
enum WiFiInfoProvider {

    static func currentSSID() -> String? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for interface in interfaces {
            guard let info = CNCopyCurrentNetworkInfo(interface as CFString) as? [String: Any] else {
                continue
            }
            if let ssid = info[kCNNetworkInfoKeySSID as String] as? String, !ssid.isEmpty {
                return ssid
            }
        }
        return nil
        #endif
    }
}
