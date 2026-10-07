import Foundation
import UIKit

/// 把用户带到系统设置里的具体页面。
///
/// iOS 没有公开 API 能直接打开「当前 Wi-Fi 详情」或「配置代理」那一屏，
/// 只能用私有 scheme 尽力而为。现存的 scheme 有三代，每个目标的候选都按
/// 「新一代优先」排序：
///
///   1. `settings-navigation://com.apple.Settings.<模块>[/<子页>]`
///      iOS 26 起 Settings 启用的导航协议，目标是设置内部的模块标识。
///      社区在 iOS 26 上抓出来的当前有效形式，也是唯一能进「当前网络详情页」
///      （`.../WiFi/NetworkDetails` ＝ 填代理服务器地址的那一屏）的路径。
///   2. `App-Prefs:root=<根>&path=<子页>`
///      iOS 10 ~ 25 一直在用，iOS 16 实测可用。
///   3. `prefs:root=<根>&path=<子页>`
///      最早的一代，现在基本只剩历史意义。
///
/// **为什么把最新的放在最前面**：新系统上老 scheme 会被系统做「安全兜底」——
/// 解析不到目标就落到**发起请求的那个 App 自己的设置页**。那正是最让人困惑的
/// 结果：用户点「打开定位服务」，看到的却是 Floc 在设置里的那一屏，还以为是
/// 程序跳错了。反过来，老系统上 `settings-navigation://` 根本没注册，
/// `open` 会返回 false 然后自然往后落，不会造成任何损失（iOS 18.4 模拟器实测
/// 报的是 `kLSApplicationNotFound`，即 scheme 未注册）。
///
/// **`canOpenURL` 不能拿来当闸门。** 两个坑都踩过：
///   - iOS 18 起它对 `App-Prefs` 一律返回 false，但直接 `open` 仍然能跳到目标页，
///     用 `canOpenURL` 判断会把「能用」误判成「不支持」；
///   - 对这些 scheme 本来就要求在 Info.plist 里逐条声明
///     `LSApplicationQueriesSchemes`，漏一条就静默失效。
/// 所以这里逐个直接 `open`，按系统的完成回调判断到底哪个候选被接受了。
/// （只有 `canOpenURL` 需要声明 scheme，`open` 不需要。）
///
/// 即便跳转成功，也只代表「到了那一屏附近」（系统可能只打开设置首页），
/// 所以**调用方必须始终把手动路径写出来**，别让用户以为跳准了。
enum SystemSettingsNavigator {

    // MARK: - 目标与候选

    /// 系统设置里的一个目标。
    ///
    /// 把候选表放在这里而不是散在各个方法里，是为了让单测能直接钉住
    /// 「每个目标的第一条必须是 iOS 26 的 `settings-navigation://`」——
    /// 这条顺序错了，新系统上就会静默落到本应用设置页，而现象和「跳转成功」
    /// 一模一样，靠肉眼回归根本看不出来。
    enum Target: CaseIterable {
        /// 「无线局域网 →（当前网络）→ 配置代理」。
        ///
        /// 第一条是 iOS 26 才有的「当前网络详情页」，正是要填 127.0.0.1:8888 的那一屏；
        /// 老系统没有这条，会退到「无线局域网」列表，用户再自己点一下 ⓘ。
        case wifi

        /// 「隐私与安全性 → 定位服务」。
        case locationServices

        /// 「通用 → 关于本机 → 证书信任设置」。
        case certificateTrust

        /// 设置首页。只当前面全部失败时的兜底，不该被业务直接调用。
        case settingsRoot

        /// 跳不到时写给用户看的手动路径，同时也是日志里的 target 名。
        var fallbackHint: String {
            switch self {
            case .wifi: return "无线局域网"
            case .locationServices: return "隐私与安全性 → 定位服务"
            case .certificateTrust: return "通用 → 关于本机 → 证书信任设置"
            case .settingsRoot: return "设置首页"
            }
        }

