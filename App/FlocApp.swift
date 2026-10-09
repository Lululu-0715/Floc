import SwiftUI

@main
struct FlocApp: App {

    @StateObject private var setup = SetupCoordinator()
    @StateObject private var appearance = AppearanceStore.shared
    @StateObject private var theme = ThemeStore.shared
    #if !PURE_BUILD
    @StateObject private var license = LicenseManager.shared
    #endif
    @StateObject private var fontScale = FontScaleStore.shared

    init() {
        // 启动时清理过期日志，避免容器无限增长。
        RuntimeLogger.purgeExpiredLogs()
        RuntimeLogger.info("APP", "Lifecycle", "应用启动", details: [
            "version": Bundle.main.appVersion,
            "build": Bundle.main.buildNumber,
            "system": UIDevice.current.systemVersion,
            "core": CoreBridge.coreVersion,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView(setup: setup)
                .environmentObject(setup)
                #if !PURE_BUILD
                .environmentObject(license)
                #endif
                // 外观在根节点统一施加：设置页里改一档，整个应用（含已经
                // 打开的 sheet 和导航栈）立刻跟着变，不用逐页传值。
                //
                // 两处都要给：`.preferredColorScheme` 管 SwiftUI 侧的环境值，
                // 窗口那一层（`syncingWindowAppearance`）才能把新的 trait
                // 送进**已经弹出来的 sheet**——只挂前者的话，在设置页里改外观
                // 不会立刻生效，退出重进才行（1.0.11 的用户反馈）。
                .preferredColorScheme(appearance.mode.colorScheme)
                .syncingWindowAppearance(appearance.mode.colorScheme)
                // 配色主题的强调色同样挂在根节点：`.tint` 管系统控件
                // （开关、段选、链接），`\.themeAccent` 管我们自己写的那些
                // `Color.accentColor` 位置——两者都得给，缺一个就会留下
                // 几处永远是系统蓝的元素。
                .tint(theme.accent)
                .environment(\.themeAccent, theme.accent)
                // 字号：把档位挂到根节点的动态字体环境上，整棵树会随之重算，
                // 设置页里那些固定字号（`SettingsMetrics`，读的是静态属性）
                // 也就一并拿到新系数，不需要逐页传值。
                .environment(\.sizeCategory, fontScale.size.sizeCategory)
                .onAppear {
                    Task {
                        await AppRemoteConfigurationStore.shared.refresh()
                    }
                    #if !PURE_BUILD
                    Task {
                        // 启动校验授权状态。失败时 LicenseManager 内部会回落到
                        // 本地缓存（3 天离线宽限），不会因为一次断网就把用户挡在门外。
                        await license.refresh(silent: true)
                        // 每天上报一次心跳，用于推荐系统「连续使用 3 天」的判定。
                        await license.reportDailyHeartbeatIfNeeded()
                    }
                    #endif
                }
        }
    }
}

extension Bundle {
    var appVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var buildNumber: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
