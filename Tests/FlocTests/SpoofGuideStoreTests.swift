import XCTest
@testable import Floc

/// 「不再提示」开关的契约测试。
///
/// 这条开关的需求只有一句话：**点过一次之后，以后永远别再弹**。
/// 它对应的现场是 1.0.11 —— 提示挂在 `MapHomeView` 的 `@State` 上，
/// 生命周期跟视图走，冷启动必然归零，于是每次打开 App 都弹一遍。
/// 所以这里最要紧的一条是「重建 store 之后仍然是关着的」（等价下一次冷启动）。
@MainActor
final class SpoofGuideStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // 独立 suite 隔离，别碰真实存储（和 AppearanceStoreTests 同一套写法）。
        suiteName = "SpoofGuideStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> SpoofGuideStore {
        SpoofGuideStore(defaults: defaults)
    }

    /// 全新安装：该弹。
    func testPresentsByDefault() {
        let store = makeStore()
        XCTAssertTrue(store.shouldPresent, "没点过「不再提示」时引导应该会弹")
        XCTAssertFalse(store.isDismissed)
        XCTAssertEqual(store.openSettingsCount, 0)
    }

    /// 点「不再提示」当场关闭。
    func testDismissForeverClosesImmediately() {
        let store = makeStore()
        store.dismissForever()
        XCTAssertTrue(store.isDismissed)
        XCTAssertFalse(store.shouldPresent)
    }

    /// **最关键的一条**：关掉之后重建 store（等价下一次冷启动）仍然是关的。
    func testDismissSurvivesRestart() {
        makeStore().dismissForever()

        let nextLaunch = makeStore()
        XCTAssertFalse(nextLaunch.shouldPresent,
                       "重启之后又弹了 —— 说明开关没落盘（1.0.11 的原 bug）")
    }

    /// 重复点不该出错，也不该把值翻回去。
    func testDismissIsIdempotent() {
        let store = makeStore()
        store.dismissForever()
        store.dismissForever()

        XCTAssertTrue(store.isDismissed)
        XCTAssertFalse(makeStore().shouldPresent)
    }

    /// 「去设置」**不关闭**引导：下次开启虚拟定位还得提醒。
    /// 用户要的是点「不再提示」才永久关，跳设置只是去看一眼。
    func testOpenSettingsDoesNotDismiss() {
        let store = makeStore()
        store.noteOpenSettings()

        XCTAssertTrue(store.shouldPresent, "点「去设置」不该把引导关掉")
        XCTAssertFalse(store.isDismissed)
        XCTAssertEqual(store.openSettingsCount, 1)

        store.noteOpenSettings()
        XCTAssertEqual(store.openSettingsCount, 2)
        XCTAssertEqual(makeStore().openSettingsCount, 2, "计数也要落盘")
    }

    /// `reset()` 把开关恢复成「还会弹」，盘上不留残值。
    func testResetRestoresPresentation() {
        let store = makeStore()
        store.dismissForever()
        store.noteOpenSettings()

        store.reset()

        XCTAssertTrue(store.shouldPresent)
        XCTAssertFalse(store.isDismissed)
        XCTAssertEqual(store.openSettingsCount, 0)

        let nextLaunch = makeStore()
        XCTAssertTrue(nextLaunch.shouldPresent)
        XCTAssertEqual(nextLaunch.openSettingsCount, 0)
        XCTAssertFalse(
            defaults.bool(forKey: "spoofGuideDismissed"),
            "reset 之后盘上不该还留着 true"
        )
    }
}
