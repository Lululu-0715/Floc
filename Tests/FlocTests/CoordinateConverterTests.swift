import XCTest
import CoreLocation
@testable import Floc

/// 坐标系转换测试。
///
/// 断言用的是「已知参考点」：北京天安门、上海外滩等位置的 GCJ-02 与 WGS-84
/// 坐标是公开可查的，转换结果应当落在合理误差内。
final class CoordinateConverterTests: XCTestCase {

    // MARK: - 境外不转换

    func testOutOfChinaDetection() {
        // 中国境内
        XCTAssertFalse(
            CoordinateConverter.isOutOfChina(latitude: 39.908722, longitude: 116.397499),
            "北京应判定为境内"
        )
        XCTAssertFalse(
            CoordinateConverter.isOutOfChina(latitude: 22.281508, longitude: 114.174700),
            "香港应判定为境内"
        )

        // 境外
        XCTAssertTrue(
            CoordinateConverter.isOutOfChina(latitude: 35.6762, longitude: 139.6503),
            "东京应判定为境外"
        )
        XCTAssertTrue(
            CoordinateConverter.isOutOfChina(latitude: 40.7128, longitude: -74.0060),
            "纽约应判定为境外"
        )
    }

    func testOutOfChinaCoordinatesAreNotShifted() {
        // 东京坐标转换后应当完全不变
        let tokyo = (latitude: 35.6762, longitude: 139.6503)
        let converted = CoordinateConverter.wgs84ToGCJ02(
            latitude: tokyo.latitude,
            longitude: tokyo.longitude
        )

        XCTAssertEqual(converted.latitude, tokyo.latitude, accuracy: 1e-9)
        XCTAssertEqual(converted.longitude, tokyo.longitude, accuracy: 1e-9)
    }

    // MARK: - 正向转换

    func testWGS84ToGCJ02ShiftsInChina() {
        let beijing = (latitude: 39.907500, longitude: 116.391800)
        let converted = CoordinateConverter.wgs84ToGCJ02(
            latitude: beijing.latitude,
            longitude: beijing.longitude
        )

        // 境内必然产生偏移，幅度在数百米量级（约 0.001~0.01 度）
        let deltaLat = abs(converted.latitude - beijing.latitude)
        let deltaLon = abs(converted.longitude - beijing.longitude)

        XCTAssertGreaterThan(deltaLat, 0.0001, "纬度应有可见偏移")
        XCTAssertGreaterThan(deltaLon, 0.0001, "经度应有可见偏移")
        XCTAssertLessThan(deltaLat, 0.01, "纬度偏移不应超过 0.01 度")
        XCTAssertLessThan(deltaLon, 0.01, "经度偏移不应超过 0.01 度")
    }

    // MARK: - 往返一致性

    func testRoundTripRestoresOriginalCoordinate() {
        let samples = [
            (name: "北京", latitude: 39.908722, longitude: 116.397499),
            (name: "上海", latitude: 31.230416, longitude: 121.473701),
            (name: "深圳", latitude: 22.543099, longitude: 114.057868),
            (name: "乌鲁木齐", latitude: 43.825592, longitude: 87.616848),
            (name: "三亚", latitude: 18.252847, longitude: 109.511909),
        ]

        for sample in samples {
            let gcj = CoordinateConverter.wgs84ToGCJ02(
                latitude: sample.latitude,
                longitude: sample.longitude
            )
            let back = CoordinateConverter.gcj02ToWGS84(
                latitude: gcj.latitude,
                longitude: gcj.longitude
            )

            // 3 次迭代逼近，误差应远小于 1 米（约 1e-7 度）
            XCTAssertEqual(
                back.latitude, sample.latitude, accuracy: 1e-6,
                "\(sample.name) 纬度往返应还原"
            )
            XCTAssertEqual(
                back.longitude, sample.longitude, accuracy: 1e-6,
                "\(sample.name) 经度往返应还原"
            )
        }
    }

    func testRepeatedConversionDoesNotDrift() {
        // 反复正反转换 20 次，误差不应累积放大
        let original = (latitude: 31.230416, longitude: 121.473701)
        var current = original

        for _ in 0..<20 {
            let gcj = CoordinateConverter.wgs84ToGCJ02(
                latitude: current.latitude,
                longitude: current.longitude
            )
            current = CoordinateConverter.gcj02ToWGS84(
                latitude: gcj.latitude,
                longitude: gcj.longitude
            )
        }

        XCTAssertEqual(current.latitude, original.latitude, accuracy: 1e-5)
        XCTAssertEqual(current.longitude, original.longitude, accuracy: 1e-5)
    }

