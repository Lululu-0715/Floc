import Combine
import CoreLocation
import Foundation
import SwiftUI

/// 判断「虚拟定位到底生效了没有」。
///
/// 背景：定位服务把上一次的结果缓存（在系统进程里）很久，用户点「开启虚拟定位」
/// 之后地图上往往还是旧位置，必须去系统设置里把「定位服务」关一下再打开，
/// 强制重新查询一次才会跳到选点。这一步做完**到底成没成**，App 自己不吭声，
/// 用户只能盯着地图猜。
///
/// 判据只有一条，但很硬：**回读本机定位，比对目标点**。
/// 本机的定位请求和被"骗"的那些 App 走的是同一条链路（都经过代理改写），
/// 所以回读到的坐标就是系统当前认定的位置：
///
///   - 落在目标点附近 → 改写已经生效；
///   - 仍是原来的真实位置 → 还没生效，继续等或者去检查链路。
///
/// 有意**不**依赖代理那边的统计（`ThirdPartyProxyManager.diagnostics`）：
/// 那一路在应用内代理模式下拿不到，而且"请求被改写"与"系统已经用上了新位置"
/// 之间还差一次重新解算——回读才是最终事实。
@MainActor
final class SpoofEffectVerifier: ObservableObject {

    static let shared = SpoofEffectVerifier()

    /// 判定为「同一个地方」的距离阈值（米）。
    ///
    /// 改写是逐字节替换经纬度，理论上回读值应当和目标点几乎完全一致。
    /// 留 80 米是给两件事：移动模拟打开时的抖动半径（最大 20 米），
    /// 以及系统对精度字段的取整。真实位置与选点差着几百米起步，
    /// 这个阈值不会把「没生效」误判成「生效」。
    static let matchThreshold: CLLocationDistance = 80

    /// 校验结论。
    enum Status: Equatable {

        /// 还没校验过（没开启虚拟定位时就是这一档）。
        case idle

        /// 正在等系统给出新位置。
        case verifying

        /// 已生效，附上确认时间。
        case effective(verifiedAt: Date)

        /// 没生效。
        case ineffective(reason: Reason)

        enum Reason: Equatable {
            /// 读不到本机定位：定位服务总开关关着，或者本 App 没有定位权限。
            case locationUnavailable
            /// 读得到位置，但仍然是真实位置——改写没走上（或系统还没重新解算）。
            case stillRealLocation
        }
    }

    @Published private(set) var status: Status = .idle

    private var task: Task<Void, Never>?

    // MARK: - 判定

    /// 纯判定：回读坐标与目标点算不算同一个地方。
    static func isEffective(
        probe: CLLocationCoordinate2D,
        target: CLLocationCoordinate2D,
        threshold: CLLocationDistance = SpoofEffectVerifier.matchThreshold
    ) -> Bool {
        let a = CLLocation(latitude: probe.latitude, longitude: probe.longitude)
        let b = CLLocation(latitude: target.latitude, longitude: target.longitude)
        return a.distance(from: b) <= threshold
    }

    /// 是否已经确认生效。
    var isEffective: Bool {
        if case .effective = status { return true }
        return false
    }

    var isVerifying: Bool { status == .verifying }

    // MARK: - 驱动

    /// 开始一轮校验。
    ///
    /// - Parameters:
    ///   - target: 目标点，必须与回读值**同源** —— 回读走 `CLLocationManager`，
    ///     它给的从来是 WGS-84（境内也不变，纠偏发生在地图侧），所以这里要传
    ///     选点的 `wgs84` 表示（`CoordinatePair.wgs84.coordinate`），
    ///     而不是地图体系的那一套。传错会整整差一个 GCJ 偏移（约 500 米），
    ///     校验就恒定报「未生效」（1.0.13 的现场）。
    ///   - provider: 回读用的定位封装。每轮都会 `forceFresh`，避免拿缓存里的旧位置。
    ///   - attempts: 最多探几次。用户去系统设置里关开定位服务、再切回来的时间
    ///     通常十几秒，所以默认给到 10 次 × 3 秒 ≈ 30 秒。
    @discardableResult
    func start(
        target: CLLocationCoordinate2D,
        provider: RealLocationProvider,
        attempts: Int = 10,
        interval: TimeInterval = 3
    ) -> Task<Void, Never> {
        run(target: target, attempts: attempts, interval: interval) {
            await Self.probeOnce(provider: provider)
        }
    }

