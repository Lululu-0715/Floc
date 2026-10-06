import Darwin
import Foundation

/// 一套 CA 证书与私钥（PEM 文本）。
struct CertificateAuthority: Equatable {
    let certPEM: String
    let keyPEM: String
}

enum CoreBridgeError: LocalizedError {
    case certificateGenerationFailed
    case certificateServiceFailed
    case proxyStartFailed

    var errorDescription: String? {
        switch self {
        case .certificateGenerationFailed: return AppLocalization.string("无法生成本机证书")
        case .certificateServiceFailed: return AppLocalization.string("无法启动本机证书服务")
        case .proxyStartFailed: return AppLocalization.string("无法启动本机代理服务")
        }
    }
}

/// Go Core 的 Swift 封装。
///
/// 所有跨语言调用都集中在这里，好处是内存管理（`free`）和错误转换只有一处，
/// 上层业务代码完全看不到 C 指针。
enum CoreBridge {

    /// Core 的版本号，用于确认静态库与 Swift 代码匹配。
    static var coreVersion: String {
        guard let pointer = locationcore_version() else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    // MARK: - 证书

    /// 校验一套 CA 是否可用。
    static func isValidCertificateAuthority(_ authority: CertificateAuthority) -> Bool {
        authority.certPEM.withCString { cert in
            authority.keyPEM.withCString { key in
                locationcore_validateca(
                    UnsafeMutablePointer(mutating: cert),
                    UnsafeMutablePointer(mutating: key)
                ) != 0
            }
        }
    }

    /// 生成一套新的 CA。
    static func generateCertificateAuthority() throws -> CertificateAuthority {
        RuntimeLogger.info("APP", "Core.CA", "调用 Core 生成 CA")
        let result = locationcore_generateca()
        guard let certPointer = result.r0, let keyPointer = result.r1 else {
            flushLogs(category: "CA")
            throw CoreBridgeError.certificateGenerationFailed
        }
        defer { free(certPointer); free(keyPointer) }
        RuntimeLogger.info("APP", "Core.CA", "Core CA 生成成功")
        flushLogs(category: "CA")
        return CertificateAuthority(
            certPEM: String(cString: certPointer),
            keyPEM: String(cString: keyPointer)
        )
    }

    // MARK: - 日志

    /// 把 Core 侧积压的日志搬到 Swift 日志系统。
    static func flushLogs(category: String) {
        guard let pointer = locationcore_drainlogs() else { return }
        defer { free(pointer) }
        String(cString: pointer)
            .split(separator: "\n")
            .forEach { RuntimeLogger.info("CORE", category, String($0)) }
    }

    // MARK: - 自检

    /// 让 Core 跑一次模拟改写，返回结果描述。
    /// 用于诊断页展示「改写引擎是否正常工作」，不需要真的开代理。
    static func selfCheckPatch(latitude: Double, longitude: Double, accuracy: Int) -> String {
        guard let pointer = locationcore_testpatch(
            CDouble(latitude), CDouble(longitude), CInt(accuracy)
        ) else {
            return "error: 无返回值"
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// 生成一份示例扫描请求的十六进制串，用于调试。
    static func sampleRequestHex() -> String {
        guard let pointer = locationcore_samplerequesthex() else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    // MARK: - 代理连通性验证

    /// 刷新验证 token，返回新值。
    static func refreshVerifyToken() -> String {
        guard let pointer = locationcore_refreshverifytoken() else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// 检查 token 是否为当前有效值。
    static func checkVerifyToken(_ token: String) -> Bool {
        token.withCString { locationcore_checkverifytoken(UnsafeMutablePointer(mutating: $0)) != 0 }
    }

    /// 更新改写配置（坐标、开关、精度、运动模拟）。
    static func updatePatchConfig(
        latitude: Double,
        longitude: Double,
        enabled: Bool,
        accuracy: Int,
        motionEnabled: Bool
    ) {
        locationcore_setpatchconfig(
            CDouble(latitude),
            CDouble(longitude),
            enabled ? 1 : 0,
            CInt(accuracy),
            motionEnabled ? 1 : 0
        )
    }
}

/// 本机证书服务。
///
/// 提供两个端点：一个下载根证书（供 iOS 安装描述文件），一个用 CA 签出的
/// 叶子证书提供 HTTPS /health。只要 /health 能用系统默认信任链握手成功，
/// 就说明用户已经完整信任了根证书——这是「证书是否装好」的唯一可靠判据。
final class LocalCertificateService {

    private var handle: UInt = 0
    private(set) var downloadURL: URL?
    private(set) var probeURL: URL?
    private(set) var leafHash = ""

    deinit { stop() }

    var isRunning: Bool { handle != 0 }

    func start(authority: CertificateAuthority) throws {
        guard handle == 0 else {
            RuntimeLogger.debug("APP", "Certificate.service", "本机证书服务已在运行")
            return
        }

        RuntimeLogger.info("APP", "Certificate.service", "调用 Core 启动本机证书服务")
        let newHandle: UInt = authority.certPEM.withCString { cert in
            authority.keyPEM.withCString { key in
                UInt(locationcore_startcertservice(
                    UnsafeMutablePointer(mutating: cert),
                    UnsafeMutablePointer(mutating: key)
                ))
            }
        }
        guard newHandle != 0 else {
            CoreBridge.flushLogs(category: "CertificateService")
            throw CoreBridgeError.certificateServiceFailed
        }

        let httpPort = Int(locationcore_certservice_httpport(newHandle))
        let httpsPort = Int(locationcore_certservice_httpsport(newHandle))
        guard httpPort > 0, httpsPort > 0,
              let hashPointer = locationcore_certservice_leafsha256(newHandle) else {
            _ = locationcore_stopcertservice(newHandle)
            throw CoreBridgeError.certificateServiceFailed
        }
        defer { free(hashPointer) }

        handle = newHandle
        downloadURL = URL(string: "http://127.0.0.1:\(httpPort)/ca.cer")
        probeURL = URL(string: "https://127.0.0.1:\(httpsPort)/health")
        leafHash = String(cString: hashPointer)

        RuntimeLogger.info("APP", "Certificate.service", "本机证书服务启动成功", details: [
            "httpPort": String(httpPort),
            "httpsPort": String(httpsPort),
            "leafHash": leafHash,
        ])
        CoreBridge.flushLogs(category: "CertificateService")
    }

    func stop() {
        guard handle != 0 else { return }
        let result = locationcore_stopcertservice(handle)
        RuntimeLogger.info("APP", "Certificate.service", "停止本机证书服务", details: [
            "result": String(result),
        ])
        CoreBridge.flushLogs(category: "CertificateService")
        handle = 0
        downloadURL = nil
        probeURL = nil
        leafHash = ""
    }
}
