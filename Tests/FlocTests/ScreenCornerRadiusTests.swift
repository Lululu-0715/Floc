import XCTest
import UIKit
@testable import Floc

/// 屏幕圆角与「跟屏幕同心的大卡片圆角」。
///
/// 背景：1.0.13 把底部大卡片的圆角写死成 44（= 屏幕 55 − 留边 12），
/// 而 55 只是 iPhone 14 Pro / 15 / 16 那一代的屏幕圆角 —— 用户手上的
/// **16 Pro Max 是 62**，同心值应当是 50。差这 6pt，两条弧的圆心就错开 6pt，
/// 用户的反馈是「卡片下面两个圆角跟我的 16 Pro Max 手机圆角不协调」。
///
/// 这里锁三件事：
///
///   1. 兜底表里**主力机型一个都不能漏**（尤其 16 Pro / 16 Pro Max 那组 62）；
///   2. 大卡片圆角与屏幕圆角**共圆心**（半径差正好等于卡片留边）；
///   3. 内层圆角不会超过 46pt 主按钮的半高 —— 超了会被系统夹回胶囊，
///      同心就名存实亡。
final class ScreenCornerRadiusTests: XCTestCase {

    // MARK: - 兜底表

    /// 公开实测值，逐组抽查。改这张表要先改这里，别悄悄把某代机器归错组。
    func testFallbackTableCoversKnownDevices() {
        let expectations: [(identifier: String, radius: CGFloat, note: String)] = [
            ("iPhone11,8", 41.5, "XR / 11"),
            ("iPhone13,1", 44, "12 mini / 13 mini"),
            ("iPhone14,5", 47.33, "12 / 13 / 14 / 16e 那一组"),
            ("iPhone13,4", 53.33, "12 Pro Max / 13 Pro Max / 14 Plus"),
            ("iPhone15,4", 55, "15"),
            ("iPhone16,2", 55, "15 Pro Max"),
            ("iPhone17,1", 62, "16 Pro"),
            ("iPhone17,2", 62, "16 Pro Max —— 用户报的那台"),
        ]

        for expectation in expectations {
            XCTAssertEqual(
                ScreenCornerRadius.tableRadius(for: expectation.identifier),
                expectation.radius,
                "\(expectation.identifier)（\(expectation.note)）的屏幕圆角不对 —— "
                + "兜底表和运行时读到的值必须一致"
            )
        }
    }

    /// 表里没有的机型（以后新出的）返回 nil，由 `fallback` 兜住 ——
    /// 不能返回 0，那会让卡片圆角变成负的。
    func testUnknownDeviceHasNoTableEntry() {
        XCTAssertNil(ScreenCornerRadius.tableRadius(for: "iPhone99,9"))
        XCTAssertNil(ScreenCornerRadius.tableRadius(for: "arm64"), "模拟器不该命中机型表")
    }

    /// 无论走哪条路，拿到的屏幕圆角都在合理区间里。
    ///
    /// 顺带把三个值打出来：跑在模拟器上时这就是「运行时读私有属性到底成不成」
    /// 的现场证据（读到 62 说明读得动，读到 55 说明走了兜底）。
    func testResolvedRadiusIsWithinSaneRange() {
        let value = ScreenCornerRadius.value
        print("[DUMP] 屏幕圆角=\(value) 卡片圆角=\(GlassMetrics.mapPanelCornerRadius) "
              + "内容留边=\(GlassMetrics.mapPanelContentInset)")

        XCTAssertGreaterThanOrEqual(value, ScreenCornerRadius.minimum,
                                    "屏幕圆角低于下限，直角屏算出来会是负数")
        XCTAssertLessThanOrEqual(value, 100, "屏幕圆角被读成了奇怪的数量级")
    }

    // MARK: - 大卡片跟屏幕同心

    /// 同心判据很直白：卡片到屏幕外沿的留边，必须正好等于两个半径之差。
    func testPanelRadiusIsConcentricWithScreen() {
        XCTAssertEqual(
            GlassMetrics.mapPanelCornerRadius + GlassMetrics.mapPanelEdgeInset,
            ScreenCornerRadius.value,
            accuracy: 0.001,
            "卡片圆角 + 留边 ≠ 屏幕圆角 —— 两条弧的圆心又错开了"
        )
    }

    /// 16 Pro Max（屏幕 62）上应当是 50 / 27 / 内层 23。
    ///
    /// 这组数是本轮的验收标准：用户说「数值有问题那这个卡片相应的都要改」，
    /// 改的就是这三个。这里刻意写**字面量**（而不是拿常量再算一遍），
    /// 否则改坏常量时用例会跟着一起变，等于没锁。
    func testReferenceDeviceNumbers() {
        let screen: CGFloat = 62
        let card = screen - 12                              // mapPanelEdgeInset
        let content = max(card - 23, 20)                    // buttonCornerRadius
        let inner = GlassMetrics.concentric(outer: card, inset: content)

        XCTAssertEqual(GlassMetrics.mapPanelEdgeInset, 12, "卡片留边被改了")
        XCTAssertEqual(GlassMetrics.buttonCornerRadius, 23, "主按钮圆角被改了")
        XCTAssertEqual(card, 50, "16 Pro Max 的卡片圆角应当是 50")
        XCTAssertEqual(content, 27, "内容留边跟着圆角走，应当是 27")
        XCTAssertEqual(inner, GlassMetrics.buttonCornerRadius,
                       "内层圆角应当正好等于主按钮的半高（两条弧相切）")
    }

    /// 逐机型扫一遍：内容留边不会小于 20，内层圆角不会超过按钮半高。
    ///
    /// 超过半高会被系统夹回胶囊 —— 那时按钮的弧跟卡片内壁的弧就不再同心了。
    func testInnerRadiusNeverExceedsButtonHalfHeight() {
        let screenRadii: [CGFloat] = [39, 41.5, 44, 47.33, 53.33, 55, 62]

        for radius in screenRadii {
            let card = radius - GlassMetrics.mapPanelEdgeInset
            let content = max(card - GlassMetrics.buttonCornerRadius, 20)
            let inner = GlassMetrics.concentric(outer: card, inset: content)

            XCTAssertGreaterThanOrEqual(content, 20,
                                        "屏幕 \(radius)：内容留边小于 20，文字会贴边")
            XCTAssertLessThanOrEqual(
                inner, GlassMetrics.buttonCornerRadius,
                "屏幕 \(radius)：内层圆角 \(inner) 超过主按钮半高，会被系统夹回胶囊"
            )
        }
    }

    /// 运行时的两个派生值必须就是上面那套式子（防止有人给卡片单独写一个数）。
    func testRuntimeValuesFollowTheFormula() {
        XCTAssertEqual(
            GlassMetrics.mapPanelCornerRadius,
            ScreenCornerRadius.value - GlassMetrics.mapPanelEdgeInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            GlassMetrics.mapPanelContentInset,
            max(GlassMetrics.mapPanelCornerRadius - GlassMetrics.buttonCornerRadius, 20),
            accuracy: 0.001
        )
    }
}
