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
    static let interceptedHosts = [
        "gs-loc.apple.com",
        "gs-loc-cn.apple.com",
        "gsp-ssl.ls.apple.com",
        "bluedot.is.autonavi.com",
        "bluedot.is.autonavi.com.gds.alibabadns.com",
    ]

    /// 查询动作：检查客户端是否已装好模块，并读回当前保存的坐标。
    enum Action: String {
        case query
        case clear
    }

    /// 构造配置接口 URL。坐标一律使用 WGS-84。
    static func url(
        action: Action? = nil,
        wgs84Latitude: Double? = nil,
        wgs84Longitude: Double? = nil,
        accuracy: Int? = nil
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
        components.queryItems = items.isEmpty ? nil : items

        return components.url
    }

    /// 客户端应当返回的 JSON 结构。
    struct Response: Codable {
        let success: Bool
        let longitude: Double?
        let latitude: Double?
        let accuracy: Int?
        let error: String?
    }
}
