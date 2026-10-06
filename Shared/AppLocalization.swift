import Foundation

/// 应用内文案的多语言查表。
///
/// 之所以不用 `NSLocalizedString` 的宏形式，是因为文案需要在运行时按设备语言
/// 动态切换（设置页里可以手动改语言），宏会在编译期固化查询方式。
enum AppLocalization {

    /// 当前生效的语言。`nil` 表示跟随系统。
    static var overrideLanguage: String? {
        get { UserDefaults.standard.string(forKey: languageKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: languageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: languageKey)
            }
            cachedBundle = nil
        }
    }

    private static let languageKey = "appLanguageOverride"
    private static var cachedBundle: Bundle?

    /// 支持的语言代码，与 Resources 下的 lproj 目录一一对应。
    static let supportedLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("en", "English"),
    ]

    /// 跟随系统时的实际语言代码。
    static var resolvedLanguageCode: String {
        if let override = overrideLanguage {
            return override
        }
        for preferred in Locale.preferredLanguages {
            if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") {
                return "zh-Hant"
            }
            if preferred.hasPrefix("zh") {
                return "zh-Hans"
            }
            if preferred.hasPrefix("en") {
                return "en"
            }
        }
        return "zh-Hans"
    }

    private static var bundle: Bundle {
        if let cachedBundle {
            return cachedBundle
        }
        let code = resolvedLanguageCode
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let localized = Bundle(path: path) {
            cachedBundle = localized
            return localized
        }
        cachedBundle = .main
        return .main
    }

    /// 查一条文案。找不到时回退到 key 本身，方便开发期发现漏翻。
    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// 带格式参数的文案。
    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }

    /// 语言变化通知名，供界面刷新。
    static let didChangeNotification = Notification.Name("AppLocalizationDidChange")
}
