import Foundation
import Security

/// 稳定的设备标识。
///
/// 为什么不用 `identifierForVendor`：它会在「卸载后重装且期间没有装过
/// 其他本厂 App」时变化，用户抹机重装就能白嫖一次 3 天试用、也能重复
/// 领推荐奖励。
///
/// 这里改用 Keychain：`kSecClassGenericPassword` 的条目在卸载 App 时
/// 不会被系统清掉，重装后仍能读回同一个 UUID。这是目前不越狱条件下
/// 能拿到的最稳的一档标识。
///
/// 局限（如实说明）：
///   - 用户「抹掉所有内容和设置」会清空 Keychain，此时会生成新 ID；
///   - 同一台设备用同一个 Apple ID 的多个 App 若共用 keychain access
///     group 才能做到跨 App 一致，这里不做，保持简单。
/// 对防刷来说已经够用：成本从「重装一次」提高到「整机重置」。
enum DeviceIdentity {

    /// Keychain 里存这个 UUID 用的 service 名
    private static let service = "com.fff.loc.device"

    /// account 名
    private static let account = "device-id"

    /// 内存缓存，避免每次请求都去读 Keychain
    private static var cached: String?

    /// 当前设备 ID（小写，与服务端 normalizeDevice 对齐）
    static var current: String {
        if let cached { return cached }

        if let existing = readFromKeychain() {
            cached = existing
            return existing
        }

        let fresh = UUID().uuidString.lowercased()
        writeToKeychain(fresh)
        cached = fresh
        return fresh
    }

    // MARK: - Keychain

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }

        return value
    }

    private static func writeToKeychain(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // 先删再加，避免 errSecDuplicateItem
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // 仅本机、解锁后可读；不参与 iCloud 同步
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        SecItemAdd(addQuery as CFDictionary, nil)
    }

    // MARK: - 调试

    /// 强制换一个新 ID（仅调试用，正式包不要暴露入口）
    static func resetForDebug() {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        cached = nil
    }
}
