import XCTest
@testable import Floc

/// 第三方代理客户端与协议契约测试。
///
/// 这些断言锁定了「App ↔ 客户端脚本」之间的接口约定。任何一侧改动导致
/// 契约不一致，这里都应立刻失败——因为线上表现会是「模块装了但定位不变」，
/// 极难排查。
final class ThirdPartyProxyClientTests: XCTestCase {

    // MARK: - 客户端元数据

    func testAllClientsHaveUniqueIdentifiers() {
        let rawValues = ThirdPartyProxyClient.allCases.map(\.rawValue)
        XCTAssertEqual(
            Set(rawValues).count,
            rawValues.count,
            "客户端标识不应重复"
        )
    }

    func testAllClientsHaveDisplayNameAndScheme() {
        for client in ThirdPartyProxyClient.allCases {
            XCTAssertFalse(client.displayName.isEmpty, "\(client) 缺少显示名")
            XCTAssertFalse(client.urlScheme.isEmpty, "\(client) 缺少 URL Scheme")
            XCTAssertFalse(
                client.moduleFileExtension.isEmpty,
                "\(client) 缺少模块扩展名"
            )
        }
    }

    func testModuleExtensionsMatchClientConvention() {
        // 这些扩展名必须与客户端实际接受的格式一致，否则导入会失败
        XCTAssertEqual(ThirdPartyProxyClient.shadowrocket.moduleFileExtension, "module")
        XCTAssertEqual(ThirdPartyProxyClient.surge.moduleFileExtension, "sgmodule")
        XCTAssertEqual(ThirdPartyProxyClient.quantumultX.moduleFileExtension, "conf")
        XCTAssertEqual(ThirdPartyProxyClient.loon.moduleFileExtension, "lpx")
        XCTAssertEqual(ThirdPartyProxyClient.stash.moduleFileExtension, "stoverride")
        XCTAssertEqual(ThirdPartyProxyClient.egern.moduleFileExtension, "sgmodule")
    }

    func testURLSchemesMatchClientConvention() {
        XCTAssertEqual(ThirdPartyProxyClient.shadowrocket.urlScheme, "shadowrocket")
        XCTAssertEqual(ThirdPartyProxyClient.surge.urlScheme, "surge")
        // Quantumult X 的 scheme 带连字符，容易写错
        XCTAssertEqual(ThirdPartyProxyClient.quantumultX.urlScheme, "quantumult-x")
        XCTAssertEqual(ThirdPartyProxyClient.loon.urlScheme, "loon")
        XCTAssertEqual(ThirdPartyProxyClient.stash.urlScheme, "stash")
        XCTAssertEqual(ThirdPartyProxyClient.egern.urlScheme, "egern")
    }

    func testClientIsCodable() throws {
        for client in ThirdPartyProxyClient.allCases {
            let data = try JSONEncoder().encode(client)
            let decoded = try JSONDecoder().decode(ThirdPartyProxyClient.self, from: data)
            XCTAssertEqual(decoded, client)
        }
    }

    // MARK: - 协议契约

    func testSettingsPathIsStable() {
        // 这个路径被写进了 6 个客户端模块文件，改动会破坏所有已发布模块
        XCTAssertEqual(ThirdPartyProxyProtocol.settingsPath, "/wloc-settings/save")
    }

    func testInterceptedHostsCoverAppleLocationEndpoints() {
        let hosts = ThirdPartyProxyProtocol.interceptedHosts

        XCTAssertTrue(hosts.contains("gs-loc.apple.com"), "必须拦截主定位端点")
        XCTAssertTrue(hosts.contains("gs-loc-cn.apple.com"), "必须拦截国内定位端点")
        XCTAssertFalse(hosts.isEmpty)
    }

    // MARK: - URL 构造

