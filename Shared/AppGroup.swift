import Foundation

/// App Group 容器与共享存储。
///
/// 用 App Group 是为了让日志、收藏、运行模式等状态在所有进程间一致，
/// 也为将来加入扩展（如通知扩展）留出空间。
enum AppGroup {

    /// 必须与 entitlements 中的 `com.apple.security.application-groups` 保持一致。
    static let identifier = "group.com.fff.loc"

    /// 共享 UserDefaults。App Group 不可用时退化为标准 defaults，
    /// 保证在未配置 App Group 的签名环境下也能正常使用。
    static let defaults: UserDefaults = {
        UserDefaults(suiteName: identifier) ?? .standard
    }()

    /// 共享容器目录。App Group 不可用时退化为沙盒内的 Application Support。
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// 日志文件所在目录。
    static var logsDirectoryURL: URL {
        let url = containerURL.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 判断 App Group 是否真的可用，用于在诊断页提示用户。
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
    }
}
