import XCTest
@testable import Floc

/// 内置测试卡密的契约测试。
///
/// 背景：授权服务端（Cloudflare Worker）还没部署时，唯一能走完
/// 「输入卡密 → 激活 → 看到倒计时」这条链路的入口就是内置测试卡密。
/// 它必须**完全离线**生效，不能偷偷依赖 `baseURL`，否则后端一挂
/// 自测入口也跟着废掉。
final class LicenseTestCardTests: XCTestCase {

    /// `LicenseManager.shared` 是单例，且状态落在 UserDefaults 里，
    /// 每个用例收尾都要把测试授权清掉，否则会污染后面的用例。
    @MainActor
    override func tearDown() async throws {
        await LicenseManager.shared.unbind()
        try await super.tearDown()
    }

    // MARK: - 输入规范化

    /// 用户手打时大小写、空格、全角连字符都可能不一样，
    /// 规范化不到位就会「明明输对了却说卡密无效」。
    func testNormalizeCardKey() {
        XCTAssertEqual(LicenseConfig.normalizeCardKey("floc-test-2026"), "FLOC-TEST-2026")
        XCTAssertEqual(LicenseConfig.normalizeCardKey("  FLOC-TEST-2026  "), "FLOC-TEST-2026")
        XCTAssertEqual(LicenseConfig.normalizeCardKey("FLOC TEST 2026"), "FLOC-TEST-2026")
        XCTAssertEqual(LicenseConfig.normalizeCardKey("FLOC—TEST—2026"), "FLOC-TEST-2026")
        XCTAssertEqual(LicenseConfig.normalizeCardKey("FLOC－TEST－2026"), "FLOC-TEST-2026")
        XCTAssertEqual(LicenseConfig.normalizeCardKey("   "), "")
    }

    func testTestCodeRecognition() {
        XCTAssertFalse(LicenseConfig.testCardKeys.isEmpty, "测试卡密表不应为空，否则自测入口消失")

        for key in LicenseConfig.testCardKeys {
            XCTAssertTrue(LicenseConfig.isTestCode(key))
            XCTAssertTrue(
                LicenseConfig.isTestCode(key.lowercased()),
                "测试卡密必须大小写不敏感"
            )
        }

        XCTAssertTrue(LicenseConfig.isTestCode(" floc-test-2026 "))
    }

    func testRealLookingCodeIsNotATestCode() {
        XCTAssertFalse(LicenseConfig.isTestCode("FLOC-ABCD-EFGH-IJKL"))
        XCTAssertFalse(LicenseConfig.isTestCode(""))
        XCTAssertFalse(LicenseConfig.isTestCode("FLOC-TEST"))   // 少一段
        XCTAssertFalse(LicenseConfig.isTestCode("FLOC-TEST-2027"))
    }

    /// 提示只在服务端没配好时出现——换成真实域名后必须自己消失，
    /// 否则正式包里会向用户露出一个后门入口。
    func testHintFollowsConfiguration() {
        XCTAssertEqual(LicenseConfig.showsTestCardHint, !LicenseConfig.isConfigured)
    }

    // MARK: - 离线激活

    /// 激活后应当直接可用，且状态名标成「测试授权」——
    /// 不能伪装成「已激活」，否则看不出这是自测状态。
    @MainActor
    func testActivatingWithTestCodeGrantsUsableLicense() async {
        let manager = LicenseManager.shared

        guard let key = LicenseConfig.testCardKeys.first else {
            return XCTFail("测试卡密表为空")
        }

        let ok = await manager.activate(cardKey: key)

        XCTAssertTrue(ok, "测试卡密必须能在离线状态下激活")
        XCTAssertNil(manager.lastErrorMessage)
        XCTAssertTrue(manager.isTestLicense)
        XCTAssertTrue(manager.isUsable, "激活后闸门必须放行")
        XCTAssertEqual(manager.displayNameKey, "测试授权")
        XCTAssertEqual(manager.cardTypeLabel, LicenseConfig.testCardTypeLabel)
        XCTAssertEqual(
            manager.remainingMs,
            Double(LicenseConfig.testCardDays) * 86_400_000,
            accuracy: 5_000,
            "剩余时长应当从授予那一刻起算"
        )
    }

    /// 小写 + 带空格的写法也要能激活，这是用户最容易打出来的形态。
    @MainActor
    func testActivatingIsCaseAndSpaceInsensitive() async {
        let manager = LicenseManager.shared

        guard let key = LicenseConfig.testCardKeys.first else {
            return XCTFail("测试卡密表为空")
        }

        let messy = " " + key.lowercased().replacingOccurrences(of: "-", with: " ") + " "
        // 先落成局部常量再断言：`await` 不能出现在 XCTAssert 的自动闭包里。
        let ok = await manager.activate(cardKey: messy)
        XCTAssertTrue(ok)
        XCTAssertTrue(manager.isTestLicense)
    }

    @MainActor
    func testEmptyCodeIsRejected() async {
        let manager = LicenseManager.shared
        let ok = await manager.activate(cardKey: "   ")
        XCTAssertFalse(ok)
        XCTAssertNotNil(manager.lastErrorMessage)
    }

    /// 解除测试授权后必须回到「未激活」，不能再放行。
    @MainActor
    func testUnbindClearsTestLicense() async {
        let manager = LicenseManager.shared

        guard let key = LicenseConfig.testCardKeys.first else {
            return XCTFail("测试卡密表为空")
        }

        _ = await manager.activate(cardKey: key)
        XCTAssertTrue(manager.isTestLicense)

        let cleared = await manager.unbind()
        XCTAssertTrue(cleared)
        XCTAssertFalse(manager.isTestLicense)
        XCTAssertEqual(manager.status, .unregistered)
        XCTAssertEqual(manager.remainingMs, 0)
        XCTAssertFalse(manager.status.isUsable)
    }
}
