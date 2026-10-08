import UIKit
import Foundation

/// 远程配置。
///
/// 用途：当 Apple 侧改动 WLOC 协议导致脚本失效时，可以不发新版本就让旧版本
/// 应用感知到问题并提示用户。这里只做「取一个 JSON、放宽期限」这一件事，
/// 不涉及任何用户数据上报。
@MainActor
final class AppRemoteConfigurationStore: ObservableObject {

    static let shared = AppRemoteConfigurationStore()

    struct Configuration: Codable {
        /// 当前已知失效的最低系统版本，例如 "27.0"。命中时界面给出警示。
        var blockedFromSystemVersion: String?
        /// 给用户看的公告文本。
        var announcement: String?
        /// 公告的有效期，过期后不再展示。
        var announcementExpiresAt: Date?

        var isAnnouncementVisible: Bool {
            guard let text = announcement, !text.isEmpty else { return false }
            guard let expiry = announcementExpiresAt else { return true }
            return expiry > Date()
        }
    }

    /// 默认配置地址。换成自己的托管地址时改这里。
    ///
    /// **为什么和模块一样用 jsDelivr 而不是 `raw.githubusercontent.com`**：
    /// `raw.githubusercontent.com` 在国内基本不可用，`refresh()` 拉不到就
    /// 静默沿用缓存（这是刻意的降级路径，但它意味着远端配置**永远不会更新**）。
    /// 也就是说，写 raw 地址等于把「不发版也能改行为」这条后路悄悄堵死了，
    /// 而且不会报错——只有翻运行日志才看得到「远程配置拉取失败」。
    ///
    /// jsDelivr 对分支的缓存最长 12 小时，改完配置要等一阵子才全网生效。
    static let defaultConfigurationURL =
        "https://cdn.jsdelivr.net/gh/Lululu-0715/Floc@main/Resources/remote-config.json"

    @Published private(set) var configuration = Configuration()
    @Published private(set) var lastFetchedAt: Date?

    /// 当前系统版本是否落在「已知失效」区间。
    @Published private(set) var systemVersionBlocked = false

    private let defaults: UserDefaults
    private let session: URLSession
    private let storageKey = "remoteConfiguration"

    private init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)

        // 先用缓存里的配置撑住首屏，避免每次启动都白等网络。
        if let data = defaults.data(forKey: storageKey),
           let cached = try? JSONDecoder().decode(Configuration.self, from: data) {
            self.configuration = cached
        }
        evaluateSystemVersion()
    }

    /// 拉取远程配置。失败时静默保留旧配置，不打扰用户。
    func refresh() async {
        guard let url = URL(string: Self.defaultConfigurationURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(Configuration.self, from: data)
            configuration = decoded
            lastFetchedAt = Date()
            if let encoded = try? JSONEncoder().encode(decoded) {
                defaults.set(encoded, forKey: storageKey)
            }
            evaluateSystemVersion()
            RuntimeLogger.info("APP", "RemoteConfig", "远程配置已更新")
        } catch {
            // 网络不可达、仓库还没建好都会走到这里，属于预期内的降级路径。
            RuntimeLogger.debug("APP", "RemoteConfig", "远程配置拉取失败，沿用缓存", details: [
                "error": (error as NSError).localizedDescription,
            ])
        }
    }

    /// 对比当前系统版本与配置里声明的「已知失效」起始版本。
    private func evaluateSystemVersion() {
        guard let blockedFrom = configuration.blockedFromSystemVersion else {
            systemVersionBlocked = false
            return
        }

        let current = UIDevice.current.systemVersion
        systemVersionBlocked = compareVersions(current, blockedFrom) >= 0

        if systemVersionBlocked {
            RuntimeLogger.warn("APP", "RemoteConfig", "当前系统版本已被标记为不兼容", details: [
                "current": current,
                "blockedFrom": blockedFrom,
            ])
        }
    }

    /// 语义化版本比较。返回 -1 / 0 / 1。
    private func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)

        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
