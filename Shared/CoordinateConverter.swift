import CoreLocation
import Foundation

/// GCJ-02（火星坐标）与 WGS-84 之间的双向转换。
///
/// 背景：MapKit 没有公开 API 暴露当前使用的坐标参考系。在国内地图数据源下
/// 它返回 GCJ-02，在境外返回 WGS-84。而 WLOC 写入必须使用 WGS-84。
/// 因此实现上采取「双坐标并存」策略：每次确定一个位置时就同时算出两套坐标
/// 一起存下来，使用时按当前地图体系取对应字段，避免反复转换累积误差。
enum CoordinateConverter {

    // Krasovsky 1940 椭球参数
    private static let semiMajorAxis = 6378245.0
    private static let eccentricitySquared = 0.00669342162296594323

    /// 坐标参考系。
    enum MapCoordinateSystem: String, Codable, CaseIterable {
        case wgs84 = "WGS-84"
        case gcj02 = "GCJ-02"

        var diagnosticName: String {
            switch self {
            case .wgs84: return AppLocalization.string("国际标准 (WGS-84)")
            case .gcj02: return AppLocalization.string("国内标准 (GCJ-02)")
            }
        }
    }

    // MARK: - 转换核心

    /// 粗略判断是否在中国境外。境外坐标不需要做偏移。
    /// 边界比实际国境线略宽松，避免在边境地区误判。
    static func isOutOfChina(latitude: Double, longitude: Double) -> Bool {
        if longitude < 72.004 || longitude > 137.8347 {
            return true
        }
        if latitude < 0.8293 || latitude > 55.8271 {
            return true
        }
        return false
    }

    private static func transformLatitude(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLongitude(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }

    /// WGS-84 → GCJ-02。境外坐标原样返回。
    static func wgs84ToGCJ02(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        guard !isOutOfChina(latitude: latitude, longitude: longitude) else {
            return (latitude, longitude)
        }

        var deltaLat = transformLatitude(longitude - 105.0, latitude - 35.0)
        var deltaLon = transformLongitude(longitude - 105.0, latitude - 35.0)

        let radLat = latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - eccentricitySquared * magic * magic
        let sqrtMagic = sqrt(magic)

        deltaLat = (deltaLat * 180.0) / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * sqrtMagic) * .pi)
        deltaLon = (deltaLon * 180.0) / (semiMajorAxis / sqrtMagic * cos(radLat) * .pi)

