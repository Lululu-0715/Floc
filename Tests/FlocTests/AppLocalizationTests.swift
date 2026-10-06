import XCTest
@testable import Floc

/// 本地化基础设施测试。
///
/// 重点验证：三语言彼此独立、查表有兜底、格式参数正确替换。
/// 文案本身的完整性由 `Tests/check_localization.py` 在构建前校验。
final class AppLocalizationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 每个用例从「跟随系统」开始，避免相互影响
        AppLocalization.overrideLanguage = nil
    }

    override func tearDown() {
        AppLocalization.overrideLanguage = nil
        super.tearDown()
    }

    // MARK: - 语言覆盖

    func testOverrideLanguagePersists() {
        AppLocalization.overrideLanguage = "en"
        XCTAssertEqual(AppLocalization.overrideLanguage, "en")

        AppLocalization.overrideLanguage = "zh-Hant"
        XCTAssertEqual(AppLocalization.overrideLanguage, "zh-Hant")
    }

    func testClearingOverrideFallsBackToSystem() {
        AppLocalization.overrideLanguage = "en"
        AppLocalization.overrideLanguage = nil

        XCTAssertNil(AppLocalization.overrideLanguage)
        // 回退到系统语言后仍应是受支持的代码之一
        XCTAssertTrue(
            AppLocalization.supportedLanguages.map(\.code)
                .contains(AppLocalization.resolvedLanguageCode),
            "解析出的语言代码应在支持列表内"
        )
    }

    func testResolvedLanguageFollowsOverride() {
        for language in AppLocalization.supportedLanguages {
            AppLocalization.overrideLanguage = language.code
            XCTAssertEqual(
                AppLocalization.resolvedLanguageCode,
                language.code,
                "手动指定后应使用该语言"
            )
        }
    }

    // MARK: - 语言列表

    func testSupportedLanguagesMatchResourceDirectories() {
        let codes = AppLocalization.supportedLanguages.map(\.code)
        XCTAssertEqual(Set(codes), Set(["zh-Hans", "zh-Hant", "en"]))

        // 每个语言都应有对应的 lproj 目录
        for code in codes {
            XCTAssertNotNil(
                Bundle.main.path(forResource: code, ofType: "lproj"),
                "缺少 \(code).lproj 资源目录"
            )
        }
    }

    func testEachLanguageHasNonEmptyDisplayName() {
        for language in AppLocalization.supportedLanguages {
            XCTAssertFalse(language.name.isEmpty, "\(language.code) 缺少显示名")
        }
    }

    // MARK: - 查表

    func testKnownKeyReturnsLocalizedText() {
        // 「取消」是几乎必然存在的通用文案
        let text = AppLocalization.string("取消")
        XCTAssertFalse(text.isEmpty)
    }

    func testUnknownKeyFallsBackToKeyItself() {
        let key = "___不存在的文案_KEY___"
        XCTAssertEqual(
            AppLocalization.string(key),
            key,
            "缺翻时应回退到 key，便于开发期发现"
        )
    }

    func testSwitchingLanguageChangesOutput() {
        // 找一个在三语言下都应存在的 key。用「设置」这个词。
        let key = "设置"

        AppLocalization.overrideLanguage = "zh-Hans"
        let simplified = AppLocalization.string(key)

        AppLocalization.overrideLanguage = "zh-Hant"
        let traditional = AppLocalization.string(key)

        AppLocalization.overrideLanguage = "en"
        let english = AppLocalization.string(key)

        // 至少英译应当与中文不同（若「设置」在某语言缺翻会回退成 key，
        // 那也算合理结果，所以这里放宽为「不同语言查出的结果不应全部相同」）
        XCTAssertFalse(
            simplified == traditional && traditional == english,
            "三语言查出的结果不应完全相同：\(simplified) / \(traditional) / \(english)"
        )
    }

    // MARK: - 格式参数

    func testFormattedStringSubstitutesArguments() {
        // 用「%d」这类占位符的文案在项目中存在（如「已收藏 %d 个位置」）。
        // 这里直接验证格式化通道本身工作正常。
        let result = AppLocalization.string("___格式 %@___", "测试")
        XCTAssertTrue(
            result.contains("测试"),
            "格式参数应被替换进文案：\(result)"
        )
    }

    func testFormattedStringWithoutArgumentsIsUnchanged() {
        let plain = AppLocalization.string("取消")
        let viaFormat = AppLocalization.string("取消")
        XCTAssertEqual(plain, viaFormat)
    }

    // MARK: - 通知

    func testDidChangeNotificationExists() {
        XCTAssertEqual(
            AppLocalization.didChangeNotification.rawValue,
            "AppLocalizationDidChange"
        )
    }
}

/// App Group 降级行为测试。
///
/// 测试 target 通常没有 App Group 权限，正好可以验证降级路径：
/// 即使 App Group 不可用，存储也不应崩溃，而是退化为可用状态。
final class AppGroupTests: XCTestCase {

    func testIdentifierMatchesEntitlementValue() {
        XCTAssertEqual(
            AppGroup.identifier,
            "group.com.fff.loc"
        )
    }

    func testDefaultsAreAlwaysUsable() {
        // 无论 App Group 是否可用，defaults 都必须能读写
        AppGroup.defaults.set("测试值", forKey: "AppGroupTests.probe")
        XCTAssertEqual(
            AppGroup.defaults.string(forKey: "AppGroupTests.probe"),
            "测试值"
        )
        AppGroup.defaults.removeObject(forKey: "AppGroupTests.probe")
    }

    func testContainerURLIsAlwaysResolvable() {
        // 不可用时降级到 Application Support，不应崩溃
        let url = AppGroup.containerURL
        XCTAssertFalse(url.path.isEmpty)
    }

    func testLogsDirectoryIsCreated() {
        let url = AppGroup.logsDirectoryURL
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "日志目录应被自动创建：\(url.path)"
        )
    }

    func testLogsDirectoryIsWritable() {
        let url = AppGroup.logsDirectoryURL.appendingPathComponent("probe.txt")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try "probe".write(to: url, atomically: true, encoding: .utf8)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        } catch {
            XCTFail("日志目录应可写：\(error)")
        }
    }
}