    // MARK: - CoordinatePair

    func testCoordinatePairStoresBothSystems() {
        let pair = CoordinateConverter.CoordinatePair(wgs84Latitude: 39.908722, wgs84Longitude: 116.397499)

        // 两套坐标都应存在且不同
        XCTAssertNotEqual(pair.wgs84.latitude, pair.gcj02.latitude, accuracy: 1e-9)
        XCTAssertNotEqual(pair.wgs84.longitude, pair.gcj02.longitude, accuracy: 1e-9)

        // 按体系取值应各自匹配
        XCTAssertTrue(pair.matchesWGS84(latitude: 39.908722, longitude: 116.397499))
        XCTAssertTrue(pair.matchesGCJ02(
            latitude: pair.gcj02.latitude,
            longitude: pair.gcj02.longitude
        ))
    }

    func testCoordinatePairFromGCJ02() {
        let pair = CoordinateConverter.CoordinatePair(gcj02Latitude: 39.915000, gcj02Longitude: 116.404000)

        XCTAssertTrue(pair.matchesGCJ02(latitude: 39.915000, longitude: 116.404000))
        // WGS-84 应当与 GCJ-02 不同
        XCTAssertFalse(pair.matchesWGS84(latitude: 39.915000, longitude: 116.404000))
    }

    func testCoordinatePairCoordinateForSystem() {
        let pair = CoordinateConverter.CoordinatePair(wgs84Latitude: 31.230416, wgs84Longitude: 121.473701)

        let wgs = pair.coordinate(for: .wgs84)
        let gcj = pair.coordinate(for: .gcj02)

        XCTAssertEqual(wgs.latitude, pair.wgs84.latitude, accuracy: 1e-12)
        XCTAssertEqual(gcj.latitude, pair.gcj02.latitude, accuracy: 1e-12)
        XCTAssertNotEqual(wgs.latitude, gcj.latitude, accuracy: 1e-9)
    }

    func testCoordinatePairCodable() throws {
        let pair = CoordinateConverter.CoordinatePair(wgs84Latitude: 22.543099, wgs84Longitude: 114.057868)

        let encoded = try JSONEncoder().encode(pair)
        let decoded = try JSONDecoder().decode(CoordinateConverter.CoordinatePair.self, from: encoded)

        XCTAssertEqual(decoded, pair, "编解码后应当完全相等")
    }

    // MARK: - 地图体系判据

    func testMapSystemUsesRegionOnly() {
        // 境内一律 GCJ-02（Apple 中国的底图与 POI 都来自高德）
        XCTAssertEqual(
            CoordinateConverter.mapSystem(latitude: 39.904714, longitude: 116.391315),
            .gcj02,
            "北京应按 GCJ-02 解释"
        )
        XCTAssertEqual(
            CoordinateConverter.mapSystem(latitude: 22.281508, longitude: 114.174700),
            .gcj02,
            "香港应按 GCJ-02 解释"
        )

        // 境外一律 WGS-84
        XCTAssertEqual(
            CoordinateConverter.mapSystem(latitude: 35.6762, longitude: 139.6503),
            .wgs84,
            "东京应按 WGS-84 解释"
        )
        XCTAssertEqual(
            CoordinateConverter.mapSystem(latitude: 40.7128, longitude: -74.0060),
            .wgs84,
            "纽约应按 WGS-84 解释"
        )
    }

    // MARK: - 锚点（1.0.10 偏移 bug 的回归锁）

    /// 锚点必须是「真 WGS-84」。
    ///
    /// 判据：`tiananmenGCJ02` 那对数字是**高德 GCJ-02** 的输出，把锚点正算回去
    /// 必须正好落在它上面。谁哪天图省事直接把那对数字写成锚点，这条断言立刻失败
    /// —— 那正是 1.0.10 之前的错误写法。
    func testTiananmenAnchorIsGenuineWGS84() {
        let anchor = CoordinateConverter.tiananmenWGS84
        let asGCJ = CoordinateConverter.wgs84ToGCJ02(
            latitude: anchor.latitude,
            longitude: anchor.longitude
        )

        XCTAssertEqual(asGCJ.latitude, CoordinateConverter.tiananmenGCJ02.latitude, accuracy: 1e-6)
        XCTAssertEqual(asGCJ.longitude, CoordinateConverter.tiananmenGCJ02.longitude, accuracy: 1e-6)

        // 两套数值必须明显不是同一个点，否则锚点就是把 GCJ 当成了 WGS。
        XCTAssertGreaterThan(
            abs(anchor.longitude - CoordinateConverter.tiananmenGCJ02.longitude),
            0.001,
            "锚点与「高德那对数字」不应重合（重合说明锚点写成了 GCJ）"
        )
    }

