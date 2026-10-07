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
///
/// **纯净版（`PURE_BUILD`）下这里几乎什么都不做**：不发请求、恒放行。
/// 见 `Shared/BuildFlavor.swift`。
@MainActor
final class LicenseManager: ObservableObject {

    static let shared = LicenseManager()

    // MARK: - 发布状态

    /// 当前授权状态
    @Published private(set) var status: LicenseStatus = .unregistered

    /// 剩余时长（毫秒，含推荐奖励）。
    ///
    /// 只留毫秒这一档：设置页的「账号」卡片要显示到分钟
    /// （`3 天 3 小时 12 分钟`），只存天数看不出刚激活的场景，
    /// 而再存一份天数就得在两处同步维护，早晚会不一致。
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

    /// 当前用的是不是内置测试卡密。
    ///
    /// 测试授权是纯本地授予的（见 `LicenseConfig.testCardKeys`），
    /// 所以要单独标一下，否则界面上会显示成「已激活」，看不出这是自测状态。
    @Published private(set) var isTestLicense = false

    // MARK: - 本地缓存 key

    private enum CacheKey {
        static let state      = "license.cached.state"
        static let verifiedAt = "license.cached.verifiedAt"
        static let heartbeat  = "license.heartbeat.lastDay"
        static let cardKey    = "license.cached.cardKey"
        static let isTestCard = "license.cached.isTestCard"
    }

    private let defaults = UserDefaults.standard
    private let deviceId = DeviceIdentity.current

    #if !PURE_BUILD
    /// 纯净版里 `LicenseAPI.swift` 整个文件不参与编译，所以这个属性也不存在。
    private let api = LicenseAPI.shared
    #endif

    private init() {
        restoreFromCache()
    }

    // MARK: - 对外：能不能用

    /// 是否处于「本地模式」。
    ///
    /// 授权服务端还没配置（`baseURL` 仍是占位符）时为真：此时不做任何
    /// 校验，也不拦功能，方便后端就绪前自测。详见 `LicenseConfig.isConfigured`。
    var isLocalMode: Bool { !LicenseConfig.isConfigured }

    /// 是否允许使用核心功能（虚拟定位）。
    ///
    /// 三种放行来源：本地模式（服务端没配）、内置测试授权、真实授权。
    /// 测试授权按秒倒计时，过期就真过期——这样「到期被拦」这条路径
    /// 也能在没后端的情况下验一遍。
    var isUsable: Bool {
        // 纯净版根本没有授权这套东西，永远放行。
        if BuildFlavor.isPure { return true }
        if isTestLicense { return remainingMs > 0 }
        return isLocalMode || status.isUsable
    }

    /// 展示用的状态名。本地模式与测试授权都要覆盖，
    /// 否则用户会看到一个「未激活」的红锁却又能正常用，前后矛盾。
    var displayNameKey: String {
        if isTestLicense { return "测试授权" }
        if isLocalMode { return "本地模式" }
        return status.displayNameKey
    }

    /// 距到期还剩多久（含推荐奖励）。
    ///
    /// 精确到分钟：刚激活时只显示「剩余 30 天」看不出倒计时在走，
    /// 用户会怀疑到底有没有生效。天数 ≥ 1 时补上小时与分钟。
    var remainingText: String {
        if isTestLicense {
            return Self.describe(remainingMs: remainingMs)
        }
        if isLocalMode {
            return AppLocalization.string("未配置授权服务端，不做校验")
        }
        return Self.describe(remainingMs: remainingMs)
    }