    func testQueryActionURL() {
        let url = ThirdPartyProxyProtocol.url(action: .query)

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "gs-loc.apple.com")
        XCTAssertEqual(url?.path, "/wloc-settings/save")
        XCTAssertTrue(url?.query?.contains("action=query") ?? false)
    }

    func testClearActionURL() {
        let url = ThirdPartyProxyProtocol.url(action: .clear)

        XCTAssertTrue(url?.query?.contains("action=clear") ?? false)
    }

    func testSaveURLContainsAllParameters() {
        let url = ThirdPartyProxyProtocol.url(
            wgs84Latitude: 39.908722,
            wgs84Longitude: 116.397499,
            accuracy: 25
        )

        let query = url?.query ?? ""
        XCTAssertTrue(query.contains("lat=39.908722"), "纬度应保留 6 位小数：\(query)")
        XCTAssertTrue(query.contains("lon=116.397499"), "经度应保留 6 位小数：\(query)")
        XCTAssertTrue(query.contains("acc=25"), "精度应包含：\(query)")
    }

    func testSaveURLUsesWGS84NotGCJ02() {
        // 契约规定查询参数一律用 WGS-84。这里验证传入什么就发什么——
        // 若调用方误传 GCJ-02，偏差会达到数百米。
        let gcjPair = CoordinateConverter.CoordinatePair(
            wgs84Latitude: 39.908722,
            wgs84Longitude: 116.397499
        )
        let url = ThirdPartyProxyProtocol.url(
            wgs84Latitude: gcjPair.wgs84.latitude,
            wgs84Longitude: gcjPair.wgs84.longitude,
            accuracy: 25
        )

        let query = url?.query ?? ""
        XCTAssertTrue(query.contains("lat=39.908722"))
        // 不能出现 GCJ-02 的值
        XCTAssertFalse(
            query.contains(String(format: "%.6f", gcjPair.gcj02.latitude)),
            "不应把 GCJ-02 坐标发出去"
        )
    }

    func testSaveURLWithNegativeCoordinates() {
        let url = ThirdPartyProxyProtocol.url(
            wgs84Latitude: -33.868820,
            wgs84Longitude: 151.209290,
            accuracy: 50
        )

        let query = url?.query ?? ""
        XCTAssertTrue(query.contains("lat=-33.868820"), "南纬应带负号：\(query)")
        XCTAssertTrue(query.contains("lon=151.209290"))
    }

    func testEmptyURLHasNoQueryString() {
        let url = ThirdPartyProxyProtocol.url()

        XCTAssertNil(url?.query, "无参数时不应有多余的 ?")
    }

    // MARK: - 响应解析

    func testParsesSuccessResponse() throws {
        let json = """
        {"success":true,"longitude":116.397499,"latitude":39.908722,"accuracy":25}
        """
        let response = try JSONDecoder().decode(
            ThirdPartyProxyProtocol.Response.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.latitude ?? 0, 39.908722, accuracy: 1e-6)
        XCTAssertEqual(response.longitude ?? 0, 116.397499, accuracy: 1e-6)
        XCTAssertEqual(response.accuracy, 25)
        XCTAssertNil(response.error)
    }

    func testParsesFailureResponse() throws {
        // 脚本在「模块已装但未开启」时返回 success=false，
        // App 据此区分「模块没生效」和「模块在但没开」。
        let json = #"{"success":false,"error":"无已保存的坐标"}"#
        let response = try JSONDecoder().decode(
            ThirdPartyProxyProtocol.Response.self,
            from: Data(json.utf8)
        )

        XCTAssertFalse(response.success)
        XCTAssertEqual(response.error, "无已保存的坐标")
        XCTAssertNil(response.latitude)
    }

    func testParsesResponseWithoutOptionalFields() throws {
        let json = #"{"success":true}"#
        let response = try JSONDecoder().decode(
            ThirdPartyProxyProtocol.Response.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(response.success)
        XCTAssertNil(response.latitude)
        XCTAssertNil(response.longitude)
        XCTAssertNil(response.error)
    }
}
