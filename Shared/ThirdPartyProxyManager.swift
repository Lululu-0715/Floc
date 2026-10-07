import Foundation
import UIKit

/// 第三方代理模式的管理器。
///
/// 与应用内代理的关键差别：坐标不是推给本机 Go 代理，而是通过一个约定的
/// HTTP 接口写进第三方客户端。该请求在正常情况下会被客户端在本地拦下，
/// 不会真的发到 Apple 服务器。
@MainActor
final class ThirdPartyProxyManager: ObservableObject {

    static let shared = ThirdPartyProxyManager()

    /// 连接状态。
    enum ConnectionState: Equatable {
        /// 还没检查过。
        case unknown
        /// 正在检查。
        case checking
        /// 客户端未安装。
        case clientMissing
        /// 客户端已装，但模块没生效（请求没被拦下）。
        case moduleNotInstalled
        /// 模块已连通，但当前没有保存坐标。
        case connectedNoCoordinate
        /// 模块连通且已保存坐标。
        case connected(latitude: Double, longitude: Double)
        /// 配置写入失败。
        case failed(String)

        var displayText: String {
            switch self {
            case .unknown: return AppLocalization.string("未检测")
            case .checking: return AppLocalization.string("检测中")
            case .clientMissing: return AppLocalization.string("未安装客户端")
            case .moduleNotInstalled: return AppLocalization.string("模块未生效")
            case .connectedNoCoordinate: return AppLocalization.string("已连接，未开启")
            case .connected: return AppLocalization.string("已连接")
            case .failed: return AppLocalization.string("配置失败")
            }
        }