    /// 一轮校验的驱动。
    ///
    /// 回读这一步做成闭包，是为了让单测能注入一个可控的"探针"——
    /// 真机上的 `CLLocationManager` 在测试环境里给不出确定的结果。
    @discardableResult
    func run(
        target: CLLocationCoordinate2D,
        attempts: Int = 10,
        interval: TimeInterval = 3,
        probe: @escaping () async -> Result<CLLocationCoordinate2D, RealLocationProvider.Failure>
    ) -> Task<Void, Never> {
        task?.cancel()
        status = .verifying

        RuntimeLogger.info("APP", "Verify", "开始校验虚拟定位是否生效", details: [
            "attempts": "\(attempts)",
            "interval": String(format: "%.1f", interval),
        ])

        let total = max(attempts, 1)
        let newTask = Task { [weak self] in
            for attempt in 1...total {
                if Task.isCancelled { return }

                let result = await probe()
                if Task.isCancelled { return }
                guard let self else { return }

                switch result {
                case .success(let coordinate):
                    if Self.isEffective(probe: coordinate, target: target) {
                        self.status = .effective(verifiedAt: Date())
                        RuntimeLogger.info("APP", "Verify", "虚拟定位已生效", details: [
                            "attempt": "\(attempt)",
                        ])
                        return
                    }
                    RuntimeLogger.debug("APP", "Verify", "回读到的是旧位置，继续等", details: [
                        "attempt": "\(attempt)",
                    ])

                case .failure(.denied), .failure(.restricted):
                    // 权限/总开关的问题，再等也不会自己好，直接给结论。
                    self.status = .ineffective(reason: .locationUnavailable)
                    RuntimeLogger.warn("APP", "Verify", "读不到本机定位，无法校验")
                    return

                case .failure(.unavailable):
                    // 暂时解算不出来（室内、刚进隧道），下一轮再试。
                    break
                }

                if attempt < total, interval > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }

            guard let self, !Task.isCancelled else { return }
            self.status = .ineffective(reason: .stillRealLocation)
            RuntimeLogger.warn("APP", "Verify", "校验超时，仍未读到目标位置")
        }

        task = newTask
        return newTask
    }

    /// 停止校验并回到未校验状态（关掉虚拟定位、或用户换了目标点时调用）。
    func reset() {
        task?.cancel()
        task = nil
        status = .idle
    }

    /// 把回调式的 `requestOnce` 包成 async。
    private static func probeOnce(
        provider: RealLocationProvider
    ) async -> Result<CLLocationCoordinate2D, RealLocationProvider.Failure> {
        await withCheckedContinuation { continuation in
            provider.requestOnce(forceFresh: true) { result in
                continuation.resume(returning: result)
            }
        }
    }
}

// MARK: - 展示

extension SpoofEffectVerifier.Status {

    /// 状态胶囊上的文字。未开启虚拟定位时不显示（由调用方判断 `idle`）。
    var pillText: String {
        switch self {
        case .idle:
            return AppLocalization.string("未验证")
        case .verifying:
            return AppLocalization.string("验证中")
        case .effective:
            return AppLocalization.string("已生效")
        case .ineffective:
            return AppLocalization.string("未生效")
        }
    }

    var pillIcon: String {
        switch self {
        case .idle: return "questionmark.circle"
        case .verifying: return "arrow.triangle.2.circlepath"
        case .effective: return "checkmark.seal.fill"
        case .ineffective: return "exclamationmark.triangle.fill"
        }
    }

    var pillColor: Color {
        switch self {
        case .idle: return .secondary
        case .verifying: return .blue
        case .effective: return .green
        case .ineffective: return .orange
        }
    }

    /// 给用户看的完整说明（banner 用）。
    var explanation: String {
        switch self {
        case .idle:
            return AppLocalization.string("尚未校验虚拟定位是否生效")
        case .verifying:
            return AppLocalization.string("正在校验虚拟定位是否生效，请稍候")
        case .effective:
            return AppLocalization.string("虚拟定位已生效，系统当前的位置就是选点位置")
        case .ineffective(.locationUnavailable):
            return AppLocalization.string("读不到本机定位：请确认系统「定位服务」和本 App 的定位权限都已打开")
        case .ineffective(.stillRealLocation):
            return AppLocalization.string(
                "还没生效：请到「设置 → 隐私与安全性 → 定位服务」关一下再打开，然后点「重新验证」"
            )
        }
    }
}
