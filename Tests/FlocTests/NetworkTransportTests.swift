import XCTest
@testable import Floc

/// 接入方式与应用内代理可用性的契约测试。
///
/// 这条判断决定「点开启虚拟定位」是被拦下还是放行。写错的方向有两种，
/// 后果不对称，所以两个方向都要锁：
///
///   - 该拦没拦（蜂窝放行）→ 代理起来了、开关亮了、提示「已开启」，
///     但流量根本不经过本机，定位纹丝不动。这是最难排查的一类假成功。
///   - 不该拦却拦（把未知网络也拦掉）→ **模拟器上功能全废**（模拟器的
///     网络走宿主机的有线，永远判不出 Wi-Fi），而真机上反而看不出来，
///     等于把验证手段自己掐断了。
final class NetworkTransportTests: XCTestCase {

    // MARK: - 拦截策略

    func testOnlyCellularBlocksInAppProxy() {
        XCTAssertTrue(
            NetworkTransport.cellular.blocksInAppProxy,
            "蜂窝下必须拦——iOS 没有给蜂窝配 HTTP 代理的入口，代理不可能生效"
        )
    }

    func testWiFiDoesNotBlock() {
        XCTAssertFalse(
            NetworkTransport.wifi.blocksInAppProxy,
            "Wi-Fi 是应用内代理唯一能工作的场景，不能拦"
        )
    }

    func testUnknownDoesNotBlock() {
        XCTAssertFalse(
            NetworkTransport.other.blocksInAppProxy,
            "未知接入方式必须放行：模拟器与有线网络都落在这一档，"
            + "拦掉会让模拟器上的功能全部不可用"
        )
    }

    // MARK: - 日志标识

    func testDebugNamesAreStableAndASCII() {
        // 日志要能跨语言对照，所以标识固定为英文，且不参与本地化。
        XCTAssertEqual(NetworkTransport.wifi.debugName, "wifi")
        XCTAssertEqual(NetworkTransport.cellular.debugName, "cellular")
        XCTAssertEqual(NetworkTransport.other.debugName, "other")
    }

    // MARK: - 与管理器的接线

    /// 测试环境（模拟器）的网络既不是 Wi-Fi 也不是蜂窝，判定结果必须是
    /// 「不拦截」。这条同时验证了 `ProxyManager` 把监听接上了、
    /// 冷启动时的默认值不会误伤。
    @MainActor
    func testProxyManagerDoesNotBlockOnUnknownTransport() {
        let manager = ProxyManager.shared
        XCTAssertEqual(
            manager.networkTransport, .other,
            "模拟器上应判定为未知接入方式"
        )
        XCTAssertTrue(
            manager.canUseInAppProxy,
            "未知接入方式不应拦住应用内代理"
        )
    }
}
