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

    // MARK: - 已知锚点

    /// 天安门的 **GCJ-02** 坐标。
    ///
    /// 出处：高德地理编码的官方示例（「地标性建筑举例：天安门 → 116.397499,
    /// 39.908722」），百度百科「逆地理信息」词条原文引用的就是这一对数字。
    ///
    /// ⚠️ **这一对数字不是 WGS-84。** 它太像「天安门的经纬度」这条常识，
    /// 极易被直接当成参考值使用 —— 1.0.10 及以前 `probeCoordinateSystem()`
    /// 就是把它当 `referenceWGS84` 传进去的（漏了文档里写的「反算出 WGS-84」
    /// 那一步），于是境内设备的地图体系被**恒定判成 WGS-84**：选点写进定位
    /// 服务的坐标整整差一个 GCJ 偏移（数百米），用户的原话是
    /// 「地图选点跟定位出来的位置有偏差，而且不小」。
    static let tiananmenGCJ02 = (latitude: 39.908722, longitude: 116.397499)

    /// 同一个地点的 **WGS-84** 坐标。
    ///
    /// 不写死数字，而用本文件的换算现算：写死的话，将来调整换算算法
    /// （或椭球参数）时锚点不会跟着变，两套数值就不再指向同一个地点。
    static var tiananmenWGS84: (latitude: Double, longitude: Double) {
        gcj02ToWGS84(
            latitude: tiananmenGCJ02.latitude,
            longitude: tiananmenGCJ02.longitude
        )
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

    // MARK: - 地图坐标体系的判据

    /// 给定「从地图上取到的坐标」，判断它应当按哪套体系解释。
    ///
    /// 只有一条硬事实：**中国大陆的地图数据是 GCJ-02**（Apple 中国的底图与
    /// POI 都来自高德 —— 本工程拦截的主机名单里那两台 `bluedot.is.autonavi.com`
    /// 就是同一个来源），**境外是 WGS-84**。而且本文件的换算只在境内生效：
    /// 境外的两套数值完全相等。
    ///
    /// 于是「按点落在哪个区域分流」既不依赖任何探测，也不可能误判，
    /// 是这个问题上唯一站得住的判据。地图点选的解释（`handleMapTap`）、
    /// 搜索结果的分流（`runSearch`）都走这里。
    static func mapSystem(latitude: Double, longitude: Double) -> MapCoordinateSystem {
        isOutOfChina(latitude: latitude, longitude: longitude) ? .wgs84 : .gcj02
    }

    // MARK: - 坐标体系推断

    /// 一次坐标系探测的结果。
    struct SystemProbe {
        let inferredSystem: MapCoordinateSystem?
        let distanceToWGS84: CLLocationDistance
        let distanceToGCJ02: CLLocationDistance

        /// 两套候选落点之间的距离（境内约 300~700 米）。境外为 0。
        let separation: CLLocationDistance

        /// 按区域判据，这个点**应该**属于哪套体系。
        let expectedSystem: MapCoordinateSystem

        /// 原始判定与区域判据矛盾（境内点被判成 WGS-84）。
        ///
        /// 这是 1.0.10 那个偏移 bug 的现场特征，值得单独记一条日志：
        /// 它意味着探测本身出了问题，而不是地图换了体系。
        let contradictsRegion: Bool

        var inferredName: String {
            inferredSystem?.diagnosticName ?? AppLocalization.string("无法判定")
        }

        /// 判定是否可信：必须判出了体系，而且**明显地**偏向其中一套。
        ///
        /// 光看「两个距离不相等」是不够的（几乎任何坐标都满足）：锚点的两套
        /// 候选只差几百米，地图上随便一个点都会略微偏向某一侧。要求偏向幅度
        /// 超过候选间距的四成，才算真的对上了锚点。
        var isConclusive: Bool {
            guard inferredSystem != nil else { return false }
            let margin = abs(distanceToWGS84 - distanceToGCJ02)
            return margin > max(50, separation * 0.4)
        }
    }

    /// 给定 MapKit 返回的坐标，判断它更接近哪个体系。
    ///
    /// 做法：取锚点（天安门）的 WGS-84 数值，以及它换算出来的 GCJ-02 数值，
    /// 两个落点相距 500 米以上；地图返回的坐标更接近哪一个，就说明地图画布
    /// 用的是哪一套。
    ///
    /// ⚠️ **锚点必须传「真 WGS-84」数值**，两个候选才拉得开（见
    /// `tiananmenWGS84`）。把高德那对 GCJ 数字当成 WGS-84 传进来，判定会
    /// 恒定反着走 —— 1.0.10 就是这么错的。
    ///
    /// ## 这个函数只做「确认」，不做「翻转」
    ///
    /// 探测要成立，两套候选必须分得开；而换算在境外是恒等变换，境外锚点的
    /// 两个候选**完全重合**（`separation == 0`），什么也判不出来。也就是说：
    /// 能测出结果的场合必定在境内，而境内在哪套体系上是确定的（GCJ-02）。
    /// 所以「判成 WGS-84」永远意味着探错了，这里直接用区域判据
    /// （`mapSystem(latitude:longitude:)`）把它挡掉，`inferredSystem` 返回 nil。
    ///
    /// 决定坐标怎么解释的权力在 `mapSystem` 手上，这个函数只负责
    /// 「拿真实的搜索接口确认一次地图数据源没变」并留下日志。
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
        let separation = anchorAsWGS84.distance(from: anchorAsGCJ02)

        // 距离更小的那套解释更可能是地图实际使用的体系。
        var inferred: MapCoordinateSystem?
        if distanceToWGS84 < distanceToGCJ02 {
            inferred = .wgs84
        } else if distanceToGCJ02 < distanceToWGS84 {
            inferred = .gcj02
        }

        // 区域判据是硬约束：与它矛盾的判定一律作废。
        let expected = mapSystem(
            latitude: mapCoordinate.latitude,
            longitude: mapCoordinate.longitude
        )
        let contradictsRegion = inferred != nil && inferred != expected
        if contradictsRegion {
            inferred = nil
        }

        return SystemProbe(
            inferredSystem: inferred,
            distanceToWGS84: distanceToWGS84,
            distanceToGCJ02: distanceToGCJ02,
            separation: separation,
            expectedSystem: expected,
            contradictsRegion: contradictsRegion
        )
    }
}
