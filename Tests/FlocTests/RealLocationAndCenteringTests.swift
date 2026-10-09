import XCTest
import CoreLocation
@testable import Floc

/// 「实时位置」这条链路上的两处计算：回读坐标怎么解释、居中给谁让位。
///
/// 用户的两条反馈各对应一条：
///
///   · 「点了实时位置后位置还是有偏差」→ `CLLocationManager` 回的是 WGS-84，
///     1.0.13 把它当成 GCJ-02 用，等于又叠了一次 500 米偏移；
///   · 「准心不在中间」→ 地图按**屏幕几何中心**居中，而底部卡片挡住了下面
///     一大块，目标点被压向卡片。
///
/// 这两件事都没有可访问性接口可断言（蓝点不在可访问性树里），所以把计算
/// 抽成纯函数、在这里钉死 —— 真机上偏 500 米与偏 40 米都看不出来是哪一个
/// 环节错的，只有把式子锁住才能下次不再错。
///
/// 整类标 `@MainActor`：被验的三个静态方法（`RealLocationProvider.pair`、
/// `SpoofEffectVerifier.isEffective`、`MapViewBridge.visibleCenter`）所在类型
/// 都是 `@MainActor` 隔离的，静态方法跟着隔离 —— 同步的 nonisolated 测试方法
/// 调不了它们。XCTest 支持在主 actor 上跑用例，与 `SpoofEffectVerifierTests`
/// 的写法一致。
@MainActor
final class RealLocationAndCenteringTests: XCTestCase {

    // MARK: - 回读坐标按 WGS-84 解释

    /// 设备回读到的坐标要**原样**写进 `wgs84` 那一半，另半边由换算补出来。
    func testDeviceLocationIsInterpretedAsWGS84() {
        let wgs = CoordinateConverter.tiananmenWGS84
        let pair = RealLocationProvider.pair(
            fromDeviceLocation: CLLocationCoordinate2D(
                latitude: wgs.latitude,
                longitude: wgs.longitude
            )
        )

        XCTAssertEqual(pair.wgs84.latitude, wgs.latitude, accuracy: 1e-9)
        XCTAssertEqual(pair.wgs84.longitude, wgs.longitude, accuracy: 1e-9)

        // 境内要真的把 GCJ-02 算出来 —— 漏了这一步就是那 500 米。
        XCTAssertEqual(pair.gcj02.latitude, CoordinateConverter.tiananmenGCJ02.latitude,
                       accuracy: 1e-5)
        XCTAssertEqual(pair.gcj02.longitude, CoordinateConverter.tiananmenGCJ02.longitude,
                       accuracy: 1e-5)
    }

    /// 写错方向的现场（1.0.13）：把回读值当 GCJ-02 用，居中坐标落在几百米外。
    ///
    /// 这条是**回归锁**：它不检查实现，只检查「两种解释确实差着几百米」这个
    /// 事实 —— 哪天有人又把解释方向改回去，上面那条用例会红，而这条告诉他
    /// 代价有多大。
    func testWrongInterpretationWouldMissByHundredsOfMeters() {
        let wgs = CoordinateConverter.tiananmenWGS84
        let coordinate = CLLocationCoordinate2D(latitude: wgs.latitude, longitude: wgs.longitude)

        let correct = RealLocationProvider.pair(fromDeviceLocation: coordinate)
            .coordinate(for: .gcj02)
        let wrong = CoordinateConverter.CoordinatePair(
            gcj02Latitude: wgs.latitude,
            gcj02Longitude: wgs.longitude
        )
        .coordinate(for: .gcj02)

        let distance = CLLocation(latitude: correct.latitude, longitude: correct.longitude)
            .distance(from: CLLocation(latitude: wrong.latitude, longitude: wrong.longitude))

        XCTAssertGreaterThan(distance, 300, "两种解释应当差几百米（境内 GCJ 偏移量级）")
        XCTAssertLessThan(distance, 800, "偏移量级不对，换算可能被改坏了")
    }

    /// 生效校验的目标点必须与回读值同源（都取 WGS-84）。
    ///
    /// 1.0.13 取的是地图体系的 GCJ-02，跟回读值差 500 米、而阈值只有 80 米，
    /// 于是校验会**恒定**报「未生效」。
    func testVerifierTargetSharesCoordinateSystemWithProbe() {
        let coordinate = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
        let pair = RealLocationProvider.pair(fromDeviceLocation: coordinate)

        XCTAssertTrue(
            SpoofEffectVerifier.isEffective(probe: coordinate, target: pair.wgs84.coordinate),
            "回读值就是目标点本身，应当判为已生效"
        )
        XCTAssertFalse(
            SpoofEffectVerifier.isEffective(probe: coordinate, target: pair.gcj02.coordinate),
            "拿地图体系那一套当目标会恒定判未生效（500 米 ≫ 80 米阈值）"
        )
    }

    // MARK: - 居中给底部卡片让位

    /// 目标点要落在「卡片上方那块可见区」的正中：地图中心得往南挪卡片高度的一半。
    func testVisibleCenterLeavesRoomForBottomCard() {
        let target = CLLocationCoordinate2D(latitude: 39.908722, longitude: 116.397499)
        let spanMeters: Double = 200      // 一屏 200 米
        let mapHeight: CGFloat = 800      // 地图高 800pt
        let bottomInset: CGFloat = 300    // 卡片挡住 300pt

        let center = MapViewBridge.visibleCenter(
            for: target,
            spanMeters: spanMeters,
            bottomInset: bottomInset,
            mapHeight: mapHeight
        )

        // 200 米 / 800pt = 0.25 米每点；让一半 = 150pt = 37.5 米。
        let meters = CLLocation(latitude: center.latitude, longitude: center.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))

        XCTAssertEqual(meters, 37.5, accuracy: 0.5,
                       "地图中心没有按卡片高度的一半往南挪")
        XCTAssertLessThan(center.latitude, target.latitude, "应当是往南（纬度变小）挪")
        XCTAssertEqual(center.longitude, target.longitude, accuracy: 1e-12, "经度不该动")
    }

    /// 卡片挡住 0 点（或地图还没量出高度）时原样返回 —— 不要凭空偏移。
    func testVisibleCenterIsIdentityWithoutObstruction() {
        let target = CLLocationCoordinate2D(latitude: 31.230416, longitude: 121.473701)

        for (inset, height) in [(CGFloat(0), CGFloat(800)), (CGFloat(300), CGFloat(0))] {
            let center = MapViewBridge.visibleCenter(
                for: target,
                spanMeters: 200,
                bottomInset: inset,
                mapHeight: height
            )
            XCTAssertEqual(center.latitude, target.latitude, accuracy: 1e-12)
            XCTAssertEqual(center.longitude, target.longitude, accuracy: 1e-12)
        }
    }

    /// 让位量随缩放级别变化：视野越大，同样多的点对应越多的米。
    func testVisibleCenterScalesWithViewport() {
        let target = CLLocationCoordinate2D(latitude: 39.908722, longitude: 116.397499)

        func shift(spanMeters: Double) -> CLLocationDistance {
            let center = MapViewBridge.visibleCenter(
                for: target,
                spanMeters: spanMeters,
                bottomInset: 300,
                mapHeight: 800
            )
            return CLLocation(latitude: center.latitude, longitude: center.longitude)
                .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        }

        XCTAssertEqual(shift(spanMeters: 400), shift(spanMeters: 200) * 2, accuracy: 1,
                       "米数应当与一屏多少米成正比")
    }
}
