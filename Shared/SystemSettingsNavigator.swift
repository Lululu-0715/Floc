import Foundation
import UIKit

/// 把用户带到系统设置里的具体页面。
///
/// iOS 没有公开 API 能直接打开「当前 Wi-Fi 详情」，只能用 `App-Prefs` 私有
/// scheme 尽力而为。所有方法都会在打不开时回退到本应用的设置页，并返回
/// 是否成功直达，供界面提示用户「请手动前往」。
enum SystemSettingsNavigator {

    @discardableResult
    static func openWiFiSettings() -> Bool {
        open(candidates: [
            "App-Prefs:root=WIFI",
            "App-Prefs:root=WLAN",
        ], fallbackHint: "无线局域网")
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
                UIApplication.shared.open(url)
                RuntimeLogger.info("APP", "SettingsNavigator", "已跳转系统设置", details: [
                    "target": candidate,
                ])
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
