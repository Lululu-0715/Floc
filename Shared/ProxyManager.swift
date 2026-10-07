import Foundation
import Network

/// APP 模式的代理管理器。
///
/// 职责链：
///   1. 准备 CA（Keychain 里没有就生成）
///   2. 启动本机证书服务，拿到证书下载地址与信任探测地址
///   3. 引导用户安装并信任 CA（这一步只能在系统设置里手动完成）
///   4. 启动 Go 拦截代理（127.0.0.1:8888）
///   5. 校验 Wi-Fi 代理配置是否真的把流量导到了本机
///
/// 注意：本类不负责修改 Wi-Fi 代理设置——iOS 没有公开 API 能改。
/// 用户需要在「设置 → 无线局域网 → 当前网络 → 配置代理」里手动填写，
/// 本类通过「发出一个带随机 token 的请求并检查能否被本机拦到」来验证。
@MainActor
final class ProxyManager: ObservableObject {

    static let shared = ProxyManager()

    /// 代理监听端口，必须与 Go 侧保持一致。
    static let proxyHost = "127.0.0.1"
    static let proxyPort = 8888

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var isRunning: Bool { self == .running }

        var displayText: String {
            switch self {
            case .stopped: return AppLocalization.string("未启动")
            case .starting: return AppLocalization.string("启动中")
            case .running: return AppLocalization.string("运行中")
            case .failed: return AppLocalization.string("启动失败")
            }
        }
    }

    /// Wi-Fi 代理配置是否已生效。
    enum WiFiProxyState: Equatable {
        case unknown
        case notConfigured
        case configured
        case checking

        var displayText: String {
            switch self {
            case .unknown: return AppLocalization.string("未检测")
            case .notConfigured: return AppLocalization.string("未配置")
            case .configured: return AppLocalization.string("已生效")
            case .checking: return AppLocalization.string("检测中")
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var certificateTrustState: CertificateTrustVerifier.TrustState = .unknown
    @Published private(set) var wiFiProxyState: WiFiProxyState = .unknown
    @Published private(set) var currentWiFiName: String = ""

    private var proxyHandle: UInt = 0
    private let certificateService = LocalCertificateService()
    private let networkMonitor = NetworkMonitor()

    private init() {
        networkMonitor.onWiFiChanged = { [weak self] name in
            Task { @MainActor in
                self?.currentWiFiName = name
                // 换了 Wi-Fi 之后代理配置不会跟随，需要重新验证。
                self?.wiFiProxyState = .unknown
                if self?.status.isRunning == true {
                    await self?.verifyWiFiProxy()
                }
            }
        }
    }

    var certificateDownloadURL: URL? { certificateService.downloadURL }
    var certificateProbeURL: URL? { certificateService.probeURL }
    var isCertificateServiceRunning: Bool { certificateService.isRunning }

    // MARK: - 启动

    /// 完整启动流程。已经启动过则直接返回。
    func start(
        latitude: Double,
        longitude: Double,
        enabled: Bool,
        accuracy: Int,
        motionRadius: Int
    ) async throws {
        guard !status.isRunning else {
            // 已在运行，只需要把新配置推给 Core。
            updateCoordinates(
                latitude: latitude,
                longitude: longitude,
                enabled: enabled,
                accuracy: accuracy,
                motionRadius: motionRadius
            )
            return
        }

        status = .starting
        RuntimeLogger.info("APP", "Proxy", "开始启动代理")

        do {
            // 1 + 2：准备 CA 并启动证书服务
            let authority = try CertificateAuthorityStore.loadOrCreate()
            if !certificateService.isRunning {
                try certificateService.start(authority: authority)
            }

            // 3：启动拦截代理
            let handle: UInt = authority.certPEM.withCString { cert in
                authority.keyPEM.withCString { key in
                    UInt(locationcore_startproxyv2(
                        UnsafeMutablePointer(mutating: cert),
                        UnsafeMutablePointer(mutating: key),
                        CDouble(latitude),
                        CDouble(longitude),
                        enabled ? 1 : 0,
                        CInt(accuracy),
                        CInt(motionRadius)
                    ))
                }
            }
            guard handle != 0 else {
                CoreBridge.flushLogs(category: "Proxy")
                throw CoreBridgeError.proxyStartFailed
            }
            proxyHandle = handle

            status = .running
            RuntimeLogger.info("APP", "Proxy", "代理启动成功", details: [
                "address": "\(Self.proxyHost):\(Self.proxyPort)",
            ])
            CoreBridge.flushLogs(category: "Proxy")

            // 启动后立刻做一次链路检查，让用户马上知道还差哪一步。
            await verifyCertificateTrust()
            await verifyWiFiProxy()
        } catch {
            status = .failed(error.localizedDescription)
            RuntimeLogger.error("APP", "Proxy", "代理启动失败", details: [
                "error": error.localizedDescription,
            ])
            CoreBridge.flushLogs(category: "Proxy")
            throw error
        }
    }

    /// 停止代理并关闭证书服务。
    func stop() {
        guard proxyHandle != 0 else {
            status = .stopped
            return
        }
        _ = locationcore_stopproxy(proxyHandle)
        proxyHandle = 0
        certificateService.stop()
        status = .stopped
        wiFiProxyState = .unknown
        certificateTrustState = .unknown
        RuntimeLogger.info("APP", "Proxy", "代理已停止")
        CoreBridge.flushLogs(category: "Proxy")
    }

    /// 更新改写配置（坐标变化、精度或抖动半径调整时调用）。
    func updateCoordinates(
        latitude: Double,
        longitude: Double,
        enabled: Bool,
        accuracy: Int,
        motionRadius: Int
    ) {
        CoreBridge.updatePatchConfig(
            latitude: latitude,
            longitude: longitude,
            enabled: enabled,
            accuracy: accuracy,
            motionRadius: motionRadius
        )
        CoreBridge.flushLogs(category: "Proxy")
    }

    // MARK: - 环境检测

    /// 用实测结果校正 `status`。
    ///
    /// `status` 是自维护状态，进程被挂起时不会自动变成 `.stopped`，于是会出现
    /// 「状态说在跑、端口其实已经没了」——环境检测里 Wi-Fi 代理链路就因此被
    /// 误判成「跳过」，用户看到的是「Wi-Fi 设置没错，但怎么都没用」。
    ///
    /// 返回校正后「代理是否真的可用」。
    @discardableResult
    func syncStatusWithReality() -> Bool {
        guard status.isRunning else { return false }

        if CoreBridge.isProxyListening() {
            return true
        }

        RuntimeLogger.warn("APP", "Proxy", "状态显示在运行，但端口已无响应，按已停止处理")
        CoreBridge.flushLogs(category: "Proxy")
        status = .stopped
        proxyHandle = 0
        wiFiProxyState = .unknown
        return false
    }

    /// 验证 CA 是否已在系统中被完整信任。
    func verifyCertificateTrust() async {
        guard let probeURL = certificateService.probeURL else {
            certificateTrustState = .unknown
            return
        }
        certificateTrustState = await CertificateTrustVerifier.verify(probeURL: probeURL)
    }

    /// 验证 Wi-Fi 手动代理是否把流量导向了本机。
    ///
    /// 做法：刷新一个一次性 token，然后请求 `https://www.baidu.com/location-verify-<token>`。
    /// 如果代理生效，请求会被本机拦下并回显 token；否则会走到真实的百度服务器，
    /// 返回 404 或别的内容，从而判定代理没配好（或没走到本机）。
    func verifyWiFiProxy() async {
        wiFiProxyState = .checking

        let token = CoreBridge.refreshVerifyToken()
        guard !token.isEmpty,
              let url = URL(string: "https://www.baidu.com/location-verify-\(token)") else {
            wiFiProxyState = .notConfigured
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": Self.proxyHost,
            "HTTPPort": Self.proxyPort,
            "HTTPSEnable": 1,
            "HTTPSProxy": Self.proxyHost,
            "HTTPSPort": Self.proxyPort,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, _) = try await session.data(for: request)
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.trimmingCharacters(in: .whitespacesAndNewlines) == token {
                wiFiProxyState = .configured
                RuntimeLogger.info("APP", "Proxy", "Wi-Fi 代理链路验证通过")
            } else {
                wiFiProxyState = .notConfigured
                RuntimeLogger.info("APP", "Proxy", "Wi-Fi 代理链路未生效（回显内容不匹配）")
            }
        } catch {
            wiFiProxyState = .notConfigured
            RuntimeLogger.info("APP", "Proxy", "Wi-Fi 代理链路未生效", details: [
                "error": (error as NSError).localizedDescription,
            ])
        }
        CoreBridge.flushLogs(category: "Proxy")
    }

    /// 同步一次 Core 侧日志到 Swift 日志系统。
    func flushCoreLogs() {
        CoreBridge.flushLogs(category: "Proxy")
    }

    /// 跑一次改写引擎自检，返回结果描述。
    func runSelfCheck(latitude: Double, longitude: Double, accuracy: Int) -> String {
        let result = CoreBridge.selfCheckPatch(
            latitude: latitude,
            longitude: longitude,
            accuracy: accuracy
        )
        RuntimeLogger.info("APP", "Proxy", "改写引擎自检", details: ["result": result])
        return result
    }

    // MARK: - 引导文案

    /// 生成给用户看的手动配置步骤。
    var setupInstructions: [String] {
        var steps: [String] = []

        if let address = certificateService.downloadURL?.absoluteString {
            steps.append(AppLocalization.string("用 Safari 打开 %@ 下载证书，然后在「设置 → 通用 → VPN 与设备管理」中安装。", address))
        } else {
            steps.append(AppLocalization.string("先启动代理以生成证书服务。"))
        }

        steps.append(AppLocalization.string("在「设置 → 通用 → 关于本机 → 证书信任设置」中为证书开启完全信任。"))

        let wifiLabel = currentWiFiName.isEmpty
            ? AppLocalization.string("当前 Wi-Fi")
            : AppLocalization.string("当前 Wi-Fi「%@」", currentWiFiName)
        steps.append(AppLocalization.string(
            "在「设置 → 无线局域网 → %@ → 配置代理」中选择「手动」，服务器填 %@，端口填 %d。",
            wifiLabel, Self.proxyHost, Self.proxyPort
        ))

        steps.append(AppLocalization.string("回到本应用执行环境检测，两项都通过后即可开启虚拟定位。"))

        return steps
    }
}
