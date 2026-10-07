import SwiftUI
import XCTest
@testable import Floc

/// 未配置授权服务端时的「本地模式」契约测试。
///
/// 这一层解决的是很具体的一个问题：后端还没部署时，全新安装的包
/// 因为 `LicenseStatus.unregistered` 而 `isUsable == false`，
/// 虚拟定位按钮点不动、卡密又无处可激活——开发者自己都没法自测。
///
/// 契约有三条，缺一条就会退回那个死锁：
///   1. 仍是占位地址时 `isConfigured == false`；
///   2. 本地模式下 `isUsable == true`，闸门放行；
///   3. 展示名显示「本地模式」，而不是一个红锁「未激活」。
final class LicenseLocalModeTests: XCTestCase {

    // MARK: - 占位地址识别

    func testPlaceholderBaseURLIsNotConfigured() {
        XCTAssertTrue(
            LicenseConfig.baseURL.contains("YOUR-SUBDOMAIN"),
            "本用例假设仓库里仍是占位地址；换成真实域名后请连同本用例一起更新"
        )
        XCTAssertFalse(LicenseConfig.isConfigured, "占位地址不应被视为已配置")
    }

    func testConfiguredFlagFollowsTheMarker() {
        // 只验证判定规则本身：包含标记 → 未配置；换掉 → 已配置。
        func isConfigured(_ url: String) -> Bool {
            !url.isEmpty && !url.contains("YOUR-SUBDOMAIN")
        }

        XCTAssertFalse(isConfigured(""))
        XCTAssertFalse(isConfigured("https://floc-license.YOUR-SUBDOMAIN.workers.dev"))
        XCTAssertTrue(isConfigured("https://floc-license.abc.workers.dev"))
    }

    // MARK: - 闸门

    @MainActor
    func testLocalModeAllowsUsage() {
        let manager = LicenseManager.shared
        XCTAssertTrue(manager.isLocalMode, "占位地址下应处于本地模式")
        XCTAssertTrue(manager.isUsable, "本地模式必须放行，否则开发者自测不了")
        XCTAssertEqual(
            manager.displayNameKey,
            "本地模式",
            "本地模式不能再显示「未激活」的红锁，否则和能用的现状自相矛盾"
        )
    }

    func testUnderlyingStatusStillBlocksWhenNotLocal() {
        // 本地模式只是「放行」这一层的特例，状态枚举本身没被放宽。
        XCTAssertFalse(LicenseStatus.unregistered.isUsable)
        XCTAssertFalse(LicenseStatus.expired.isUsable)
        XCTAssertFalse(LicenseStatus.trialExpired.isUsable)
        XCTAssertTrue(LicenseStatus.active.isUsable)
        XCTAssertTrue(LicenseStatus.trial.isUsable)
        XCTAssertTrue(LicenseStatus.bonus.isUsable)
        XCTAssertTrue(LicenseStatus.offline.isUsable)
    }

    // MARK: - 剩余时长文案

    /// `3 天 3 小时 3 分钟` 这类文案每次打开设置页都会显示，
    /// 边界（刚好整小时、不足一分钟）最容易写错。
    ///
    /// 毫秒数都先算成常量：直接把长表达式塞进断言会让类型检查器超时。
    @MainActor
    func testDescribeRemaining() {
        let dayKey: String = AppLocalization.string("%ld 天 %ld 小时 %ld 分钟")
        let hourKey: String = AppLocalization.string("%ld 小时 %ld 分钟")
        let minuteKey: String = AppLocalization.string("%ld 分钟")

        // 直接写字面量而不是 `3 * 86_400 * 1000` 这类算式：
        // 常量折叠 + 自动类型推断堆在一起会让编译器超时。
        let threeDaysMs: Double = 270_180_000   // 3 天 3 小时 3 分钟
        let oneDayMs: Double = 86_400_000       // 刚好 1 天
        let twoHoursMs: Double = 7_200_000      // 刚好 2 小时
        let underOneMinuteMs: Double = 59_000   // 59 秒

        XCTAssertEqual(
            LicenseManager.describe(remainingMs: threeDaysMs),
            String(format: dayKey, 3, 3, 3)
        )

        // 刚好一天整：小时与分钟都要落到 0，而不是显示成 24 小时
        XCTAssertEqual(
            LicenseManager.describe(remainingMs: oneDayMs),
            String(format: dayKey, 1, 0, 0)
        )

        // 不足一天：走「小时 + 分钟」分支
        XCTAssertEqual(
            LicenseManager.describe(remainingMs: twoHoursMs),
            String(format: hourKey, 2, 0)
        )

        // 不足一分钟：分钟数为 0，仍然走分钟分支而不是「已到期」
        XCTAssertEqual(
            LicenseManager.describe(remainingMs: underOneMinuteMs),
            String(format: minuteKey, 0)
        )
    }

    @MainActor
    func testDescribeTreatsNonPositiveAsExpired() {
        let expired: String = AppLocalization.string("已到期")
        let zeroMs: Double = 0
        let negativeMs: Double = -1

        XCTAssertEqual(LicenseManager.describe(remainingMs: zeroMs), expired)
        XCTAssertEqual(LicenseManager.describe(remainingMs: negativeMs), expired)
    }
}
