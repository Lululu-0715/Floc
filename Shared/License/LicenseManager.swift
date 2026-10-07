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

    /// 是否允许使用核心功能（虚拟定位）
    var isUsable: Bool { status.isUsable }

    /// 是否在试用中
    var isTrial: Bool { status == .trial }

    /// 距到期还有几天（试用/卡密都用这个数）
    var daysLeftText: String {
        guard remainingDays > 0 else { return "已到期" }
        if remainingDays >= 365 {
            let years = Double(remainingDays) / 365.0
            return String(format: "剩余 %.1f 年", years)
        }
        return "剩余 \(remainingDays) 天"
    }

    // MARK: - 校验

    /// 向服务端校验并刷新状态。
    ///
    /// - Parameter silent: 静默模式不弹错误（用于后台刷新）
    func refresh(silent: Bool = false) async {
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
        cardTypeLabel = state.typeLabel
        bonusDays = state.bonusDays ?? 0
    }

    private func saveToCache() {
        let snapshot: [String: Any] = [
            "status": status.rawValue,
            "remainingDays": remainingDays,
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

        // 用缓存拼一个 LicenseState，剩余天数按离线时长扣减
        let decayed = max(0, remainingDays - Int(elapsedDays))
        return LicenseState(
            ok: true,
            status: LicenseStatus(rawValue: dict["status"] as? String ?? "") ?? .unregistered,
            type: nil,
            days: nil,
            expireAt: nil,
            bonusDays: dict["bonusDays"] as? Int,
            bonusMs: nil,
            remainingDays: decayed,
            remainingMs: nil,
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
