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

    /// 运动状态模拟：原地抖动的半径（米）。0 表示关闭。
    ///
    /// 开启后每次改写都会在半径内随机偏移坐标，让系统看到的是
    /// 「同一个位置附近的微小漂移」，而不是死钉在一个点上。
    @Published var motionDriftRadius: Int = 0

    /// 上次选点时的地图缩放级别（米），用于恢复现场。
    @Published var viewportMeters: Double = MapLocationState.defaultViewportMeters

    /// 默认视野（米）。
    ///
    /// 200 米大约是「一条街」的尺度：虚拟定位选点通常就是要精确到某个
    /// 楼或某个路口，进应用先给到这个精度，比默认给几公里再手动放大省事。
    /// 只用于**首次进入**的初始视野；「实时位置」不改缩放，保持用户当前比例。
    static let defaultViewportMeters: Double = 200

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
        static let motionDrift = "spoofMotionDriftRadius"
        static let viewport = "mapViewportMeters"
        static let lastCoordinate = "lastSelectedCoordinate"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        accuracy = defaults.object(forKey: Key.accuracy) as? Int ?? 25
        motionDriftRadius = MotionDriftOption.normalized(
            defaults.object(forKey: Key.motionDrift) as? Int ?? 0
        ).rawValue
        let storedViewport = defaults.double(forKey: Key.viewport)
        viewportMeters = storedViewport > 0 ? storedViewport : Self.defaultViewportMeters
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
        defaults.set(motionDriftRadius, forKey: Key.motionDrift)
        defaults.set(viewportMeters, forKey: Key.viewport)
    }

    private static func loadCoordinate(from defaults: UserDefaults, key: String) -> CoordinateConverter.CoordinatePair? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CoordinateConverter.CoordinatePair.self, from: data)
    }
}

/// 运动状态模拟的抖动半径档位。
///
/// 只提供三档而不是自由输入：半径越大，位置越"飘"，超出一定范围后
/// 依赖定位精度的应用反而会判定为信号异常。三档覆盖了常见场景，
/// 也避免用户填进一个把定位甩到几公里外的值。
enum MotionDriftOption: Int, CaseIterable, Identifiable {

    case off = 0
    case fiveMeters = 5
    case tenMeters = 10
    case twentyMeters = 20

    var id: Int { rawValue }

    /// 实际抖动半径（米）。关闭时为 0。
    var radiusMeters: Int { rawValue }

    var isEnabled: Bool { self != .off }

    var displayName: String {
        switch self {
        case .off: return AppLocalization.string("关闭")
        default: return AppLocalization.string("%d 米", rawValue)
        }
    }

    /// 把任意存储值收敛到受支持的档位，防止旧数据或脏数据带进非法半径。
    static func normalized(_ rawValue: Int) -> MotionDriftOption {
        MotionDriftOption(rawValue: rawValue) ?? .off
    }
}
