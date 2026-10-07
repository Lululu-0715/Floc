import Foundation

/// 授权状态。
///
/// 刻意做成一棵「从优到劣」的枚举：判断能否使用时只需要看
/// `isUsable`，不需要在各处散落 `if status == xxx` 的组合判断。
enum LicenseStatus: String, Codable {
    /// 卡密有效期内
    case active
    /// 试用期内
    case trial
    /// 只有推荐奖励时长（无卡密）
    case bonus
    /// 试用已过期，未激活
    case trialExpired = "trial_expired"
    /// 卡密已过期
    case expired
    /// 从未登记过（新设备且没连过网）
    case unregistered
    /// 离线，用的是上次缓存的结果
    case offline

    /// 是否允许使用虚拟定位功能
    var isUsable: Bool {
        switch self {
        case .active, .trial, .bonus, .offline:
            return true
        case .trialExpired, .expired, .unregistered:
            return false
        }
    }

    /// 展示用的文案 key
    var displayNameKey: String {
        switch self {
        case .active:       return "已激活"
        case .trial:        return "试用中"
        case .bonus:        return "推荐奖励"
        case .trialExpired: return "试用已结束"
        case .expired:      return "已过期"
        case .unregistered: return "未激活"
        case .offline:      return "离线可用"
        }
    }
}

/// 服务端 `/api/verify` 的返回。
struct LicenseState: Codable {
    var ok: Bool
    var status: LicenseStatus
    /// 卡密类型（month / quarter / …），试用时为空
    var type: String?
    /// 卡密本身的天数
    var days: Int?
    /// 到期时间戳（ms）
    var expireAt: Double?
    /// 推荐奖励天数
    var bonusDays: Int?
    /// 推荐奖励剩余毫秒
    var bonusMs: Double?
    /// 总剩余天数（含推荐奖励）
    var remainingDays: Int
    var remainingMs: Double?
    var serverTime: Double

    /// 卡密类型的中文名
    var typeLabel: String? {
        guard let type else { return nil }
        switch type {
        case "month":    return "月卡"
        case "quarter":  return "季卡"
        case "halfyear": return "半年卡"
        case "year":     return "年卡"
        default:         return type
        }
    }
}

/// 激活卡密的返回。
struct ActivationResult: Codable {
    var ok: Bool
    var alreadyActivated: Bool?
    var type: String?
    var days: Int?
    var expireAt: Double?
    var remainingDays: Int?
    var error: String?
    var message: String?
}

/// 推荐进度。
struct ReferralStatus: Codable {
    var ok: Bool
    /// 我的邀请码
    var code: String?
    /// 已达到门槛的被推荐人数
    var invitedCount: Int
    /// 其中已付费的人数
    var paidCount: Int
    /// 累计获得的奖励天数
    var bonusDays: Int
    /// 已发放的档位
    var awardedTiers: [Int]?
    /// 下一档
    var nextTier: ReferralTier?
    /// 距下一档还差几人
    var towardNext: Int
    /// 封顶天数
    var capDays: Int
    /// 奖励剩余天数
    var bonusRemainingDays: Int?
    /// 我是被推荐人时的进度
    var asReferred: ReferredProgress?

    struct ReferralTier: Codable {
        var count: Int
        var days: Int
    }

    struct ReferredProgress: Codable {
        var inviterCode: String
        var streakDays: Int
        var qualified: Bool
        var requiredDays: Int
    }
}

/// 通用错误返回
struct APIError: Codable {
    var ok: Bool
    var error: String
    var message: String?
}

/// 服务端返回的业务错误。
///
/// 单独定义是为了把「服务端明确拒绝」和「网络不通」区分开：
/// 前者不该走离线宽限，后者才走。
enum LicenseError: LocalizedError {
    /// 服务端明确返回了错误
    case server(code: String, message: String)
    /// 网络层错误
    case network(String)
    /// 返回体无法解析
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .server(_, let message): return message
        case .network(let detail):    return "网络异常：\(detail)"
        case .decoding(let detail):   return "返回数据异常：\(detail)"
        }
    }

    /// 是否属于「可以走离线宽限」的错误（只有网络问题才算）
    var allowsOfflineGrace: Bool {
        if case .network = self { return true }
        return false
    }

    /// 服务端错误码
    var code: String? {
        if case .server(let code, _) = self { return code }
        return nil
    }
}
