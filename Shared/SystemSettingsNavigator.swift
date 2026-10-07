import Foundation
import UIKit

/// 把用户带到系统设置里的具体页面。
///
/// iOS 没有公开 API 能直接打开「当前 Wi-Fi 详情」或「配置代理」那一屏，
/// 只能用 `App-Prefs` 私有 scheme 尽力而为。已知的现实：
///
///   - `App-Prefs:root=WIFI` 能打开「无线局域网」列表，**但进不了某一网络的
///     详情页，更进不了「配置代理」**——那一层没有可用的 URL；
///   - iOS 16 起这些私有 scheme 越来越不稳，部分版本会落到设置首页；
///   - `canOpenURL` 只代表 scheme 被声明过（见 Info.plist 的
///     `LSApplicationQueriesSchemes`），**不代表那个页面真的存在**。
///
/// 所以所有方法的返回值语义是「已经尽力跳转」，不是「跳准了」。
/// 调用方应当同时把手动路径写出来，让用户能自己走完最后两下。
enum SystemSettingsNavigator {

    @discardableResult
    static func openWiFiSettings() -> Bool {
        open(candidates: [
            "App-Prefs:root=WIFI",
            "App-Prefs:root=WLAN",
            "prefs:root=WIFI",
        ], fallbackHint: "无线局域网")
    }

    @discardableResult
    static func openLocationServices() -> Bool {
        open(candidates: [
            "App-Prefs:root=Privacy&path=LOCATION",
            "App-Prefs:root=PRIVACY&path=LOCATION",
            "App-Prefs:root=Privacy",
        ], fallbackHint: "隐私与安全性 → 定位服务")
    }

    @discardableResult
    static func openCertificateTrustSettings() -> Bool {
        CertificateTrustVerifier.openTrustSettings()
    }

    @discardableResult
    static func openVPNDeviceManagement() -> Bool {
        open(candidates: [
            "App-Prefs:root=General&path=ManagedConfigurationList",
            "App-Prefs:root=General",
        ], fallbackHint: "VPN 与设备管理")
    }

    @discardableResult
    static func openAppSettings() -> Bool {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
        UIApplication.shared.open(url)
        return true
    }

    private static func open(candidates: [String], fallbackHint: String) -> Bool {
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url) { success in
                    // 回调在后台线程，日志本身是线程安全的。
                    RuntimeLogger.info("APP", "SettingsNavigator", success ? "已跳转系统设置" : "系统设置跳转被拒", details: [
                        "target": candidate,
                    ])
                }
                return true
            }
        }

        RuntimeLogger.warn("APP", "SettingsNavigator", "无法直达系统设置页", details: [
            "target": fallbackHint,
        ])
        // 回退到应用设置页，至少让用户能一键跳进设置 App。
        openAppSettings()
        return false
    }
}
