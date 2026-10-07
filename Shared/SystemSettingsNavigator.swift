import Foundation
import UIKit

/// 把用户带到系统设置里的具体页面。
///
/// iOS 没有公开 API 能直接打开「当前 Wi-Fi 详情」或「配置代理」那一屏，
/// 只能用 `App-Prefs` 私有 scheme 尽力而为。已知的现实：
///
///   - `App-Prefs:root=WIFI` 能打开「无线局域网」列表，**但进不了某一网络的
///     详情页，更进不了「配置代理」**——那一层没有可用的 URL；
///   - `App-Prefs:root=Privacy&path=LOCATION` 能落到「定位服务」，
///     但这条路径在版本之间改过好几次，所以下面每个方法都排了一串候选；
///   - iOS 16 起这些私有 scheme 越来越不稳，部分版本会落到设置首页。
///
/// **`canOpenURL` 不能拿来当闸门。** iOS 18 起它对 `App-Prefs` 一律返回
/// false，但直接 `open` 仍然能跳到目标页；用 `canOpenURL` 判断会把「能用」
/// 误判成「不支持」，然后退到本应用的设置页——用户看到的正是
/// 「点定位服务，结果跳到的是 Floc 自己在设置里的那一屏」。所以这里
/// 逐个直接 `open`，按系统的完成回调判断到底哪个候选被接受了。
///
/// 即便跳转成功，也只代表「到了那一屏附近」（系统可能只打开设置首页），
/// 所以**调用方必须始终把手动路径写出来**，别让用户以为跳准了。
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
            "prefs:root=Privacy&path=LOCATION",
            "App-Prefs:root=LOCATION_SERVICES",
            "App-Prefs:root=Privacy",
        ], fallbackHint: "隐私与安全性 → 定位服务")
    }

    @discardableResult
    static func openCertificateTrustSettings() -> Bool {
        CertificateTrustVerifier.openTrustSettings()
    }

    @discardableResult
    static func openAppSettings() -> Bool {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
        UIApplication.shared.open(url)
        return true
    }

    /// 依次尝试候选地址，返回「是否至少有一个被系统接受」。
    ///
    /// 完成回调是异步的，所以这里的返回值只能理解成「已经发出跳转请求」；
    /// 真正被拒时会在回调里补记一条日志，并继续退到设置首页。
    @discardableResult
    private static func open(candidates: [String], fallbackHint: String) -> Bool {
        var remaining = candidates

        func attempt() {
            guard let candidate = remaining.first else {
                RuntimeLogger.warn("APP", "SettingsNavigator", "无法直达系统设置页", details: [
                    "target": fallbackHint,
                ])
                openSettingsRoot()
                return
            }
            remaining.removeFirst()

            guard let url = URL(string: candidate) else {
                attempt()
                return
            }

            UIApplication.shared.open(url, options: [:]) { success in
                RuntimeLogger.info("APP", "SettingsNavigator", success ? "已跳转系统设置" : "系统设置跳转被拒", details: [
                    "target": candidate,
                ])
                if !success { attempt() }
            }
        }

        attempt()
        return true
    }

    /// 退而求其次：只把「设置」App 打开，不指定子页面。
    ///
    /// 最后一步才是官方的应用设置页——它落在 Floc 自己那一屏，严格说不是
    /// 要去的地方，但那是唯一保证可用的入口，用户至少能从这里往上返回。
    private static func openSettingsRoot() {
        let candidates = ["App-Prefs:root", "prefs:root"]
        var remaining = candidates

        func attempt() {
            guard let candidate = remaining.first else {
                openAppSettings()
                return
            }
            remaining.removeFirst()

            guard let url = URL(string: candidate) else {
                attempt()
                return
            }

            UIApplication.shared.open(url, options: [:]) { success in
                if !success { attempt() }
            }
        }

        attempt()
    }
}
