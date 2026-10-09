import Combine
import CoreLocation
import Foundation

/// 读取设备当前真实位置的轻量封装。
///
/// 只服务于地图页的「实时位置」按钮：点一次、取一次、立刻停。
/// 刻意不做持续更新与后台采集——本应用的核心是把位置改掉，
/// 长期订阅真实位置既没有用处，也会平白多要一份定位权限的使用记录。
///
/// **这里拿到的是 WGS-84 原始坐标**（GPS 原始值，境内也不会被换成 GCJ-02），
/// 展示到地图上之前必须按当前地图体系换算，否则国内会偏出几百米。
/// 换算成「双坐标」这一步统一走 `pair(fromDeviceLocation:)`，别在调用方各写一遍。
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

    /// 当前是否已经拿到定位权限。
    ///
    /// 用于「要不要主动发起一次定位」的判断：没授权就发请求会当场弹系统
    /// 授权框，冷启动时这样弹一下很突兀（用户还没做任何操作）。
    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// 缓存位置的有效期（秒）。超过这个年龄就重新定位一次。
    /// 取值理由见 `requestLocationOrUseCache`。
    private static let cacheValidity: TimeInterval = 60

    private let manager = CLLocationManager()
    /// 本次请求的回调。拿到结果或失败后立即清空，保证只回调一次。
    private var pendingCompletion: ((Result<CLLocationCoordinate2D, Failure>) -> Void)?
    /// 本次请求是否**绕开缓存**（见 `requestOnce(forceFresh:completion:)`）。
    private var pendingForceFresh = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// 请求一次当前位置。
    ///
    /// 未授权时会先弹系统授权框，用户同意后自动继续；拒绝则直接回调失败。
    ///
    /// - Parameter forceFresh: 为 true 时**跳过一分钟缓存**，强制向系统要一次
    ///   新解算的位置。用于「虚拟定位生效没有」这类校验：缓存里那份很可能
    ///   是改写生效**之前**的旧结果，拿它比对会得出错误的结论。
    ///   实时位置按钮（`goToRealLocation`）不要用它，那里的等待代价更显眼。
    func requestOnce(
        forceFresh: Bool = false,
        completion: @escaping (Result<CLLocationCoordinate2D, Failure>) -> Void
    ) {
        // 上一条请求还没结束就再来一次：直接放弃旧的，以最新一次为准。
        pendingCompletion = completion
        pendingForceFresh = forceFresh
        isLocating = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestLocationOrUseCache()
        case .denied:
            finish(.failure(.denied))
        case .restricted:
            finish(.failure(.restricted))
        @unknown default:
            finish(.failure(.denied))
        }
    }

    /// 有足够新的缓存就直接用，否则才真正去要一次定位。
    ///
    /// `requestLocation()` 要等 GPS 解出一次位置，室内、地下车库、刚进隧道
    /// 常常要 5–10 秒，用户看到的就是「点了半天没反应」。系统本来就维护着
    /// 一份最近位置，**一分钟内的直接采用**：这个按钮要回答的是「我在哪」，
    /// 一分钟内的漂移对肉眼没有意义，而等待的代价是实打实的。
    ///
    /// 超过一分钟（或从来没有过）才回退到现取，保证结果不会离谱。
    private func requestLocationOrUseCache() {
        // 校验路径明确要求「现取」，缓存再新也不能用：那一份多半正是改写
        // 生效之前的旧坐标（用户点「开启虚拟定位」前刚看过自己的真实位置）。
        if !pendingForceFresh,
           let cached = manager.location,
           abs(cached.timestamp.timeIntervalSinceNow) < Self.cacheValidity {
            RuntimeLogger.debug("APP", "Location", "实时位置命中缓存", details: [
                "ageSeconds": String(format: "%.1f", -cached.timestamp.timeIntervalSinceNow),
            ])
            finish(.success(cached.coordinate))
            return
        }
        manager.requestLocation()
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Failure>) {
        isLocating = false
        pendingForceFresh = false
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }

    // MARK: - 坐标体系

    /// 把回读到的坐标装成「双坐标」对。
    ///
    /// **只按 WGS-84 解释**：`CLLocationManager` 给的从来是 GPS 原始值
    /// （境内也不变 —— 被纠偏的是地图，见 `MapHomeView.goToRealLocation` 的
    /// 说明与 `CoordinateConverter.mapSystem` 的注释），所以这里是
    /// `CoordinatePair(wgs84…)`，**不是**按地区分流那一条。
    ///
    /// 抽成静态函数是为了能单测：这是「实时位置跳转偏 500 米」与
    /// 「生效校验恒判未生效」两个 bug 的共同根因，值得钉一条回归。
    static func pair(
        fromDeviceLocation coordinate: CLLocationCoordinate2D
    ) -> CoordinateConverter.CoordinatePair {
        CoordinateConverter.CoordinatePair(
            wgs84Latitude: coordinate.latitude,
            wgs84Longitude: coordinate.longitude
        )
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
            requestLocationOrUseCache()
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
