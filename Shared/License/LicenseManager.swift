import Foundation
import Combine

/// 授权中枢。
///
/// 职责：
///   1. 启动/回前台时向服务端校验，得到权威状态
///   2. 断网时用本地缓存 + 离线宽限，避免地铁里没法用
///   3. 激活卡密、解绑设备
///   4. 每天上报一次使用心跳，用于推荐系统的「连续使用 3 天」判定
///
/// 注意：这里的所有判断都只是「客户端体验层」，真正的防刷靠服务端。
/// 客户端被越狱破解只能骗过自己，服务端仍会拒绝签发状态。
@MainActor
final class LicenseManager: ObservableObject {

    static let shared = LicenseManager()

    // MARK: - 发布状态

    /// 当前授权状态
    @Published private(set) var status: LicenseStatus = .unregistered

    /// 剩余天数（含推荐奖励）
    @Published private(set) var remainingDays: Int = 0

    /// 剩余时长（毫秒，含推荐奖励）。
    ///
    /// 比 `remainingDays` 精细：设置页的「账号」卡片要显示到分钟
    /// （`3 天 3 小时 12 分钟`），只靠天数看不出刚激活的场景。
    @Published private(set) var remainingMs: Double = 0

    /// 卡密类型名（月卡/季卡…），试用或未激活时为 nil
    @Published private(set) var cardTypeLabel: String?

    /// 推荐奖励天数
    @Published private(set) var bonusDays: Int = 0

    /// 推荐进度
    @Published private(set) var referral: ReferralStatus?

    /// 正在请求中（用于按钮转菊花）
    @Published private(set) var isBusy = false

    /// 最近一次错误文案，UI 弹完要清掉
    @Published var lastErrorMessage: String?

    /// 是否完成过一次校验（UI 用它决定要不要显示骨架）
    @Published private(set) var hasLoaded = false

    // MARK: - 本地缓存 key

    private enum CacheKey {
        static let state      = "license.cached.state"
        static let verifiedAt = "license.cached.verifiedAt"
        static let heartbeat  = "license.heartbeat.lastDay"
        static let cardKey    = "license.cached.cardKey"
    }

    private let defaults = UserDefaults.standard
    private let api = LicenseAPI.shared
    private let deviceId = DeviceIdentity.current

    private init() {
        restoreFromCache()
    }

    // MARK: - 对外：能不能用

    /// 是否处于「本地模式」。
    ///
    /// 授权服务端还没配置（`baseURL` 仍是占位符）时为真：此时不做任何
    /// 校验，也不拦功能，方便后端就绪前自测。详见 `LicenseConfig.isConfigured`。
    var isLocalMode: Bool { !LicenseConfig.isConfigured }

    /// 是否允许使用核心功能（虚拟定位）
    var isUsable: Bool { isLocalMode || status.isUsable }

    /// 是否在试用中
    var isTrial: Bool { status == .trial }

    /// 展示用的状态名。本地模式下覆盖成「本地模式」，
    /// 否则用户会看到一个「未激活」的红锁却又能正常用，前后矛盾。
    var displayNameKey: String {
        isLocalMode ? "本地模式" : status.displayNameKey
    }

    /// 距到期还剩多久（含推荐奖励）。
    ///
    /// 精确到分钟：刚激活时只显示「剩余 30 天」看不出倒计时在走，
    /// 用户会怀疑到底有没有生效。天数 ≥ 1 时补上小时与分钟。
    var remainingText: String {
        if isLocalMode {
            return AppLocalization.string("未配置授权服务端，不做校验")
        }
        return Self.describe(remainingMs: remainingMs)
    }

    /// 把毫秒数格式化成「x 天 x 小时 x 分钟」。
    ///
    /// 单独抽出来是为了能单测——边界（刚好 1 天 / 刚好 1 小时 / 不足 1 分钟）
    /// 最容易写错，而这段文案每次打开设置页都会显示。
    static func describe(remainingMs: Double) -> String {
        guard remainingMs > 0 else {
            return AppLocalization.string("已到期")
        }

        let totalSeconds = Int(remainingMs / 1000)
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60

        if days > 0 {
            return String(format: AppLocalization.string("%ld 天 %ld 小时 %ld 分钟"), days, hours, minutes)
        }
        if hours > 0 {
            return String(format: AppLocalization.string("%ld 小时 %ld 分钟"), hours, minutes)
        }
        return String(format: AppLocalization.string("%ld 分钟"), minutes)
    }

