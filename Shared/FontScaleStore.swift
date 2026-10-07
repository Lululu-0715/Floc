import SwiftUI
import UIKit

/// 应用内字号档位。
///
/// 只做三档（小 / 标准 / 大），不做连续滑杆——字号这种东西用户试两下就选定，
/// 给一条滑杆只会让人反复拖。
///
/// 生效方式有两条，缺一不可：
///   1. 根视图上挂 `.environment(\.sizeCategory, ...)`，让所有走系统字体的
///      文字（`.body` / `.headline` / `.footnote` …）跟着缩放；
///   2. `SettingsMetrics` 里的固定字号乘上 `scale`，否则设置页
///      自己那套 `.system(size:)` 会纹丝不动——看起来就像开关没生效。
///
/// 刻意不把这个枚举放进 `FontScaleStore` 内部：`SettingsMetrics` 是纯静态
/// 工具，读档位时不该被 MainActor 隔离卡住。
enum FontScaleSize: String, CaseIterable, Identifiable {

    case small
    case standard
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small:    return AppLocalization.string("小")
        case .standard: return AppLocalization.string("标准")
        case .large:    return AppLocalization.string("大")
        }
    }

    /// 固定字号的缩放系数。
    ///
    /// 幅度刻意收敛：系统字体的档位差距本来就比这里大，
    /// 自定义字号再激进就会把设置页的行高撑破。
    var scale: CGFloat {
        switch self {
        case .small:    return 0.92
        case .standard: return 1.0
        case .large:    return 1.12
        }
    }

    /// 映射到系统动态字体档位。
    ///
    /// 「标准」刻意映射成**系统当前档位**而不是写死的 `.large`：用户在
    /// iOS 辅助功能里把字体调大过，我们不该在没动过设置的情况下把它压回去。
    /// 小 / 大 是明确覆盖，就按固定档位来。
    @MainActor
    var sizeCategory: ContentSizeCategory {
        switch self {
        case .small:    return .small
        case .standard:
            return ContentSizeCategory(UIApplication.shared.preferredContentSizeCategory) ?? .large
        case .large:    return .extraLarge
        }
    }

    /// 存储键。`SettingsMetrics` 要直接读它，所以放在这里统一维护。
    static let storageKey = "appFontScale"

    /// 从存储里读当前档位，读不到就是标准。
    static var current: FontScaleSize {
        let raw = AppGroup.defaults.string(forKey: storageKey)
        return raw.flatMap(FontScaleSize.init(rawValue:)) ?? .standard
    }
}

/// 字号的读写入口。
@MainActor
final class FontScaleStore: ObservableObject {

    static let shared = FontScaleStore()

    @Published var size: FontScaleSize {
        didSet {
            guard size != oldValue else { return }
            AppGroup.defaults.set(size.rawValue, forKey: FontScaleSize.storageKey)
            RuntimeLogger.info("APP", "FontScale", "字号已切换", details: [
                "size": size.rawValue,
            ])
        }
    }

    private init() {
        size = FontScaleSize.current
    }
}