        /// 候选地址，从新到旧。
        var candidates: [String] {
            switch self {
            case .wifi:
                return [
                    "settings-navigation://com.apple.Settings.WiFi/NetworkDetails",
                    "settings-navigation://com.apple.Settings.WiFi",
                    "App-Prefs:root=WIFI",
                    "prefs:root=WIFI",
                ]

            case .locationServices:
                return [
                    "settings-navigation://com.apple.Settings.PrivacyAndSecurity/LOCATION",
                    "settings-navigation://com.apple.Settings.PrivacyAndSecurity",
                    "App-Prefs:root=Privacy&path=LOCATION",
                    "prefs:root=Privacy&path=LOCATION",
                    "App-Prefs:root=Privacy",
                ]

            case .certificateTrust:
                // 第二条用的是设置内部的 specifier 名 `CERT_TRUST_SETTINGS`；
                // 老代码写的 `CertificateTrustSettings` 只是页面标题，从来不是
                // 可解析的标识，所以那一条从来没跳过。
                return [
                    "settings-navigation://com.apple.Settings.General/About/CERT_TRUST_SETTINGS",
                    "App-Prefs:root=General&path=About/CERT_TRUST_SETTINGS",
                    "App-Prefs:root=General&path=About",
                    "App-Prefs:root=General",
                ]

            case .settingsRoot:
                return [
                    "settings-navigation://com.apple.Settings",
                    "App-Prefs:root",
                    "prefs:root",
                ]
            }
        }
    }

    // MARK: - 对外入口

    @discardableResult
    static func openWiFiSettings() -> Bool {
        open(.wifi)
    }

    @discardableResult
    static func openLocationServices() -> Bool {
        open(.locationServices)
    }

    @discardableResult
    static func openCertificateTrustSettings() -> Bool {
        open(.certificateTrust)
    }

    /// 本应用自己的设置页。这是唯一保证可用的入口，只该当最后的兜底。
    @discardableResult
    static func openAppSettings() -> Bool {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
        UIApplication.shared.open(url)
        return true
    }

    // MARK: - 跳转实现

    /// 按顺序试候选；全部被拒时退到设置首页，再不行才退到本应用设置页。
    @discardableResult
    static func open(_ target: Target) -> Bool {
        open(candidates: target.candidates, fallbackHint: target.fallbackHint) {
            openSettingsRoot()
        }
    }

    /// 只把「设置」App 打开，不指定子页面。
    private static func openSettingsRoot() {
        open(
            candidates: Target.settingsRoot.candidates,
            fallbackHint: Target.settingsRoot.fallbackHint
        ) {
            RuntimeLogger.warn("APP", "SettingsNavigator", "设置首页也打不开，退到本应用设置页", details: [
                "ios": UIDevice.current.systemVersion,
            ])
            openAppSettings()
        }
    }

    /// 依次尝试候选地址，返回「是否已发出跳转请求」。
    ///
    /// 完成回调是异步的，所以返回值只能理解成「已经发出请求」；真正被拒时会在
    /// 回调里补一条日志，继续试下一个候选，全部被拒才执行 `onExhausted`。
    ///
    /// 日志里带上命中的具体地址与系统版本：`settings-navigation://` 在老系统上
    /// 没注册、在新系统上才有效，这两个字段是判断「用户那台机器到底走到哪一步」
    /// 的唯一线索。
    @discardableResult
    private static func open(
        candidates: [String],
        fallbackHint: String,
        onExhausted: @escaping () -> Void
    ) -> Bool {
        var remaining = candidates

        func attempt() {
            guard let candidate = remaining.first else {
                RuntimeLogger.warn("APP", "SettingsNavigator", "无法直达系统设置页", details: [
                    "target": fallbackHint,
                    "ios": UIDevice.current.systemVersion,
                ])
                onExhausted()
                return
            }
            remaining.removeFirst()

            guard let url = URL(string: candidate) else {
                attempt()
                return
            }

            UIApplication.shared.open(url, options: [:]) { success in
                RuntimeLogger.info("APP", "SettingsNavigator", success ? "已跳转系统设置" : "系统设置跳转被拒", details: [
                    "target": fallbackHint,
                    "url": candidate,
                    "ios": UIDevice.current.systemVersion,
                ])
                if !success { attempt() }
            }
        }

        attempt()
        return true
    }
}
