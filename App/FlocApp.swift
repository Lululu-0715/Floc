import SwiftUI

@main
struct FlocApp: App {

    @StateObject private var setup = SetupCoordinator()
    @StateObject private var appearance = AppearanceStore.shared

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
                // 外观在根节点统一施加：设置页里改一档，整个应用（含已经
                // 打开的 sheet 和导航栈）立刻跟着变，不用逐页传值。
                .preferredColorScheme(appearance.mode.colorScheme)
                .onAppear {
                    Task {
                        await AppRemoteConfigurationStore.shared.refresh()
                    }
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
