import Foundation
import Network
import SystemConfiguration.CaptiveNetwork

/// 当前网络的接入方式。
///
/// **为什么必须区分 Wi-Fi 与蜂窝**：应用内代理是靠「手动 HTTP 代理」生效的，
/// 而手动代理是**挂在某一个 Wi-Fi 网络上的**（设置 → 无线局域网 → 当前网络 →
/// 配置代理），iOS 没有给蜂窝网络配 HTTP 代理的入口。所以用户在蜂窝下开启
/// 虚拟定位时，代理进程确实起来了、开关也确实亮了，但没有任何流量会走到
/// 127.0.0.1:8888 —— 表现就是「提示开启成功，定位纹丝不动」。
/// 功能上不可能支持，那就必须在开启前拦住并讲清楚原因。
enum NetworkTransport: Equatable {

    case wifi
    case cellular

    /// 未知：模拟器、有线网络，或路径还没就绪。
    ///
    /// **这一档不拦截**。判错的代价是不对称的：误把 Wi-Fi 当蜂窝会直接
    /// 让功能不可用，而放过一次蜂窝只是回到改造前的行为。模拟器也落在这里
    /// （它的网络走宿主机的有线，`usesInterfaceType(.wifi)` 为 false），
    /// 所以界面回归不受影响。
    case other

    /// 应用内代理在当前接入方式下是否可用。
    ///
    /// 只有明确判定为蜂窝时才拦。抽取成独立判断是为了能单测 ——
    /// 这条策略一旦写反（比如把 `.other` 也拦掉），表现是「模拟器上功能全废」，
    /// 在真机上反而看不出来。
    var blocksInAppProxy: Bool { self == .cellular }

    /// 日志用的稳定标识。**刻意不走本地化**：日志要能跨语言对照，
    /// 写成「移动网络」之后切到英文再看日志就找不到同一条了。
    var debugName: String {
        switch self {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .other: return "other"
        }
    }

    /// 给用户看的名称。
    var displayText: String {
        switch self {
        case .wifi: return AppLocalization.string("Wi-Fi")
        case .cellular: return AppLocalization.string("移动网络")
        case .other: return AppLocalization.string("未知网络")
        }
    }
}

/// 网络状态监听。
///
/// 主要用于三件事：
///   1. 拿到当前 Wi-Fi 名称，在引导文案里明确指出该去哪一页配置代理；
///   2. Wi-Fi 切换时触发代理链路重新验证（手动代理配置是跟着网络走的）；
///   3. 区分 Wi-Fi / 蜂窝，好在蜂窝下拦住应用内代理的开启动作。
@MainActor
final class NetworkMonitor {

    /// Wi-Fi 名称变化时的回调。
    var onWiFiChanged: ((String) -> Void)?

    /// 接入方式变化时的回调。**每次路径更新都会回调**，不像 `onWiFiChanged`
    /// 只在「发生了变化」时回调 —— 后者在蜂窝下永远不会触发（初始值就是
    /// 「不在 Wi-Fi」，状态没变），冷启动时接入方式就永远是未知。
    var onTransportChanged: ((NetworkTransport, String) -> Void)?

    /// 当前接入方式。见 `NetworkTransport` 的说明。
    private(set) var transport: NetworkTransport = .other

    /// 当前是否处于 Wi-Fi 连接。
    var isOnWiFi: Bool { transport == .wifi }

    /// 当前 Wi-Fi 名称，取不到时为空串。
    private(set) var currentWiFiName: String = ""

    /// 不限定接口类型：要同时看到 Wi-Fi 与蜂窝，才能判断「是不是在蜂窝下」。
    /// 原来用的是 `requiredInterfaceType: .wifi`，那样拿不到蜂窝路径，
    /// 也就没法把「没有 Wi-Fi」和「用的是蜂窝」区分开。
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.fff.loc.network")
    private var lastSSID = ""

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let transport = Self.transport(for: path)
            let name = WiFiInfoProvider.currentSSID() ?? ""
            Task { @MainActor in
                guard let self else { return }
                let changed = self.transport != transport || self.lastSSID != name
                self.apply(transport: transport, name: name)
                self.onTransportChanged?(transport, name)
                if changed {
                    self.lastSSID = name
                    RuntimeLogger.info("APP", "Network", "网络状态变化", details: [
                        "transport": transport.debugName,
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

    /// 主动刷新一次。路径没变化时 `pathUpdateHandler` 不会再回调，
    /// 所以进入主界面这类关键时点要自己拉一次。
    func refresh() {
        apply(transport: Self.transport(for: monitor.currentPath),
              name: WiFiInfoProvider.currentSSID() ?? "")
    }

    private func apply(transport newValue: NetworkTransport, name: String) {
        transport = Self.forcedTransport ?? newValue
        currentWiFiName = name
    }

    /// 调试用：把接入方式强制成指定值。
    ///
    /// 存在的唯一理由：**模拟器的网络走宿主机的有线，永远是 `.other`**，
    /// 蜂窝那条拦截分支在模拟器上根本走不到。要在模拟器上核对提示文案与
    /// 拦截行为，只能靠这个开关。Release 构建里整段不存在，
    /// 不留任何可以被外部改动的入口。
    private static var forcedTransport: NetworkTransport? {
        #if DEBUG
        switch AppGroup.defaults.string(forKey: "debugNetworkTransport") {
        case "wifi": return .wifi
        case "cellular": return .cellular
        case "other": return .other
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// 把 NWPath 翻成接入方式。
    ///
    /// `path.status != .satisfied` 时给 `.other` 而不是猜一个：路径没就绪的
    /// 瞬间（切网络、刚启动）本来就不该做任何拦截判断。
    ///
    /// 标 `nonisolated`：调用它的是 `NWPathMonitor` 的路径回调，跑在后台队列上，
    /// 拿不到主 actor。这个函数只读传入的 `path`、不碰任何实例状态，
    /// 天生就该是纯函数。
    nonisolated private static func transport(for path: NWPath) -> NetworkTransport {
        guard path.status == .satisfied else { return .other }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
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