    /// 设置页第一层那行用的短文案。
    ///
    /// 列表行里是「图标 + 标题 + 取值 + 箭头」，塞不下
    /// 「30 天 5 小时 12 分钟」，硬放会被截断成「30 天 5 小…」。
    /// 这一层只需要「大概还有多久」，精确到分钟的完整文案留在二级页。
    var remainingSummaryText: String {
        if isLocalMode { return AppLocalization.string("本地模式") }
        guard remainingMs > 0 else { return AppLocalization.string("已到期") }

        let totalSeconds = Int(remainingMs / 1000)
        let days = totalSeconds / 86_400
        if days > 0 { return String(format: AppLocalization.string("%ld 天"), days) }

        let hours = (totalSeconds % 86_400) / 3_600
        if hours > 0 { return String(format: AppLocalization.string("%ld 小时"), hours) }

        return String(format: AppLocalization.string("%ld 分钟"), (totalSeconds % 3_600) / 60)
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

    // MARK: - 校验

    /// 向服务端校验并刷新状态。
    ///
    /// - Parameter silent: 静默模式不弹错误（用于后台刷新）
    func refresh(silent: Bool = false) async {
        #if PURE_BUILD
        // 纯净版没有授权服务端这回事，一次请求都不发。
        lastErrorMessage = nil
        #else
        // 本地模式：直接放行，连一次请求都不发。
        // 之前占位地址会让每次启动都白等 12 秒超时，还弹一条「网络异常」，
        // 而后端根本没部署——纯噪声。
        if isLocalMode {
            lastErrorMessage = nil
            return
        }

        // 测试授权是本地授予的，服务端没有这张卡；去问一次只会把状态刷成
        // 「未激活」，把测试中的倒计时抹掉。
        if isTestLicense {
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
        } catch let error as LicenseError {
            if error.allowsOfflineGrace, let cached = cachedStateIfWithinGrace() {
                // 网络不通但缓存还在宽限期内 → 继续用
                apply(cached, asOffline: true)
                if !silent { lastErrorMessage = nil }
            } else {
                if !silent { lastErrorMessage = error.errorDescription }
            }
        } catch {
            if !silent { lastErrorMessage = error.localizedDescription }
        }
        #endif
    }

    // MARK: - 激活 / 解绑

    /// 用卡密激活，成功返回 true
    @discardableResult
    func activate(cardKey: String) async -> Bool {
        #if PURE_BUILD
        // 纯净版没有卡密，界面上也没有入口；真被调到就当激活失败。
        lastErrorMessage = nil
        return false
        #else
        let key = LicenseConfig.normalizeCardKey(cardKey)
        guard !key.isEmpty else {
            lastErrorMessage = AppLocalization.string("请输入卡密")
            return false
        }

        // 内置测试卡密：完全离线生效，不依赖服务端是否配好。
        // 放在最前面，是为了让「尚无后端」的自测场景能真的走完激活流程。
        if LicenseConfig.isTestCode(key) {
            applyTestLicense(cardKey: key)
            return true
        }

        guard !isLocalMode else {
            lastErrorMessage = AppLocalization.string("尚未配置授权服务端，当前为本地模式，无需卡密")
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

            // 真实卡密激活成功，本地测试授权让位。只在确实处于测试态时清，
            // 免得把普通用户的缓存也一并抹掉。
            if isTestLicense { clearTestLicense() }
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
        #endif
    }

    /// 自助解绑（换手机用），成功返回 true
    @discardableResult
    func unbind() async -> Bool {
        #if PURE_BUILD
        lastErrorMessage = nil
        return false
        #else
        // 测试授权服务端不认识，也不需要「解绑」——本地清掉即可。
        if isTestLicense {
            clearTestLicense()
            return true
        }

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
        #endif
    }

    // MARK: - 推荐

    /// 拉取我的邀请码（首次调用时服务端自动生成）
    func loadReferralCode() async {
        #if PURE_BUILD
        return
        #else
        guard !isLocalMode else { return }
        do {
            referral = try await api.referralCode(deviceId: deviceId)
        } catch let error as LicenseError {
            lastErrorMessage = error.errorDescription
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        #endif
    }

    /// 填写别人的邀请码
    @discardableResult
    func bindReferral(code: String) async -> Bool {
        #if PURE_BUILD
        lastErrorMessage = nil
        return false
        #else
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
        #endif
    }

    /// 查询推荐进度
    func loadReferralStatus() async {
        #if PURE_BUILD
        return
        #else
        guard !isLocalMode else { return }
        do {
            referral = try await api.referralStatus(deviceId: deviceId)
        } catch {
            // 推荐进度查失败不打扰用户，静默即可
        }
        #endif
    }

    /// 每天上报一次使用心跳。
    ///
    /// 用「UTC 日期」做去重，保证同一天多次启动只算一次。
    /// 被推荐人连续 3 天打开 App 后，服务端会自动给推荐人发奖励。
    func reportDailyHeartbeatIfNeeded() async {
        #if PURE_BUILD
        return
        #else
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
        #endif
    }

    // MARK: - 内部：状态落地

    private func apply(_ state: LicenseState, asOffline: Bool = false) {
        status = asOffline ? .offline : state.status
        // 老服务端可能只回了天数，这里补一个等价毫秒数，保证「天数/小时/分钟」
        // 三档展示都有值。
        remainingMs = state.remainingMs ?? Double(state.remainingDays) * 86_400_000
        cardTypeLabel = state.typeLabel
        bonusDays = state.bonusDays ?? 0
    }

    // MARK: - 内部：内置测试授权

    /// 用内置测试卡密就地授予一份授权。
    ///
    /// 全程不发请求，所以离线、后端未部署时都能用。天数从**授予那一刻**
    /// 起算，跟真实卡密一样会随时间衰减。
    private func applyTestLicense(cardKey: String) {
        isTestLicense = true
        status = .active
        cardTypeLabel = LicenseConfig.testCardTypeLabel
        bonusDays = 0
        remainingMs = Double(LicenseConfig.testCardDays) * 86_400_000
        lastErrorMessage = nil

        defaults.set(cardKey, forKey: CacheKey.cardKey)
        defaults.set(true, forKey: CacheKey.isTestCard)
        saveToCache()

        RuntimeLogger.info("APP", "License", "已用内置测试卡密激活", details: [
            "days": String(LicenseConfig.testCardDays),
        ])
    }

    /// 清掉测试授权，回到「未激活」。
    ///
    /// 连缓存一起清：测试授权在服务端没有任何记录，留着缓存只会在下次冷启动
    /// 时把这份本地授予的状态又读回来。
    private func clearTestLicense() {
        isTestLicense = false
        status = .unregistered
        remainingMs = 0
        cardTypeLabel = nil
        bonusDays = 0

        defaults.removeObject(forKey: CacheKey.isTestCard)
        defaults.removeObject(forKey: CacheKey.cardKey)
        defaults.removeObject(forKey: CacheKey.state)
        defaults.removeObject(forKey: CacheKey.verifiedAt)
    }

    private func saveToCache() {
        let snapshot: [String: Any] = [
            "status": status.rawValue,
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
        // 测试授权标记要先读回来：下面 `remainingMs` 的衰减逻辑两条路都走，
        // 但只有这个标记能让界面显示成「测试授权」而不是「已激活」。
        isTestLicense = defaults.bool(forKey: CacheKey.isTestCard)

        guard let snapshot = defaults.dictionary(forKey: CacheKey.state) else { return }
        if let raw = snapshot["status"] as? String,
           let cachedStatus = LicenseStatus(rawValue: raw) {
            status = cachedStatus
        }
        remainingMs = 0
        let savedAt = snapshot["savedAt"] as? TimeInterval
        // 缓存里的毫秒数是「上次校验那一刻」的，按已过去的真实时间扣一下，
        // 否则冷启动瞬间会显示一个虚高的倒计时。
        if let cachedMs = snapshot["remainingMs"] as? Double {
            let elapsedMs = savedAt.map { (Date().timeIntervalSince1970 - $0) * 1000 } ?? 0
            remainingMs = max(0, cachedMs - elapsedMs)
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

        // 用缓存拼一个 LicenseState，剩余时长按离线时长扣减。
        // 拿不到剩余毫秒（老格式缓存）就当作不可用，走正常的错误提示。
        guard let cachedMs = dict["remainingMs"] as? Double else { return nil }
        let elapsedMs = (Date().timeIntervalSince1970 - savedAt) * 1000
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
