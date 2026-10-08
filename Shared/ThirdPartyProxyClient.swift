import UIKit
import Foundation

/// 支持的第三方代理客户端。
///
/// 每种客户端需要不同的模块文件扩展名与订阅 URL 后缀，能力也有差异
/// （主要在于是不是支持蜂窝网络、是否长期保持配置）。
enum ThirdPartyProxyClient: String, CaseIterable, Codable, Identifiable {
    case shadowrocket
    case surge
    case quantumultX
    case loon
    case stash
    case egern

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shadowrocket: return "Shadowrocket"
        case .surge: return "Surge"
        case .quantumultX: return "Quantumult X"
        case .loon: return "Loon"
        case .stash: return "Stash"
        case .egern: return "Egern"
        }
    }

    /// 模块文件的扩展名。
    var moduleFileExtension: String {
        switch self {
        case .shadowrocket: return "module"
        case .surge, .egern: return "sgmodule"
        case .quantumultX: return "conf"
        case .loon: return "lpx"
        case .stash: return "stoverride"
        }
    }

    /// 唤起客户端的 URL scheme。
    var urlScheme: String {
        switch self {
        case .shadowrocket: return "shadowrocket"
        case .surge: return "surge"
        case .quantumultX: return "quantumult-x"
        case .loon: return "loon"
        case .stash: return "stash"
        case .egern: return "egern"
        }
    }

    /// 是否支持蜂窝网络下的拦截。
    var supportsCellular: Bool {
        // Shadowrocket / Surge / Quantumult X / Loon / Stash 均可基于 VPN 接管全部流量。
        // 这里保守地按「客户端自身能力」区分，实际仍以用户配置为准。
        switch self {
        case .shadowrocket, .surge, .quantumultX, .loon, .stash, .egern: return true
        }
    }

    /// 当前支持的稳定程度。
    enum SupportLevel: String {
        case verified
        case experimental

        var displayName: String {
            switch self {
            case .verified: return AppLocalization.string("已真机验证")
            case .experimental: return AppLocalization.string("待验证")
            }
        }
    }

    var supportLevel: SupportLevel {
        switch self {
        case .shadowrocket: return .verified
        case .surge, .quantumultX, .loon, .stash, .egern: return .experimental
        }
    }

    /// 该客户端是否安装在本机。
    var isInstalled: Bool {
        guard let url = URL(string: "\(urlScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// 尝试唤起客户端。
    @discardableResult
    func open() -> Bool {
        guard let url = URL(string: "\(urlScheme)://") else { return false }
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }
}

// MARK: - 配置接口协议

/// 本应用与第三方代理客户端之间的配置接口。
///
/// 这是整个第三方模式的契约：App 只负责发请求，客户端负责拦截并落盘坐标。
/// 双方约定的路径与参数如下（客户端必须在设备本地拦截，请求不会真的出网）。
enum ThirdPartyProxyProtocol {

    /// 配置接口地址。
    static let settingsPath = "/wloc-settings/save"

    /// 需要被客户端拦截的主机。
    ///
    /// 前两台是 Apple 的全球 / 国内定位入口；中间一批 `gsp*` / `gspe*` 是
    /// 新版本系统把定位查询分散过去的备用入口，只拦前两台的话在 iOS 26+
    /// 上会出现「模块装了却没反应」；最后两台是 Apple 地图在国内使用的
    /// 蓝点定位（高德）端点。
    ///
    /// 与 `Core/proxy.go` 的 `locationHosts` 必须保持一致——两边对不上，
    /// 用户切换运行模式后拦截范围就会静默变窄。
    static let interceptedHosts = [
        "gs-loc.apple.com",
        "gs-loc-cn.apple.com",
        "gsp-ssl.ls.apple.com",
        "gsp10-ssl.ls.apple.com",
        "gsp10-ssl.apple.com",
        "gsp64-ssl.ls.apple.com",
        "gspe1-ssl.ls.apple.com",
        "gspe19-ssl.ls.apple.com",
        "gspe19-2-ssl.ls.apple.com",
        "gspe35-ssl.ls.apple.com",
        "gspe79-ssl.ls.apple.com",
        "gspe85-ssl.ls.apple.com",
        "bluedot.is.autonavi.com",
        "bluedot.is.autonavi.com.gds.alibabadns.com",
    ]

    /// 查询动作：检查客户端是否已装好模块，并读回当前保存的坐标。
    enum Action: String {
        case query
        case clear
    }

    /// 构造配置接口 URL。坐标一律使用 WGS-84。
    ///
    /// `drift` 是运动状态模拟的原地抖动半径（米），0 或 nil 表示关闭。
    static func url(
        action: Action? = nil,
        wgs84Latitude: Double? = nil,
        wgs84Longitude: Double? = nil,
        accuracy: Int? = nil,
        driftRadius: Int? = nil
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "gs-loc.apple.com"
        components.path = settingsPath

        var items: [URLQueryItem] = []
        if let action {
            items.append(URLQueryItem(name: "action", value: action.rawValue))
        }
        if let wgs84Longitude {
            items.append(URLQueryItem(name: "lon", value: String(format: "%.6f", wgs84Longitude)))
        }
        if let wgs84Latitude {
            items.append(URLQueryItem(name: "lat", value: String(format: "%.6f", wgs84Latitude)))
        }
        if let accuracy {
            items.append(URLQueryItem(name: "acc", value: String(accuracy)))
        }
        if let driftRadius {
            items.append(URLQueryItem(name: "drift", value: String(driftRadius)))
        }
        components.queryItems = items.isEmpty ? nil : items

        return components.url
    }

    /// 客户端应当返回的 JSON 结构。
    struct Response: Codable {
        let success: Bool
        let longitude: Double?
        let latitude: Double?
        let accuracy: Int?
        let driftRadius: Int?
        let error: String?
        /// 拦截这次请求的客户端标识（`shadowrocket` / `surge` / `quantumultx`…）。
        ///
        /// 由脚本自己探测运行环境得出。它回答的是一个别的方式答不了的问题：
        /// 「现在这套模块，到底是哪个客户端在跑」。用户在应用里换了客户端选择、
        /// 但手机上其实还开着另一个代理时，状态就不会张冠李戴。
        let env: String?
        /// 响应改写脚本最后一次运行的结果。见 `ModuleDiagnostics`。
        let diag: ModuleDiagnostics?
    }

    /// 响应改写脚本（`wloc.js`）最后一次运行的结果。
    ///
    /// 第三方模式最大的麻烦是「看不见」：规则装没装上、脚本跑到哪一步，
    /// 全在客户端自己的日志里，用户够不着。脚本每次运行都把结论写进存储，
    /// 配置接口查询时一并带回，应用就能把原因直接翻成一句话。
    struct ModuleDiagnostics: Codable, Equatable {

        /// 结论码。取值见 `wloc.js` 的 `recordDiag`。
        let outcome: String?
        /// 记录时间（Unix 毫秒）。
        let ts: Double?
        /// 改写到的位置条目数。
        let locations: Int?
        /// 命中的信封格式：arpc / marker / length-prefix / raw。
        let envelope: String?
        /// 该次响应原本是否为 gzip，脚本是否解压过。
        let gzip: Bool?
        /// 脚本运行所在的客户端（与 `Response.env` 同源）。
        let env: String?
        /// 出错时的原因。
        let reason: String?

        var date: Date? {
            guard let ts, ts > 0 else { return nil }
            return Date(timeIntervalSince1970: ts / 1000)
        }
    }
}