    /// 兼容旧调用点：只用「天」表述的场合。
    var daysLeftText: String {
        guard remainingDays > 0 else { return AppLocalization.string("已到期") }
        if remainingDays >= 365 {
            let years = Double(remainingDays) / 365.0
            return String(format: AppLocalization.string("剩余 %.1f 年"), years)
        }
        return String(format: AppLocalization.string("剩余 %ld 天"), remainingDays)
    }

    // MARK: - 校验

    /// 向服务端校验并刷新状态。
    ///
    /// - Parameter silent: 静默模式不弹错误（用于后台刷新）
    func refresh(silent: Bool = false) async {
        // 本地模式：直接放行，连一次请求都不发。
        // 之前占位地址会让每次启动都白等 12 秒超时，还弹一条「网络异常」，
        // 而后端根本没部署——纯噪声。
        if isLocalMode {
            hasLoaded = true
            lastErrorMessage = nil
            return
        }

        guard !isBusy else { return }
        if !silent { isBusy = true }
        defer { if !silent { isBusy = false } }

        do {
            let state = try await api.verify(deviceId: deviceId)
            apply(state)
            saveToCache()
            hasLoaded = true
        } catch let error as LicenseError {
            if error.allowsOfflineGrace, let cached = cachedStateIfWithinGrace() {
                // 网络不通但缓存还在宽限期内 → 继续用
                apply(cached, asOffline: true)
                hasLoaded = true
                if !silent { lastErrorMessage = nil }
            } else {
                hasLoaded = true
                if !silent { lastErrorMessage = error.errorDescription }
            }
        } catch {
            if !silent { lastErrorMessage = error.localizedDescription }
        }
    }

    // MARK: - 激活 / 解绑