    // MARK: - 地图体系探测

    func testInferSystemAcceptsGCJ02Anchor() {
        let anchor = CoordinateConverter.tiananmenWGS84
        let probe = CoordinateConverter.inferSystem(
            mapCoordinate: CLLocationCoordinate2D(
                latitude: CoordinateConverter.tiananmenGCJ02.latitude,
                longitude: CoordinateConverter.tiananmenGCJ02.longitude
            ),
            referenceWGS84: CLLocationCoordinate2D(
                latitude: anchor.latitude,
                longitude: anchor.longitude
            )
        )

        XCTAssertEqual(probe.inferredSystem, .gcj02, "地图返回高德那套坐标时应判为 GCJ-02")
        XCTAssertTrue(probe.isConclusive)
        XCTAssertFalse(probe.contradictsRegion)
        XCTAssertEqual(probe.expectedSystem, .gcj02)
        XCTAssertGreaterThan(probe.separation, 300, "两套候选应相差数百米")
    }

    /// 1.0.10 的现场：把高德的 GCJ 数字当成锚点，境内设备会被判成 WGS-84。
    ///
    /// 现在这条判定会被区域判据挡掉（境内不可能是 WGS-84），`inferredSystem`
    /// 返回 nil —— 宁可「不判定」（保留默认的 GCJ-02），也不能让整机坐标
    /// 偏掉一个 GCJ 偏移。
    func testInferSystemRejectsWGS84VerdictInsideChina() {
        // 锚点错误地取成高德那对 GCJ 数字（1.0.10 的写法），地图返回的仍是 GCJ。
        let wrongAnchor = CLLocationCoordinate2D(
            latitude: CoordinateConverter.tiananmenGCJ02.latitude,
            longitude: CoordinateConverter.tiananmenGCJ02.longitude
        )
        let probe = CoordinateConverter.inferSystem(
            mapCoordinate: wrongAnchor,
            referenceWGS84: wrongAnchor
        )

        XCTAssertNotEqual(probe.inferredSystem, .wgs84, "境内点不许判成 WGS-84")
        XCTAssertNil(probe.inferredSystem)
        XCTAssertTrue(probe.contradictsRegion)
        XCTAssertFalse(probe.isConclusive)
    }

    /// 两个候选只差几百米时，随便一个点都会略偏向某一侧 —— 这种「勉强偏向」
    /// 不算判定：偏向幅度必须超过候选间距的四成。
    func testInferSystemInconclusiveWhenPointMatchesNeither() {
        let anchor = CoordinateConverter.tiananmenWGS84
        let asGCJ = CoordinateConverter.wgs84ToGCJ02(
            latitude: anchor.latitude,
            longitude: anchor.longitude
        )
        let probe = CoordinateConverter.inferSystem(
            mapCoordinate: CLLocationCoordinate2D(
                latitude: (anchor.latitude + asGCJ.latitude) / 2,
                longitude: (anchor.longitude + asGCJ.longitude) / 2
            ),
            referenceWGS84: CLLocationCoordinate2D(
                latitude: anchor.latitude,
                longitude: anchor.longitude
            )
        )

        XCTAssertFalse(probe.isConclusive, "落点居中的探测不该被采信")
    }

    /// 境外锚点的两套候选完全重合（换算在境外是恒等），探测什么也判不出来 ——
    /// 这也正是「探测无法用来发现 WGS-84 地图」的原因。
    func testInferSystemCannotDistinguishOutsideChina() {
        let tokyo = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
        let probe = CoordinateConverter.inferSystem(
            mapCoordinate: tokyo,
            referenceWGS84: tokyo
        )

        XCTAssertEqual(probe.separation, 0, accuracy: 0.01, "境外两套候选应重合")
        XCTAssertNil(probe.inferredSystem)
        XCTAssertFalse(probe.isConclusive)
    }

    func testDistanceBetweenPairs() {
        let a = CoordinateConverter.CoordinatePair(wgs84Latitude: 39.908722, wgs84Longitude: 116.397499)
        let b = CoordinateConverter.CoordinatePair(wgs84Latitude: 31.230416, wgs84Longitude: 121.473701)

        // 北京到上海直线距离约 1060 公里
        let distance = a.distance(to: b)
        XCTAssertGreaterThan(distance, 1_000_000, "应超过 1000 公里")
        XCTAssertLessThan(distance, 1_150_000, "应少于 1150 公里")
    }
}
