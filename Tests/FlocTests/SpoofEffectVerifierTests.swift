import CoreLocation
import XCTest
@testable import Floc

/// 虚拟定位生效校验的判定逻辑。
///
/// 这一套的意义：改写的链路里任何一环没配上（证书没信任、Wi-Fi 代理没生效、
/// 定位服务没关开、蜂窝下根本没有代理入口），开关一样会亮、界面一样提示
/// 「已开启」，但位置纹丝不动。校验就是**回读本机定位去对目标点**，
/// 所以这里的重点是「阈值会不会把两件事混起来」。
@MainActor
final class SpoofEffectVerifierTests: XCTestCase {

    /// 天安门的 GCJ-02 数值（高德给的），当目标点。
    private let target = CLLocationCoordinate2D(latitude: 39.908722, longitude: 116.397499)

    /// 在目标点正北方向上偏移若干米（1 度纬度 ≈ 111.32 公里）。
    private func offset(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: target.latitude + meters / 111_320.0,
            longitude: target.longitude
        )
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    // MARK: - 判定

    func testExactMatchIsEffective() {
        XCTAssertTrue(SpoofEffectVerifier.isEffective(probe: target, target: target))
    }

    /// 移动模拟最大抖动半径是 20 米，抖到边界上必须仍然算「生效」。
    func testMotionJitterAtMaxRadiusIsEffective() {
        XCTAssertTrue(SpoofEffectVerifier.isEffective(probe: offset(20), target: target))
    }

    func testBoundaryInsideThresholdIsEffective() {
        XCTAssertTrue(SpoofEffectVerifier.isEffective(probe: offset(79), target: target))
    }

    func testBoundaryOutsideThresholdIsIneffective() {
        XCTAssertFalse(SpoofEffectVerifier.isEffective(probe: offset(81), target: target))
    }

    func testRealLocationHundredsOfMetersAwayIsIneffective() {
        XCTAssertFalse(SpoofEffectVerifier.isEffective(probe: offset(445), target: target))
    }

    /// **最容易错的一处**：回读坐标和地图用的是同一套体系，若拿另一套去比，
    /// 差着几百米，会把「已经生效」判成「没生效」。
    func testCoordinateSystemMixUpIsIneffective() {
        let asGCJ = CoordinateConverter.wgs84ToGCJ02(
            latitude: target.latitude,
            longitude: target.longitude
        )
        let mixed = CLLocationCoordinate2D(
            latitude: asGCJ.latitude,
            longitude: asGCJ.longitude
        )
        XCTAssertGreaterThan(
            distance(mixed, target), 300,
            "两套体系在北京应当差着几百米，这条断言是下面那条测试的前提"
        )
        XCTAssertFalse(SpoofEffectVerifier.isEffective(probe: mixed, target: target))
    }

    // MARK: - 驱动

    func testRunReportsEffectiveOnceProbeReachesTarget() async {
        let verifier = SpoofEffectVerifier()
        var calls = 0

        let task = verifier.run(target: target, attempts: 5, interval: 0) {
            calls += 1
            // 前两次还是旧位置（用户还没去关开定位服务），第三次才跳到目标点。
            return .success(calls < 3 ? self.offset(1200) : self.target)
        }
        await task.value

        XCTAssertEqual(calls, 3)
        XCTAssertTrue(verifier.isEffective)
        XCTAssertEqual(verifier.status.pillText, AppLocalization.string("已生效"))
    }

    func testRunReportsIneffectiveAfterAttemptsExhausted() async {
        let verifier = SpoofEffectVerifier()
        var calls = 0

        let task = verifier.run(target: target, attempts: 4, interval: 0) {
            calls += 1
            return .success(self.offset(2500))
        }
        await task.value

        XCTAssertEqual(calls, 4, "应当一直探到次数用尽")
        XCTAssertFalse(verifier.isEffective)
        XCTAssertEqual(verifier.status, .ineffective(reason: .stillRealLocation))
    }

    /// 定位权限/总开关关着时不该白等满 30 秒，一次就要给结论。
    func testRunReportsLocationUnavailableWithoutRetrying() async {
        let verifier = SpoofEffectVerifier()
        var calls = 0

        let task = verifier.run(target: target, attempts: 5, interval: 0) {
            calls += 1
            return .failure(.denied)
        }
        await task.value

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(verifier.status, .ineffective(reason: .locationUnavailable))
    }

    /// 「暂时解算不出来」是可恢复的，要继续试。
    func testRunKeepsTryingWhenLocationTemporarilyUnavailable() async {
        let verifier = SpoofEffectVerifier()
        var calls = 0

        let task = verifier.run(target: target, attempts: 3, interval: 0) {
            calls += 1
            return calls < 3 ? .failure(.unavailable("暂时定位不到")) : .success(self.target)
        }
        await task.value

        XCTAssertEqual(calls, 3)
        XCTAssertTrue(verifier.isEffective)
    }

    func testResetReturnsToIdleAndCancelsRunningCheck() async {
        let verifier = SpoofEffectVerifier()

        let task = verifier.run(target: target, attempts: 5, interval: 0.05) {
            .success(self.offset(3000))
        }
        verifier.reset()

        XCTAssertEqual(verifier.status, .idle)
        XCTAssertFalse(verifier.isEffective)

        await task.value
        XCTAssertEqual(verifier.status, .idle, "被取消的那一轮不许再改结论")
    }

    func testPillTextFollowsStatus() async {
        let verifier = SpoofEffectVerifier()
        XCTAssertEqual(verifier.status.pillText, AppLocalization.string("未验证"))

        let task = verifier.run(target: target, attempts: 1, interval: 0) {
            .success(self.target)
        }
        await task.value
        XCTAssertEqual(verifier.status.pillText, AppLocalization.string("已生效"))
    }
}
