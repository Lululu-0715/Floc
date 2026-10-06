import Foundation

/// 虚拟定位的开关状态机。
///
/// 开源项目里把「开关」「地图选点」「后台恢复」几处状态散落在视图中，
/// 这里收敛成一个独立状态机，方便测试也避免界面之间不同步。
@MainActor
final class MapLocationState: ObservableObject {

    /// 虚拟定位的开关。
    @Published private(set) var isEnabled = false

    /// 当前选中的位置（双坐标表示）。
    @Published private(set) var selection: CoordinateConverter.CoordinatePair?

    /// 当前选点对应的地名，用于界面展示。可能为空（还没反查出来）。
    @Published var displayName: String = ""

    /// 是否正在执行启停操作，用于禁用按钮防止连点。
    @Published private(set) var isBusy = false

    /// 当前地图使用的坐标体系，由 MapKit 探测得出。
    @Published var mapCoordinateSystem: CoordinateConverter.MapCoordinateSystem = .gcj02

    /// 精度（米），写进 WLOC 响应。
    @Published var accuracy: Int = 25

    /// 是否开启运动状态模拟。
    @Published var motionSimulationEnabled: Bool = false

    /// 上次选点时的地图缩放级别（米），用于恢复现场。
    @Published var viewportMeters: Double = 1500

    // MARK: - 选点

    /// 更新选中位置。会同时记录 WGS-84 与 GCJ-02 两套坐标。
    func select(_ pair: CoordinateConverter.CoordinatePair, name: String = "") {
        selection = pair
        displayName = name
        RuntimeLogger.debug("APP", "MapState", "选点已更新", details: [
            "wgs84": "\(pair.wgs84.latitude),\(pair.wgs84.longitude)",
        ])
    }

    /// 直接用 WGS-84 坐标选点。
    func select(wgs84Latitude: Double, wgs84Longitude: Double, name: String = "") {
        select(
            CoordinateConverter.CoordinatePair(
                wgs84Latitude: wgs84Latitude,
                wgs84Longitude: wgs84Longitude
            ),
            name: name
        )
    }

    /// 直接用 GCJ-02 坐标选点（例如用户在国内地图上点击）。
    func select(gcj02Latitude: Double, gcj02Longitude: Double, name: String = "") {
        select(
            CoordinateConverter.CoordinatePair(
                gcj02Latitude: gcj02Latitude,
                gcj02Longitude: gcj02Longitude
            ),
            name: name
        )
    }

    // MARK: - 开关

    /// 打开虚拟定位。返回是否成功。
    @discardableResult
    func enable() -> Bool {
        guard selection != nil else {
            RuntimeLogger.warn("APP", "MapState", "未选点即尝试开启")
            return false
        }
        isEnabled = true
        RuntimeLogger.info("APP", "MapState", "虚拟定位已开启")
        return true
    }

    /// 关闭虚拟定位。
    func disable() {
        isEnabled = false
        RuntimeLogger.info("APP", "MapState", "虚拟定位已关闭")
    }

    /// 标记为执行中。用 defer 确保异常路径也能复位。
    func withBusy<T>(_ operation: () throws -> T) rethrows -> T {
        isBusy = true
        defer { isBusy = false }
        return try operation()
    }

    /// 异步版本的忙碌包装。
    func withBusyAsync<T>(_ operation: () async throws -> T) async rethrows -> T {
        isBusy = true
        defer { isBusy = false }
        return try await operation()
    }

    // MARK: - 持久化

    private enum Key {
        static let enabled = "spoofEnabled"
        static let accuracy = "spoofAccuracy"
        static let motion = "spoofMotionSimulation"
        static let viewport = "mapViewportMeters"
        static let lastCoordinate = "lastSelectedCoordinate"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        accuracy = defaults.object(forKey: Key.accuracy) as? Int ?? 25
        motionSimulationEnabled = defaults.bool(forKey: Key.motion)
        let storedViewport = defaults.double(forKey: Key.viewport)
        viewportMeters = storedViewport > 0 ? storedViewport : 1500
        selection = Self.loadCoordinate(from: defaults, key: Key.lastCoordinate)
        // 注意：不恢复 isEnabled。重启后代理状态已失效，必须让用户重新开启，
        // 否则界面会显示「已开启」但实际定位并未被改写。
        isEnabled = false
    }

    /// 把当前选点和设置写回存储。
    func persist() {
        if let selection, let data = try? JSONEncoder().encode(selection) {
            defaults.set(data, forKey: Key.lastCoordinate)
        }
        defaults.set(accuracy, forKey: Key.accuracy)
        defaults.set(motionSimulationEnabled, forKey: Key.motion)
        defaults.set(viewportMeters, forKey: Key.viewport)
    }

    private static func loadCoordinate(from defaults: UserDefaults, key: String) -> CoordinateConverter.CoordinatePair? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CoordinateConverter.CoordinatePair.self, from: data)
    }
}
