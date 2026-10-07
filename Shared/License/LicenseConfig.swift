import Foundation

/// 卡密 / 推荐系统的服务端地址与业务常量。
///
/// 部署完 Cloudflare Worker 后，把 `baseURL` 换成你自己的域名即可，
/// 其余常量与 Worker 侧保持一一对应，改的时候两边要一起改。
enum LicenseConfig {

    // MARK: - 服务端地址

    /// Worker 地址（结尾不要带斜杠）。
    ///
    /// 例：`"https://floc-license.your-name.workers.dev"`
    ///
    /// 还是占位符时 App 会进入「本地模式」——不发授权请求、也不做授权闸门，
    /// 详见 `isConfigured`。
    static let baseURL = "https://floc-license.YOUR-SUBDOMAIN.workers.dev"

    /// 占位符里出现的片段，用来判断 `baseURL` 有没有被真正替换过。
    private static let placeholderMarker = "YOUR-SUBDOMAIN"

    /// 授权服务端是否已经配置好。
    ///
    /// 没配置时整个卡密系统降级成「本地模式」：
    ///   - 不发任何网络请求（省掉每次启动 12 秒超时和一条报错弹窗）；
    ///   - 授权闸门放行，开发者后端都还没部署时也能自测全部功能；
    ///   - 设置页「账号」分组里明确标注「本地模式」，不会让人误以为已激活。
    ///
    /// 把 `baseURL` 换成真实域名后，校验与闸门自动恢复，不需要改其他代码。
    static var isConfigured: Bool {
        !baseURL.isEmpty && !baseURL.contains(placeholderMarker)
    }

    // MARK: - 超时

    /// 单次请求超时（秒）。卡密校验是启动关键路径，不宜拖太久。
    static let requestTimeout: TimeInterval = 12

    /// 离线宽限期（天）。
    ///
    /// 校验失败（断网 / 服务端抽风）时，允许在这么多天内继续使用上次
    /// 成功的授权结果，避免用户在地铁里就没法用。
    static let offlineGraceDays = 3

    // MARK: - 试用

    /// 试用天数，需与 Worker 的 `TRIAL_DAYS` 一致
    static let trialDays = 3

    // MARK: - 推荐

    /// 被推荐人需连续使用的天数（与 Worker 的 `REFERRAL_REQUIRED_DAYS` 一致）
    static let referralRequiredDays = 3

    /// 被推荐人付费后推荐人额外获得的天数（与 Worker 一致）
    static let referralPaidBonusDays = 15

    /// 推荐奖励封顶天数（与 Worker 的 `REFERRAL_CAP_DAYS` 一致）
    static let referralCapDays = 365 * 3

    /// 本地展示用的档位表（真正的发放以服务端为准，这里只用于画进度条）
    static let referralTiers: [(count: Int, days: Int)] = [
        (3, 7),
        (7, 15),
        (15, 30),
        (30, 90),
        (50, 180),
        (100, 365),
    ]

    // MARK: - 请求头

    /// 服务端没有做鉴权，但带上一个自定义 UA 便于在 Worker 日志里区分客户端。
    static let userAgent = "Floc-iOS"

    /// 应用版本，随报错一起上报，便于定位「哪个版本的用户在报错」
    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v)(\(b))"
    }
}
