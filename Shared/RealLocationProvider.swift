import Combine
import CoreLocation
import Foundation

/// 读取设备当前真实位置的轻量封装。
///
/// 只服务于地图页的「实时位置」按钮：点一次、取一次、立刻停。
/// 刻意不做持续更新与后台采集——本应用的核心是把位置改掉，
/// 长期订阅真实位置既没有用处，也会平白多要一份定位权限的使用记录。
///
/// 注意：这里拿到的是 WGS-84 原始坐标，展示到地图上之前必须按当前
/// 地图体系换算，否则国内会偏出几百米。
@MainActor
final class RealLocationProvider: NSObject, ObservableObject {

    /// 定位失败的原因。
    enum Failure: LocalizedError {
        case denied
        case restricted
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return AppLocalization.string("定位权限未开启，请在系统设置中允许访问位置。")
            case .restricted:
                return AppLocalization.string("当前设备限制了定位功能，无法获取真实位置。")
            case .unavailable(let reason):
                return AppLocalization.string("获取真实位置失败：%@", reason)
            }
        }
    }

    @Published private(set) var isLocating = false

    private let manager = CLLocationManager()
    /// 本次请求的回调。拿到结果或失败后立即清空，保证只回调一次。
    private var pendingCompletion: ((Result<CLLocationCoordinate2D, Failure>) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// 请求一次当前位置。
    ///
    /// 未授权时会先弹系统授权框，用户同意后自动继续；拒绝则直接回调失败。
    func requestOnce(completion: @escaping (Result<CLLocationCoordinate2D, Failure>) -> Void) {
        // 上一条请求还没结束就再来一次：直接放弃旧的，以最新一次为准。
        pendingCompletion = completion
        isLocating = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied:
            finish(.failure(.denied))
        case .restricted:
            finish(.failure(.restricted))
        @unknown default:
            finish(.failure(.denied))
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Failure>) {
        isLocating = false
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }
}

extension RealLocationProvider: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.finish(.success(coordinate))
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        // kCLErrorLocationUnknown 是「暂时定位不到」，常见于刚进入室内，
        // 多试一次通常就有结果，所以这里直接提示重试而不是报权限问题。
        let reason = (error as NSError).localizedDescription
        Task { @MainActor in
            self.finish(.failure(.unavailable(reason)))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.handleAuthorizationChange()
        }
    }

    /// 用户响应授权后继续这次定位请求。
    ///
    /// 只有用户正等着结果时才继续，避免 App 启动阶段一次无关的授权状态
    /// 变化白跑一次定位——那会平白留下一条定位使用记录。
    private func handleAuthorizationChange() {
        guard pendingCompletion != nil else { return }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied:
            finish(.failure(.denied))
        case .restricted:
            finish(.failure(.restricted))
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
}
