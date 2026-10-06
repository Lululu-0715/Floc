import SwiftUI

/// 界面外观偏好（跟随系统 / 白天 / 黑暗）。
///
/// 三个选项而不是常见的两个：只给「白天 / 黑暗」两个开关的话，
/// 用户想交还给系统就得先把开关拨回去，没有「跟随系统」这个状态。
/// `mode` 存的是字符串原始值，方便以后加新档位时不破坏已有数据。
@MainActor
final class AppearanceStore: ObservableObject {

    static let shared = AppearanceStore()

    /// 外观模式。
    enum Mode: String, CaseIterable, Identifiable {

        case system
        case light
        case dark

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return AppLocalization.string("跟随系统")
            case .light: return AppLocalization.string("白天")
            case .dark: return AppLocalization.string("黑暗")
            }
        }

        var systemImage: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max.fill"
            case .dark: return "moon.fill"
            }
        }

        /// 交给 `.preferredColorScheme`。nil 表示不干预，由系统决定。
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    private enum Key {
        static let mode = "appearanceMode"
    }

    private let defaults: UserDefaults

    @Published var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Key.mode)
            RuntimeLogger.info("APP", "Appearance", "外观模式已切换", details: [
                "mode": mode.rawValue,
            ])
        }
    }

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Key.mode) ?? Mode.system.rawValue
        mode = Mode(rawValue: stored) ?? .system
    }
}