    /// 用卡密激活，成功返回 true
    @discardableResult
    func activate(cardKey: String) async -> Bool {
        guard !isLocalMode else {
            lastErrorMessage = AppLocalization.string("尚未配置授权服务端，当前为本地模式，无需卡密")
            return false
        }

        let key = cardKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else {
            lastErrorMessage = "请输入卡密"
            return false
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await api.activate(deviceId: deviceId, cardKey: key)
            guard result.ok else {
                lastErrorMessage = result.message ?? "激活失败"
                return false
            }

            defaults.set(key, forKey: CacheKey.cardKey)
            // 激活后重新拉一次 verify，拿到统一格式的状态（含推荐奖励叠加）
            await refresh(silent: true)
            return true
        } catch let error as LicenseError {
            lastErrorMessage = error.errorDescription
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    /// 自助解绑（换手机用），成功返回 true
    @discardableResult
    func unbind() async -> Bool {
        guard !isLocalMode else {
            lastErrorMessage = AppLocalization.string("尚未配置授权服务端，当前为本地模式，无需解绑")
            return false
        }

        let key = defaults.string(forKey: CacheKey.cardKey) ?? ""
        guard !key.isEmpty else {
            lastErrorMessage = "本机没有已激活的卡密"
            return false
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await api.unbind(deviceId: deviceId, cardKey: key)
            guard result.ok else {
                lastErrorMessage = result.message ?? "解绑失败"
                return false
            }
            defaults.removeObject(forKey: CacheKey.cardKey)
            await refresh(silent: true)
            return true
        } catch let error as LicenseError {
            lastErrorMessage = error.errorDescription
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - 推荐

    /// 拉取我的邀请码（首次调用时服务端自动生成）
    func loadReferralCode() async {
        guard !isLocalMode else { return }
        do {
            referral = try await api.referralCode(deviceId: deviceId)
        } catch let error as LicenseError {
            lastErrorMessage = error.errorDescription
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// 填写别人的邀请码
    @discardableResult
    func bindReferral(code: String) async -> Bool {
        guard !isLocalMode else {
            lastErrorMessage = AppLocalization.string("尚未配置授权服务端，推荐功能暂不可用")
            return false
        }

        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await api.referralBind(deviceId: deviceId, code: code)
            await loadReferralStatus()
            return true
        } catch let error as LicenseError {
            lastErrorMessage = error.errorDescription
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    /// 查询推荐进度
    func loadReferralStatus() async {
        guard !isLocalMode else { return }
        do {
            referral = try await api.referralStatus(deviceId: deviceId)
        } catch {
            // 推荐进度查失败不打扰用户，静默即可
        }
    }

    /// 每天上报一次使用心跳。
    ///
    /// 用「UTC 日期」做去重，保证同一天多次启动只算一次。
    /// 被推荐人连续 3 天打开 App 后，服务端会自动给推荐人发奖励。
    func reportDailyHeartbeatIfNeeded() async {
        guard !isLocalMode else { return }

        let today = ISO8601DateFormatter.dayString(from: Date())
        let last = defaults.string(forKey: CacheKey.heartbeat)

        guard last != today else { return }

        do {
            _ = try await api.referralHeartbeat(deviceId: deviceId)
            defaults.set(today, forKey: CacheKey.heartbeat)
        } catch {
            // 心跳失败无所谓，下次启动再试
        }
    }

    // MARK: - 内部：状态落地

    private func apply(_ state: LicenseState, asOffline: Bool = false) {
        status = asOffline ? .offline : state.status
        remainingDays = state.remainingDays
        // 老服务端可能只回了天数，这里补一个等价毫秒数，保证「天数/小时/分钟」
        // 三档展示都有值。
        remainingMs = state.remainingMs ?? Double(state.remainingDays) * 86_400_000
        cardTypeLabel = state.typeLabel
        bonusDays = state.bonusDays ?? 0
    }

    private func saveToCache() {
        let snapshot: [String: Any] = [
            "status": status.rawValue,
            "remainingDays": remainingDays,
            "remainingMs": remainingMs,
            "cardTypeLabel": cardTypeLabel as Any,
            "bonusDays": bonusDays,
            "savedAt": Date().timeIntervalSince1970,
        ]
        defaults.set(snapshot, forKey: CacheKey.state)
        defaults.set(Date().timeIntervalSince1970, forKey: CacheKey.verifiedAt)
    }

    /// 恢复缓存（冷启动时先给 UI 一个值，避免白屏）
    private func restoreFromCache() {
        guard let snapshot = defaults.dictionary(forKey: CacheKey.state) else { return }
        if let raw = snapshot["status"] as? String,
           let cachedStatus = LicenseStatus(rawValue: raw) {
            status = cachedStatus
        }
        remainingDays = snapshot["remainingDays"] as? Int ?? 0
        let cachedMs = snapshot["remainingMs"] as? Double
        let savedAt = snapshot["savedAt"] as? TimeInterval
        // 缓存里的毫秒数是「上次校验那一刻」的，按已过去的真实时间扣一下，
        // 否则冷启动瞬间会显示一个虚高的倒计时。
        if let cachedMs {
            let elapsedMs = savedAt.map { (Date().timeIntervalSince1970 - $0) * 1000 } ?? 0
            remainingMs = max(0, cachedMs - elapsedMs)
        } else {
            remainingMs = Double(remainingDays) * 86_400_000
        }
        cardTypeLabel = snapshot["cardTypeLabel"] as? String
        bonusDays = snapshot["bonusDays"] as? Int ?? 0
    }

    /// 取缓存，但只在宽限期内有效
    private func cachedStateIfWithinGrace() -> LicenseState? {
        guard let dict = defaults.dictionary(forKey: CacheKey.state),
              let savedAt = dict["savedAt"] as? TimeInterval
        else {
            return nil
        }

        let elapsedDays = (Date().timeIntervalSince1970 - savedAt) / 86400
        guard elapsedDays <= Double(LicenseConfig.offlineGraceDays) else { return nil }

        // 用缓存拼一个 LicenseState，剩余时长按离线时长扣减
        let elapsedMs = (Date().timeIntervalSince1970 - savedAt) * 1000
        let cachedMs = dict["remainingMs"] as? Double ?? Double(remainingDays) * 86_400_000
        let decayedMs = max(0, cachedMs - elapsedMs)
        return LicenseState(
            ok: true,
            status: LicenseStatus(rawValue: dict["status"] as? String ?? "") ?? .unregistered,
            type: nil,
            days: nil,
            expireAt: nil,
            bonusDays: dict["bonusDays"] as? Int,
            bonusMs: nil,
            remainingDays: Int(decayedMs / 86_400_000),
            remainingMs: decayedMs,
            serverTime: Date().timeIntervalSince1970 * 1000
        )
    }
}

// MARK: - 工具

private extension ISO8601DateFormatter {
    /// 取 UTC 日期串（yyyy-MM-dd），与服务端 dayKey 对齐
    static func dayString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
