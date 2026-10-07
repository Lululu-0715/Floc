// 纯净版（`PURE_BUILD`）不带卡密，这里的授权服务端通信整体不参与编译。
// 口味开关见 `Shared/BuildFlavor.swift`。
#if !PURE_BUILD
import Foundation

/// 与 Cloudflare Worker 通信的薄客户端。
///
/// 只负责「发请求 + 解析 JSON + 分错误类型」，不含任何业务状态，
/// 状态都放 `LicenseManager` 里。
struct LicenseAPI {

    static let shared = LicenseAPI()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = LicenseConfig.requestTimeout
        config.timeoutIntervalForResource = LicenseConfig.requestTimeout
        // 授权校验必须拿最新的，不能被 URL 缓存糊弄
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    // MARK: - 对外接口

    /// 校验当前设备状态
    func verify(deviceId: String) async throws -> LicenseState {
        try await post("/api/verify", body: ["deviceId": deviceId], as: LicenseState.self)
    }

    /// 用卡密激活
    func activate(deviceId: String, cardKey: String) async throws -> ActivationResult {
        try await post(
            "/api/activate",
            body: ["deviceId": deviceId, "cardKey": cardKey],
            as: ActivationResult.self
        )
    }

    /// 解绑设备
    func unbind(deviceId: String, cardKey: String) async throws -> ActivationResult {
        try await post(
            "/api/unbind",
            body: ["deviceId": deviceId, "cardKey": cardKey],
            as: ActivationResult.self
        )
    }

    // MARK: - 推荐

    /// 获取（首次自动生成）我的邀请码
    func referralCode(deviceId: String) async throws -> ReferralStatus {
        try await post("/api/referral/code", body: ["deviceId": deviceId], as: ReferralStatus.self)
    }

    /// 填写别人的邀请码
    func referralBind(deviceId: String, code: String) async throws -> ReferralStatus {
        try await post(
            "/api/referral/bind",
            body: ["deviceId": deviceId, "code": code],
            as: ReferralStatus.self
        )
    }

    /// 使用心跳（累计连续使用天数）
    func referralHeartbeat(deviceId: String) async throws -> ReferralStatus {
        try await post(
            "/api/referral/heartbeat",
            body: ["deviceId": deviceId],
            as: ReferralStatus.self
        )
    }

    /// 查询推荐进度
    func referralStatus(deviceId: String) async throws -> ReferralStatus {
        try await post(
            "/api/referral/status",
            body: ["deviceId": deviceId],
            as: ReferralStatus.self
        )
    }

    // MARK: - 内部

    private func post<T: Decodable>(
        _ path: String,
        body: [String: Any],
        as type: T.Type
    ) async throws -> T {
        guard let url = URL(string: LicenseConfig.baseURL + path) else {
            throw LicenseError.decoding("接口地址不合法：\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(LicenseConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(LicenseConfig.appVersion, forHTTPHeaderField: "X-Floc-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LicenseError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LicenseError.decoding("非 HTTP 响应")
        }

        // 服务端约定：业务错误也用 JSON 返回，形如 { ok:false, error, message }
        // 因此先尝试解码错误体，成功就按业务错误抛，失败再按解码错误处理。
        if !(200..<300).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(APIError.self, from: data) {
                throw LicenseError.server(
                    code: apiError.error,
                    message: apiError.message ?? apiError.error
                )
            }
            throw LicenseError.decoding("HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LicenseError.decoding(error.localizedDescription)
        }
    }
}
#endif
