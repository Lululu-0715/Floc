import SwiftUI
import XCTest
@testable import Floc

/// 外观偏好（跟随系统 / 白天 / 黑暗）的契约测试。
///
/// 这个值决定根节点的 `.preferredColorScheme`，一旦读写出错，
/// 要么用户的开关点了不生效，要么下次启动又跳回默认，属于很显眼的体验问题。
/// 用独立 `UserDefaults` suite 隔离，避免污染真实存储。
@MainActor
final class AppearanceStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppearanceStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> AppearanceStore {
        AppearanceStore(defaults: defaults)
    }

    // MARK: - 档位

    func testSupportedModes() {
        XCTAssertEqual(
            AppearanceStore.Mode.allCases.map(\.rawValue),
            ["system", "light", "dark"],
            "只应提供跟随系统 / 白天 / 黑暗三档"
        )
    }

    func testColorSchemeMapping() {
        XCTAssertNil(AppearanceStore.Mode.system.colorScheme, "跟随系统不应干预 colorScheme")
        XCTAssertEqual(AppearanceStore.Mode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceStore.Mode.dark.colorScheme, .dark)
    }

    func testDisplayNameAndIconArePresent() {
        for mode in AppearanceStore.Mode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode.rawValue) 缺少显示名")
            XCTAssertFalse(mode.systemImage.isEmpty, "\(mode.rawValue) 缺少图标")
        }
    }

    // MARK: - 默认值与持久化

    func testDefaultsToSystemWhenNothingStored() {
        XCTAssertEqual(makeStore().mode, .system, "首次启动应跟随系统")
    }

    func testInvalidStoredValueFallsBackToSystem() {
        defaults.set("midnight", forKey: "appearanceMode")
        XCTAssertEqual(makeStore().mode, .system, "无法识别的存档应退化为跟随系统")
    }

    func testStoredValueIsRestored() {
        defaults.set(AppearanceStore.Mode.dark.rawValue, forKey: "appearanceMode")
        XCTAssertEqual(makeStore().mode, .dark)
    }

    func testModeChangeIsPersisted() {
        let store = makeStore()
        store.mode = .light

        XCTAssertEqual(
            defaults.string(forKey: "appearanceMode"),
            AppearanceStore.Mode.light.rawValue,
            "切换后应立即写入存储"
        )

        // 重新构造一个实例，模拟下次启动
        XCTAssertEqual(makeStore().mode, .light, "重启后应恢复上次选择")
    }
}
