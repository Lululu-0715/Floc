import Foundation
import Security

/// CA 证书的持久化存储。
///
/// 只保存到 Keychain，不落磁盘明文。根私钥一旦泄露就意味着任何人都可以
/// 冒充该 CA 签发证书，因此用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// 限制为「仅本机、解锁后可读」，不会同步到 iCloud 钥匙串。
enum CertificateAuthorityStore {

    private static let serviceName = "com.fff.loc.ca"
    private static let certAccount = "root-certificate"
    private static let keyAccount = "root-private-key"

    /// 载入已保存的 CA，不存在或已损坏时返回 nil。
    static func load() -> CertificateAuthority? {
        guard let certPEM = read(account: certAccount),
              let keyPEM = read(account: keyAccount) else {
            return nil
        }

        let authority = CertificateAuthority(certPEM: certPEM, keyPEM: keyPEM)
        guard CoreBridge.isValidCertificateAuthority(authority) else {
            RuntimeLogger.warn("APP", "Certificate.store", "已保存的 CA 校验失败，将丢弃并重新生成")
            delete()
            return nil
        }
        return authority
    }

    /// 保存 CA。会先清掉旧的再写入。
    static func save(_ authority: CertificateAuthority) throws {
        delete()
        try write(value: authority.certPEM, account: certAccount)
        try write(value: authority.keyPEM, account: keyAccount)
        RuntimeLogger.info("APP", "Certificate.store", "CA 已保存到 Keychain")
    }

    /// 载入已有的，没有就生成一个新的。
    static func loadOrCreate() throws -> CertificateAuthority {
        if let existing = load() {
            return existing
        }
        let generated = try CoreBridge.generateCertificateAuthority()
        try save(generated)
        return generated
    }

    /// 删除已保存的 CA。
    static func delete() {
        remove(account: certAccount)
        remove(account: keyAccount)
    }

    // MARK: - Keychain 读写

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
        ]
    }

    private static func query(account: String) -> [String: Any] {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        return query
    }

    private static func read(account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                RuntimeLogger.warn("APP", "Certificate.store", "读取 Keychain 失败", details: [
                    "account": account,
                    "status": String(status),
                ])
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func write(value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        var query = query(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            RuntimeLogger.error("APP", "Certificate.store", "写入 Keychain 失败", details: [
                "account": account,
                "status": String(status),
            ])
            throw KeychainError.writeFailed(status)
        }
    }

    private static func remove(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }

    enum KeychainError: LocalizedError {
        case encodingFailed
        case writeFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return AppLocalization.string("证书内容编码失败")
            case .writeFailed(let status):
                return AppLocalization.string("写入钥匙串失败（状态码 %d）", status)
            }
        }
    }
}