        var isUsable: Bool {
            switch self {
            case .connected, .connectedNoCoordinate: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: ConnectionState = .unknown
    @Published private(set) var lastSavedPair: CoordinateConverter.CoordinatePair?

    /// 拦截这次请求的客户端。
    ///
    /// 来自模块回报的 `env`，与「用户在应用里选的客户端」是两回事：
    /// 真正执行拦截的是手机上开着的那个代理软件。不区分这两者，
    /// 「已连接，未开启」就会被当成所选客户端的状态，张冠李戴。
    @Published private(set) var responderClient: ThirdPartyProxyClient?

    /// 响应改写脚本最后一次运行的结果。见 `ModuleDiagnostics`。
    @Published private(set) var diagnostics: ThirdPartyProxyProtocol.ModuleDiagnostics?

    /// 回报的客户端与所选客户端不一致。
    ///
    /// 含义很明确：手机上是另一个代理软件在跑。用户往往是在应用里换了选择、
    /// 却没在客户端那边同步切换，这时候所有状态都指向那个实际在跑的客户端。
    var responderMismatch: Bool {
        guard let responderClient else { return false }
        return responderClient != selectedClient
    }

    /// 把脚本回报的结论翻成一句人话。
    ///
    /// 第三方模式最大的麻烦是「看不见」：规则装没装上、脚本跑到哪一步都在
    /// 客户端自己的日志里。「没有记录」这一档尤其重要——它说明响应改写规则
    /// 一次都没跑到，问题出在模块启用 / MITM 覆盖，而不是「格式对不上」。
    var diagnosticsText: String {
        guard let diagnostics else {
            return AppLocalization.string("没有记录，响应改写规则一次都没跑到")
        }

        switch diagnostics.outcome {
        case "rewritten":
            let count = diagnostics.locations ?? 0
            if diagnostics.gzip == true {
                return String(
                    format: AppLocalization.string("已改写 %d 个位置点（原响应为 gzip，已解压）"),
                    count
                )
            }
            return String(format: AppLocalization.string("已改写 %d 个位置点"), count)

        case "disabled":
            return AppLocalization.string("模块在运行，但还没有写入过坐标")

        case "bad-target":
            return AppLocalization.string("模块收到的坐标无效")

        case "empty-body":
            return AppLocalization.string("脚本拿不到响应体，请确认模块处于开启状态")

        case "gzip":
            return AppLocalization.string("响应是 gzip 压缩，当前客户端没有提供解压能力")

        case "no-match":
            return AppLocalization.string("响应里没有找到定位数据，系统可能换了新的响应格式")

        case "error":
            return String(
                format: AppLocalization.string("改写过程出错：%@"),
                diagnostics.reason ?? ""
            )

        default:
            return AppLocalization.string("没有记录，响应改写规则一次都没跑到")
        }
    }

    /// 诊断时间文案。没有记录时给一个占位符，不用再占一条本地化条目。
    var diagnosticsDateText: String {
        guard let date = diagnostics?.date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 当前选择的客户端。
    @Published var selectedClient: ThirdPartyProxyClient {
        didSet {
            guard selectedClient != oldValue else { return }
            defaults.set(selectedClient.rawValue, forKey: Key.client)
            RuntimeLogger.info("APP", "ThirdParty", "切换客户端", details: [
                "client": selectedClient.displayName,
            ])
            // 上一个客户端的连通性、诊断都属于它自己，不能留给新选的这个，
            // 否则会出现「还没换代理软件，应用里却显示已连接」。
            state = .unknown
            responderClient = nil
            diagnostics = nil
        }
    }

    private let defaults: UserDefaults
    private let session: URLSession

    private enum Key {
        static let client = "thirdPartyClient"
        static let savedCoordinate = "thirdPartySavedCoordinate"
    }

    private init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        self.selectedClient = defaults.string(forKey: Key.client)
            .flatMap(ThirdPartyProxyClient.init(rawValue:)) ?? .shadowrocket

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // 这个请求依赖「被第三方客户端在本地拦下」，因此不能走系统代理配置之外
        // 的额外路径，保持默认即可。
        self.session = URLSession(configuration: configuration)

        if let data = defaults.data(forKey: Key.savedCoordinate) {
            lastSavedPair = try? JSONDecoder().decode(CoordinateConverter.CoordinatePair.self, from: data)
        }
    }

    // MARK: - 查询

    /// 查询客户端是否连通，以及当前保存的坐标。
    func refresh() async {
        guard selectedClient.isInstalled else {
            state = .clientMissing
            RuntimeLogger.info("APP", "ThirdParty", "客户端未安装", details: [
                "client": selectedClient.displayName,
            ])
            return
        }

        state = .checking
        guard let url = ThirdPartyProxyProtocol.url(action: .query) else {
            state = .failed(AppLocalization.string("无法构造查询地址"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, _) = try await session.data(for: request)
            guard let response = try? JSONDecoder().decode(ThirdPartyProxyProtocol.Response.self, from: data) else {
                // 返回了内容但不是约定 JSON，通常是客户端没装模块，
                // 请求真的发到了 Apple 服务器。
                state = .moduleNotInstalled
                responderClient = nil
                diagnostics = nil
                RuntimeLogger.info("APP", "ThirdParty", "查询响应不符合约定格式")
                return
            }

            applyResponder(response)

            if response.success, let lat = response.latitude, let lon = response.longitude {
                state = .connected(latitude: lat, longitude: lon)
                let pair = CoordinateConverter.CoordinatePair(wgs84Latitude: lat, wgs84Longitude: lon)
                lastSavedPair = pair
                persistSavedPair(pair)
                RuntimeLogger.info("APP", "ThirdParty", "已连接，客户端坐标有效")
            } else {
                // success=false 且没有坐标：模块在，但用户还没开启虚拟定位。
                state = .connectedNoCoordinate
                RuntimeLogger.info("APP", "ThirdParty", "模块已连通，尚未保存坐标", details: [
                    "reason": response.error ?? "",
                ])
            }
        } catch {
            state = .failed((error as NSError).localizedDescription)
            responderClient = nil
            diagnostics = nil
            RuntimeLogger.warn("APP", "ThirdParty", "查询失败", details: [
                "error": (error as NSError).localizedDescription,
            ])
        }
    }

    /// 记下「这次是谁回的话」以及它带回的运行诊断。
    private func applyResponder(_ response: ThirdPartyProxyProtocol.Response) {
        responderClient = response.env.flatMap(ThirdPartyProxyClient.init(rawValue:))
        diagnostics = response.diag
    }

    // MARK: - 写入与清除

    /// 把坐标写入客户端。
    @discardableResult
    func save(
        pair: CoordinateConverter.CoordinatePair,
        accuracy: Int,
        motionRadius: Int = 0
    ) async -> Bool {
        guard let url = ThirdPartyProxyProtocol.url(
            wgs84Latitude: pair.wgs84.latitude,
            wgs84Longitude: pair.wgs84.longitude,
            accuracy: accuracy,
            driftRadius: motionRadius
        ) else {
            state = .failed(AppLocalization.string("无法构造保存地址"))
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, _) = try await session.data(for: request)
            let decoded = try? JSONDecoder().decode(ThirdPartyProxyProtocol.Response.self, from: data)

            if let decoded, decoded.success {
                applyResponder(decoded)
                // 契约要求：保存成功时响应里的坐标必须与请求一致，否则说明客户端实现有偏差。
                if let lat = decoded.latitude, let lon = decoded.longitude {
                    let echoed = CoordinateConverter.CoordinatePair(
                        wgs84Latitude: lat, wgs84Longitude: lon
                    )
                    if !pair.matchesWGS84(latitude: lat, longitude: lon, tolerance: 0.001) {
                        RuntimeLogger.warn("APP", "ThirdParty", "客户端回读坐标与请求不一致", details: [
                            "echoed": "\(echoed.wgs84.latitude),\(echoed.wgs84.longitude)",
                        ])
                    }
                }
                state = .connected(latitude: pair.wgs84.latitude, longitude: pair.wgs84.longitude)
                lastSavedPair = pair
                persistSavedPair(pair)
                RuntimeLogger.info("APP", "ThirdParty", "坐标已写入客户端")
                return true
            }

            let message = decoded?.error
            state = .failed(message ?? AppLocalization.string("客户端拒绝保存"))
            RuntimeLogger.warn("APP", "ThirdParty", "客户端拒绝保存", details: [
                "reason": message ?? "",
            ])
            return false
        } catch {
            state = .failed((error as NSError).localizedDescription)
            responderClient = nil
            RuntimeLogger.warn("APP", "ThirdParty", "保存请求失败", details: [
                "error": (error as NSError).localizedDescription,
            ])
            return false
        }
    }

    /// 清除客户端里保存的坐标。
    @discardableResult
    func clear() async -> Bool {
        guard let url = ThirdPartyProxyProtocol.url(action: .clear) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, _) = try await session.data(for: request)
            guard let decoded = try? JSONDecoder().decode(ThirdPartyProxyProtocol.Response.self, from: data),
                  decoded.success else {
                return false
            }
            applyResponder(decoded)
            lastSavedPair = nil
            defaults.removeObject(forKey: Key.savedCoordinate)
            state = .connectedNoCoordinate
            RuntimeLogger.info("APP", "ThirdParty", "已清除客户端坐标")
            return true
        } catch {
            RuntimeLogger.warn("APP", "ThirdParty", "清除请求失败", details: [
                "error": (error as NSError).localizedDescription,
            ])
            return false
        }
    }

