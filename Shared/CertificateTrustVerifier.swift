import Foundation
import Security
import UIKit

/// 检查根证书是否已在系统「证书信任设置」中被完整信任。
///
/// 为什么不能直接读系统信任列表：iOS 没有公开 API 能查询用户是否手动信任了
/// 某个自签根证书。所以这里采用「行为验证」——用该 CA 签发的 127.0.0.1 叶子
/// 证书起一个 HTTPS 服务，用系统默认的信任评估去请求它。能被系统接受，就证明
/// 证书已装好并信任；被拒绝，则说明还没装、没信任，或者只装了没开信任开关。
enum CertificateTrustVerifier {

    enum TrustState: Equatable {
        /// 证书服务还没起来，无法验证。
        case unknown
        /// 已安装且已信任。
        case trusted
        /// 未安装，或已安装但未开启完全信任。
        case notTrusted
        /// 验证过程本身出错（例如网络栈异常）。
        case failed(String)

        var isTrusted: Bool { self == .trusted }

        var displayText: String {
            switch self {
            case .unknown: return AppLocalization.string("未验证")
            case .trusted: return AppLocalization.string("已信任")
            case .notTrusted: return AppLocalization.string("未信任")
            case .failed: return AppLocalization.string("验证失败")
            }
        }
    }

    /// 用系统默认信任评估去访问探测端点。
    static func verify(probeURL: URL, timeout: TimeInterval = 3.0) async -> TrustState {
        var request = URLRequest(url: probeURL)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        // 关键：不使用任何自定义 URLSessionDelegate，走系统默认信任评估。
        // 这样「请求成功」才等价于「系统信任该证书链」。
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)

        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                RuntimeLogger.info("APP", "Certificate.verify", "证书信任验证通过")
                return .trusted
            }
            return .failed("HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
        } catch {
            let nsError = error as NSError
            // 典型的「证书不被信任」错误码集中在 NSURLErrorServerCertificate* 段。
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasBadDate,
                     NSURLErrorServerCertificateNotYetValid,
                     NSURLErrorServerCertificateHasUnknownRoot,
                     NSURLErrorSecureConnectionFailed,
                     NSURLErrorCannotConnectToHost:
                    RuntimeLogger.info("APP", "Certificate.verify", "证书未受信任", details: [
                        "errorCode": String(nsError.code),
                    ])
                    return .notTrusted
                default:
                    break
                }
            }
            RuntimeLogger.warn("APP", "Certificate.verify", "证书验证异常", details: [
                "error": nsError.localizedDescription,
            ])
            return .failed(nsError.localizedDescription)
        }
    }

    /// 跳转系统「证书信任设置」页面由 `SystemSettingsNavigator` 统一负责。
    ///
    /// 这里原先自己维护了一份 `App-Prefs` 候选表，还用 `canOpenURL` 当闸门——
    /// 而 iOS 18 起 `canOpenURL` 对 `App-Prefs` 恒返回 false，于是这个循环
    /// 一次都没进去过，直接落到 `openSettingsURLString`（Floc 自己在设置里的
    /// 那一屏）。两处维护同一件事只会让其中一份慢慢烂掉，现已合并。

    /// 用 Safari 打开证书下载地址，触发描述文件安装流程。
    @discardableResult
    static func openCertificateDownload(url: URL) -> Bool {
        guard UIApplication.shared.canOpenURL(url) else {
            RuntimeLogger.warn("APP", "Certificate.verify", "无法打开证书下载地址")
            return false
        }
        UIApplication.shared.open(url)
        return true
    }
}
