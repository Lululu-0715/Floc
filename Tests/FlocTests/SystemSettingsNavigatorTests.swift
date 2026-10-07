import Foundation
import XCTest
@testable import Floc

/// 系统设置跳转的契约测试。
///
/// 这类跳转只有真机才能验证「到底有没有停在那一屏」，但**候选表的顺序**是可以
/// 静态钉死的，而顺序恰恰是关键：新系统（iOS 26+）上老的 `App-Prefs` 会被系统
/// 兜底成「打开发起请求的那个 App 自己的设置页」，`open` 照样回调成功，现象和
/// 跳对了几乎一模一样。顺序写反，回归时肉眼根本发现不了——
/// 这正是 1.0.6 用户反馈「iOS 27 beta 3 上跳转全进了设置里的 App 那一屏」的形态。
final class SystemSettingsNavigatorTests: XCTestCase {

    private let ios26Prefix = "settings-navigation://"
    private let legacyPrefix = "App-Prefs:"

    /// 候选表不能空。
    func testEveryTargetHasCandidates() {
        for target in SystemSettingsNavigator.Target.allCases {
            XCTAssertFalse(target.candidates.isEmpty, "\(target) 没有任何候选地址")
        }
    }

    /// 每个目标的第一条都必须是 iOS 26 的 `settings-navigation://`。
    ///
    /// 老系统上这条会直接失败（scheme 未注册，`open` 回调 false）然后自然往后落，
    /// 没有副作用；反过来把老 scheme 放前面，新系统上就会静默走错屏。
    func testiOS26RouteComesFirst() {
        for target in SystemSettingsNavigator.Target.allCases {
            let first = target.candidates.first ?? ""
            XCTAssertTrue(
                first.hasPrefix(ios26Prefix),
                "\(target) 的第一条候选不是 iOS 26 路线，新系统上会静默落到本应用设置页：\(first)"
            )
        }
    }

    /// 每个目标都得保留老路线，否则 iOS 16 会退化——那是用户实机确认过可用的。
    func testLegacyRouteKept() {
        for target in SystemSettingsNavigator.Target.allCases {
            XCTAssertTrue(
                target.candidates.contains { $0.hasPrefix(legacyPrefix) },
                "\(target) 丢掉了 \(legacyPrefix) 老路线，iOS 16 会跟着退化"
            )
        }
    }

    /// 候选地址必须都能被 `URL(string:)` 解析。
    ///
    /// 跳转实现里 `guard let url = URL(string: candidate) else { attempt(); return }`
    /// 会把解析失败的候选静默跳过，看起来就像「这条本来就无效」。
    func testAllCandidatesAreParsable() {
        for target in SystemSettingsNavigator.Target.allCases {
            for candidate in target.candidates {
                XCTAssertNotNil(URL(string: candidate), "无法解析成 URL：\(candidate)")
            }
        }
    }

    /// 定位服务：iOS 26 与 iOS 16 两条路线都必须在。
    func testLocationServicesRoutes() {
        let candidates = SystemSettingsNavigator.Target.locationServices.candidates

        XCTAssertTrue(
            candidates.contains("settings-navigation://com.apple.Settings.PrivacyAndSecurity/LOCATION"),
            "缺少 iOS 26 的定位服务直达地址"
        )
        XCTAssertTrue(
            candidates.contains("App-Prefs:root=Privacy&path=LOCATION"),
            "iOS 16 实机验证过这条，不能删"
        )
    }

    /// 无线局域网：必须包含「当前网络详情页」——填代理服务器地址就在那一屏。
    func testWiFiRoutesIncludeCurrentNetworkDetail() {
        let candidates = SystemSettingsNavigator.Target.wifi.candidates

        XCTAssertEqual(
            candidates.first,
            "settings-navigation://com.apple.Settings.WiFi/NetworkDetails",
            "第一条应该是当前网络详情页，否则用户还得自己点一下 ⓘ"
        )
        XCTAssertTrue(candidates.contains("App-Prefs:root=WIFI"), "iOS 16 靠这条")
    }

    /// 证书信任设置用的是设置内部的 specifier 名，不是页面标题。
    ///
    /// 老代码写成 `About/CertificateTrustSettings`，那是页面标题，从来解析不到。
    func testCertificateTrustUsesSpecifierName() {
        let candidates = SystemSettingsNavigator.Target.certificateTrust.candidates

        XCTAssertEqual(
            candidates.first,
            "settings-navigation://com.apple.Settings.General/About/CERT_TRUST_SETTINGS"
        )

        for candidate in candidates {
            XCTAssertFalse(
                candidate.contains("CertificateTrustSettings"),
                "`CertificateTrustSettings` 是页面标题，不是可解析的 specifier：\(candidate)"
            )
        }
    }

    /// 跳转失败时要靠手动路径兜底，所以每个目标都得有提示文案。
    func testFallbackHintsArePresent() {
        for target in SystemSettingsNavigator.Target.allCases {
            XCTAssertFalse(target.fallbackHint.isEmpty, "\(target) 缺少手动路径提示")
        }
    }
}
