import SwiftUI
import XCTest
@testable import Floc

/// 字号档位（小 / 标准 / 大）的契约测试。
///
/// 这个值同时喂给两处：根节点的 `.environment(\.sizeCategory,)` 和
/// `SettingsMetrics` 里的固定字号。任一处读错，表现都是「设置里点了没反应」。
final class FontScaleTests: XCTestCase {

    func testSupportedSizes() {
        XCTAssertEqual(
            FontScaleSize.allCases.map(\.rawValue),
            ["small", "standard", "large"],
            "只应提供 小 / 标准 / 大 三档"
        )
    }

    func testScaleOrderingAndNeutralStandard() {
        XCTAssertLessThan(FontScaleSize.small.scale, FontScaleSize.standard.scale)
        XCTAssertLessThan(FontScaleSize.standard.scale, FontScaleSize.large.scale)
        XCTAssertEqual(FontScaleSize.standard.scale, 1.0, "标准档必须是 1.0，否则默认外观会被改动")
    }

    func testDisplayNameIsPresent() {
        for size in FontScaleSize.allCases {
            XCTAssertFalse(size.displayName.isEmpty, "\(size.rawValue) 缺少显示名")
        }
    }

    @MainActor
    func testSizeCategoryMapping() {
        // 「标准」跟随系统当前档位，因此只断言小 / 大是明确的覆盖值。
        XCTAssertEqual(FontScaleSize.small.sizeCategory, .small)
        XCTAssertEqual(FontScaleSize.large.sizeCategory, .extraLarge)
    }

    // MARK: - 存储

    /// `FontScaleSize.current` 读的是共享存储，测完要把值还原，
    /// 免得影响同一进程里其它用例。
    func testStoredValueIsRestoredAndUnknownFallsBack() {
        let key = FontScaleSize.storageKey
        let original = AppGroup.defaults.string(forKey: key)
        defer {
            if let original {
                AppGroup.defaults.set(original, forKey: key)
            } else {
                AppGroup.defaults.removeObject(forKey: key)
            }
        }

        AppGroup.defaults.set(FontScaleSize.large.rawValue, forKey: key)
        XCTAssertEqual(FontScaleSize.current, .large)

        AppGroup.defaults.set("gigantic", forKey: key)
        XCTAssertEqual(FontScaleSize.current, .standard, "无法识别的存档应退化为标准档")

        AppGroup.defaults.removeObject(forKey: key)
        XCTAssertEqual(FontScaleSize.current, .standard, "没有存档时默认标准档")
    }
}

/// 个人资料（昵称 / 头像）的展示契约。
///
/// 头像本身要落盘，单测里不碰文件系统；这里只锁住「没设置时显示什么」——
/// 那是设置页第一行一定会渲染到的东西，空着会很难看。
@MainActor
final class ProfileStoreTests: XCTestCase {

    private let store = ProfileStore.shared

    override func tearDown() {
        store.nickname = ""
        store.removeAvatar()
        super.tearDown()
    }

    func testEmptyNicknameFallsBackToPlaceholder() {
        store.nickname = ""
        XCTAssertFalse(store.hasNickname)
        XCTAssertEqual(store.displayName, AppLocalization.string("未设置昵称"))
    }

    func testWhitespaceOnlyNicknameIsTreatedAsEmpty() {
        store.nickname = "   "
        XCTAssertFalse(store.hasNickname)
        XCTAssertEqual(store.displayName, AppLocalization.string("未设置昵称"))
    }

    func testNicknameIsShownAsIs() {
        store.nickname = "阿锋"
        XCTAssertTrue(store.hasNickname)
        XCTAssertEqual(store.displayName, "阿锋")
    }

    func testAvatarInitialUsesFirstCharacterUppercased() {
        store.nickname = "floc"
        XCTAssertEqual(store.avatarInitial, "F")

        store.nickname = "阿锋"
        XCTAssertEqual(store.avatarInitial, "阿")

        store.nickname = "   "
        XCTAssertEqual(store.avatarInitial, "F", "空昵称应回退到品牌首字母")
    }
}

/// 设备码的展示形态。
final class DeviceIdentityTests: XCTestCase {

    func testDisplayCodeIsShortStableAndUppercase() {
        let code = DeviceIdentity.displayCode

        XCTAssertEqual(code.count, 8, "展示码固定 8 位，太长设置页那一行放不下")
        XCTAssertEqual(code, code.uppercased(), "展示码应统一大写")
        XCTAssertFalse(code.contains("-"), "展示码里不应残留 UUID 的连字符")
        XCTAssertEqual(code, DeviceIdentity.displayCode, "同一台设备多次读取必须一致")

        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF")
        XCTAssertNil(
            code.unicodeScalars.first { !allowed.contains($0) },
            "设备 ID 是 UUID，前 8 位应只含十六进制字符"
        )
    }

    func testFullIdentifierIsAUUID() {
        XCTAssertNotNil(UUID(uuidString: DeviceIdentity.current), "完整设备 ID 应是一个合法 UUID")
    }
}
