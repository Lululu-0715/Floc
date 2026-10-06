import XCTest
@testable import Floc

/// 运动状态模拟（原地抖动半径）的契约测试。
///
/// 这个值会从界面一路传到 Go Core / 第三方客户端脚本，中间任何一处
/// 收敛不严，都可能把「5 米轻微漂移」变成「定位甩到几十公里外」，
/// 所以档位收敛与持久化都要锁死。
final class MotionDriftOptionTests: XCTestCase {

    // MARK: - 档位

    func testSupportedSteps() {
        XCTAssertEqual(
            MotionDriftOption.allCases.map(\.radiusMeters),
            [0, 5, 10, 20],
            "只应提供关闭 / 5 / 10 / 20 四档"
        )
    }

    func testOffMeansDisabled() {
        XCTAssertFalse(MotionDriftOption.off.isEnabled)
        XCTAssertEqual(MotionDriftOption.off.radiusMeters, 0)
    }

    func testNonZeroStepsAreEnabled() {
        for option in MotionDriftOption.allCases where option != .off {
            XCTAssertTrue(option.isEnabled, "\(option.rawValue) 米应当是开启状态")
            XCTAssertGreaterThan(option.radiusMeters, 0)
        }
    }

    // MARK: - 收敛

    func testNormalizeAcceptsSupportedValues() {
        for option in MotionDriftOption.allCases {
            XCTAssertEqual(
                MotionDriftOption.normalized(option.rawValue),
                option,
                "\(option.rawValue) 是受支持档位，不应被收敛"
            )
        }
    }

    func testNormalizeRejectsUnsupportedValues() {
        // 这些值可能来自旧版本存储或被篡改的配置。
        // 一律归零而不是就近取整——就近取整会让界面显示的档位
        // 与实际生效的半径不一致。
        for value in [1, 2, 4, 6, 7, 15, 19, 25, 100, -5, 100_000] {
            XCTAssertEqual(
                MotionDriftOption.normalized(value),
                .off,
                "\(value) 不是受支持档位，应当收敛为关闭"
            )
        }
    }

    // MARK: - 展示

    func testDisplayNameIsNotEmpty() {
        for option in MotionDriftOption.allCases {
            XCTAssertFalse(option.displayName.isEmpty, "\(option) 缺少显示名")
        }
    }

    // MARK: - 持久化

    @MainActor
    func testStatePersistsDriftRadius() {
        let defaults = UserDefaults(suiteName: "MotionDriftOptionTests.persist")!
        defaults.removePersistentDomain(forName: "MotionDriftOptionTests.persist")

        let state = MapLocationState(defaults: defaults)
        XCTAssertEqual(state.motionDriftRadius, 0, "默认应当是关闭")

        state.motionDriftRadius = MotionDriftOption.tenMeters.rawValue
        state.persist()

        let restored = MapLocationState(defaults: defaults)
        XCTAssertEqual(restored.motionDriftRadius, 10, "抖动半径应当被持久化")
    }

    @MainActor
    func testStateSanitizesStoredDriftRadius() {
        let suiteName = "MotionDriftOptionTests.sanitize"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        // 旧数据 / 脏数据里出现了一个不支持的半径
        defaults.set(7, forKey: "spoofMotionDriftRadius")

        let state = MapLocationState(defaults: defaults)
        XCTAssertEqual(state.motionDriftRadius, 0, "非法档位应当在读取时归零")
    }
}