        return (latitude + deltaLat, longitude + deltaLon)
    }

    /// GCJ-02 → WGS-84。采用迭代逼近，三次迭代即可收敛到厘米级。
    static func gcj02ToWGS84(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        guard !isOutOfChina(latitude: latitude, longitude: longitude) else {
            return (latitude, longitude)
        }

        var currentLat = latitude
        var currentLon = longitude

        for _ in 0..<3 {
            let forward = wgs84ToGCJ02(latitude: currentLat, longitude: currentLon)
            let errorLat = forward.latitude - latitude
            let errorLon = forward.longitude - longitude
            if abs(errorLat) < 1e-9 && abs(errorLon) < 1e-9 {
                break
            }
            currentLat -= errorLat
            currentLon -= errorLon
        }
        return (currentLat, currentLon)
    }

    // MARK: - 坐标对

    /// 一个位置的 WGS-84 与 GCJ-02 双表示。
    struct CoordinatePair: Codable, Equatable {
        /// 转换算法版本。将来算法调整时用它识别旧数据并重算。
        static let currentConversionVersion = 1

        struct Value: Codable, Equatable {
            let latitude: Double
            let longitude: Double

            var coordinate: CLLocationCoordinate2D {
                CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
        }

        let wgs84: Value
        let gcj02: Value
        let conversionVersion: Int

        init(wgs84: Value, gcj02: Value, conversionVersion: Int = CoordinatePair.currentConversionVersion) {
            self.wgs84 = wgs84
            self.gcj02 = gcj02
            self.conversionVersion = conversionVersion
        }

        /// 由已知 WGS-84 坐标构造坐标对。
        init(wgs84Latitude: Double, wgs84Longitude: Double) {
            let converted = CoordinateConverter.wgs84ToGCJ02(
                latitude: wgs84Latitude,
                longitude: wgs84Longitude
            )
            self.init(
                wgs84: Value(latitude: wgs84Latitude, longitude: wgs84Longitude),
                gcj02: Value(latitude: converted.latitude, longitude: converted.longitude)
            )
        }

        /// 由已知 GCJ-02 坐标构造坐标对（例如用户在国内地图上点选）。
        init(gcj02Latitude: Double, gcj02Longitude: Double) {
            let converted = CoordinateConverter.gcj02ToWGS84(
                latitude: gcj02Latitude,
                longitude: gcj02Longitude
            )
            self.init(
                wgs84: Value(latitude: converted.latitude, longitude: converted.longitude),
                gcj02: Value(latitude: gcj02Latitude, longitude: gcj02Longitude)
            )
        }

        /// 按指定地图体系取坐标。
        func coordinate(for system: MapCoordinateSystem) -> CLLocationCoordinate2D {
            switch system {
            case .wgs84: return wgs84.coordinate
            case .gcj02: return gcj02.coordinate
            }
        }

        /// 判断给定坐标是否与本文的 WGS-84 表示一致。
        func matchesWGS84(latitude: Double, longitude: Double, tolerance: Double = 0.0001) -> Bool {
            abs(wgs84.latitude - latitude) <= tolerance
                && abs(wgs84.longitude - longitude) <= tolerance
        }

        /// 判断给定坐标是否与本文的 GCJ-02 表示一致。
        func matchesGCJ02(latitude: Double, longitude: Double, tolerance: Double = 0.0001) -> Bool {
            abs(gcj02.latitude - latitude) <= tolerance
                && abs(gcj02.longitude - longitude) <= tolerance
        }

        /// 与另一个坐标对的距离（以 WGS-84 为准，单位米）。
        func distance(to other: CoordinatePair) -> CLLocationDistance {
            CLLocation(latitude: wgs84.latitude, longitude: wgs84.longitude)
                .distance(from: CLLocation(latitude: other.wgs84.latitude, longitude: other.wgs84.longitude))
        }
    }

    // MARK: - 坐标体系推断

    /// 用于推断 MapKit 当前坐标体系的固定锚点（北京天安门）。
    /// 逻辑：分别按两套坐标去反查地点名，返回结果与预期一致的那个即为当前体系。
    struct SystemProbe {
        let inferredSystem: MapCoordinateSystem?
        let distanceToWGS84: CLLocationDistance
        let distanceToGCJ02: CLLocationDistance

        var inferredName: String {
            inferredSystem?.diagnosticName ?? AppLocalization.string("无法判定")
        }

        /// 两套候选之间偏移过大时说明探测结果不可信。
        var isConclusive: Bool {
            inferredSystem != nil
                && abs(distanceToWGS84 - distanceToGCJ02) > 50
        }
    }

    /// 给定 MapKit 返回的坐标，判断它更接近哪个体系。
    ///
    /// 做法：取一个已知 WGS-84 数值的锚点（北京天安门），分别算出它在两套体系
    /// 下的数值，再和地图给出的坐标比距离——更接近哪一套，地图画布就是哪一套。
    /// 两套候选相差约 300-700 米，足以区分。
    ///
    /// 注意比较的是「锚点的 WGS-84 数值」与「锚点的 GCJ-02 数值」两个不同的位置。
    /// 早先的实现把同一个坐标分别塞进两个 CoordinatePair，再取各自的 wgs84/gcj02
    /// 字段去比，而那两个字段恒等于入参本身，于是两个距离永远相等、恒定返回 nil。
    static func inferSystem(
        mapCoordinate: CLLocationCoordinate2D,
        referenceWGS84: CLLocationCoordinate2D
    ) -> SystemProbe {
        let referenceAsGCJ02 = wgs84ToGCJ02(
            latitude: referenceWGS84.latitude,
            longitude: referenceWGS84.longitude
        )

        let anchorAsWGS84 = CLLocation(
            latitude: referenceWGS84.latitude,
            longitude: referenceWGS84.longitude
        )
        let anchorAsGCJ02 = CLLocation(
            latitude: referenceAsGCJ02.latitude,
            longitude: referenceAsGCJ02.longitude
        )
        let probed = CLLocation(
            latitude: mapCoordinate.latitude,
            longitude: mapCoordinate.longitude
        )

        let distanceToWGS84 = probed.distance(from: anchorAsWGS84)
        let distanceToGCJ02 = probed.distance(from: anchorAsGCJ02)

        // 距离更小的那套解释更可能是地图实际使用的体系。
        let inferred: MapCoordinateSystem?
        if distanceToWGS84 < distanceToGCJ02 {
            inferred = .wgs84
        } else if distanceToGCJ02 < distanceToWGS84 {
            inferred = .gcj02
        } else {
            inferred = nil
        }

        return SystemProbe(
            inferredSystem: inferred,
            distanceToWGS84: distanceToWGS84,
            distanceToGCJ02: distanceToGCJ02
        )
    }
}