    // MARK: - 模块订阅地址

    /// 模块订阅地址。默认指向本仓库托管的脚本；用户也可以在设置里改成自建地址。
    var moduleSubscriptionURL: URL? {
        let base = defaults.string(forKey: "thirdPartyModuleBaseURL")
            ?? Self.defaultModuleBaseURL
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: "\(trimmed)/\(moduleFileName)") else { return nil }
        return url
    }

    /// 当前客户端需要导入的模块文件名，例如 `wloc.sgmodule`。
    ///
    /// 仓库 `ThirdParty/ProxyScripts/modules/` 下躺着 5 个 `wloc.*` 文件，
    /// 光看目录根本分不清哪个配哪个客户端。设置页把这行显示出来，
    /// 用户复制地址时就能对上号。
    var moduleFileName: String {
        "wloc.\(selectedClient.moduleFileExtension)"
    }

    /// 默认脚本托管地址。换成自己的仓库时改这里。
    static let defaultModuleBaseURL =
        "https://raw.githubusercontent.com/Lululu-0715/Floc/main/ThirdParty/ProxyScripts/modules"

    /// 把模块地址复制到剪贴板，方便用户手动导入。
    func copyModuleURLToPasteboard() -> Bool {
        guard let url = moduleSubscriptionURL else { return false }
        UIPasteboard.general.string = url.absoluteString
        RuntimeLogger.info("APP", "ThirdParty", "模块地址已复制")
        return true
    }

    // MARK: - 持久化

    private func persistSavedPair(_ pair: CoordinateConverter.CoordinatePair) {
        if let data = try? JSONEncoder().encode(pair) {
            defaults.set(data, forKey: Key.savedCoordinate)
        }
    }
}
