import XCTest
@testable import Floc

/// Go 核心桥接测试。
///
/// 这一组测试的价值在于**验证链接**：如果 `libwloccore.a` 没被正确编译或链接，
/// 这里会直接崩溃/失败，而不是等到用户装到手机上才发现。
///
/// 同时也验证跨语言数据传递（C 字符串、PEM、结构体返回）在真实运行环境下可用。
final class CoreBridgeTests: XCTestCase {

    // MARK: - 链接与版本

    func testCoreVersionIsAvailable() {
        let version = CoreBridge.coreVersion

        XCTAssertFalse(version.isEmpty, "Core 版本号不应为空——为空说明静态库没链接上")
        // 版本形如 1.0.0
        let parts = version.split(separator: ".")
        XCTAssertGreaterThanOrEqual(parts.count, 2, "版本号格式异常：\(version)")
    }

    // MARK: - 证书签发

    func testGenerateCertificateAuthority() throws {
        let authority = try CoreBridge.generateCertificateAuthority()

        XCTAssertTrue(authority.certPEM.contains("BEGIN CERTIFICATE"), "应产出 PEM 证书")
        XCTAssertTrue(authority.keyPEM.contains("PRIVATE KEY"), "应产出 PEM 私钥")
        XCTAssertGreaterThan(authority.certPEM.count, 500, "证书内容过短，可能未真正生成")
        XCTAssertGreaterThan(authority.keyPEM.count, 500, "私钥内容过短，可能未真正生成")
    }

    func testGeneratedCertificateAuthorityIsValid() throws {
        let authority = try CoreBridge.generateCertificateAuthority()

        XCTAssertTrue(
            CoreBridge.isValidCertificateAuthority(authority),
            "刚生成的 CA 应当自校验通过"
        )
    }

    func testTwoGenerationsProduceDifferentCertificates() throws {
        let first = try CoreBridge.generateCertificateAuthority()
        let second = try CoreBridge.generateCertificateAuthority()

        XCTAssertNotEqual(
            first.certPEM,
            second.certPEM,
            "两次生成的证书必须不同（序列号随机），否则存在固定密钥风险"
        )
    }

    func testTamperedCertificateIsRejected() throws {
        let authority = try CoreBridge.generateCertificateAuthority()

        // 把证书体中间的一个字符改掉，校验应当失败
        var lines = authority.certPEM.components(separatedBy: "\n")
        guard lines.count > 3 else {
            return XCTFail("证书格式异常")
        }
        let bodyIndex = 1
        var body = Array(lines[bodyIndex])
        if body.count > 10 {
            body[10] = body[10] == "A" ? "B" : "A"
            lines[bodyIndex] = String(body)
        }

        let tampered = CertificateAuthority(
            certPEM: lines.joined(separator: "\n"),
            keyPEM: authority.keyPEM
        )

        XCTAssertFalse(
            CoreBridge.isValidCertificateAuthority(tampered),
            "被篡改的证书必须校验失败"
        )
    }

    func testMismatchedKeyIsRejected() throws {
        let first = try CoreBridge.generateCertificateAuthority()
        let second = try CoreBridge.generateCertificateAuthority()

        // 证书与私钥不配对，校验必须失败——否则代理会用错误的密钥做 MITM
        let mismatched = CertificateAuthority(
            certPEM: first.certPEM,
            keyPEM: second.keyPEM
        )

        XCTAssertFalse(
            CoreBridge.isValidCertificateAuthority(mismatched),
            "证书与私钥不匹配时必须校验失败"
        )
    }

    func testEmptyInputIsRejected() {
        let empty = CertificateAuthority(certPEM: "", keyPEM: "")
        XCTAssertFalse(
            CoreBridge.isValidCertificateAuthority(empty),
            "空证书必须校验失败，而不是崩溃"
        )
    }

    // MARK: - 改写引擎自检

    func testSelfCheckPatchReportsSuccess() {
        let result = CoreBridge.selfCheckPatch(
            latitude: 39.908722,
            longitude: 116.397499,
            accuracy: 25
        )

        XCTAssertFalse(result.isEmpty, "自检应返回结果描述")
        XCTAssertFalse(
            result.lowercased().hasPrefix("error"),
            "自检不应报错：\(result)"
        )
    }

    func testSelfCheckPatchHandlesVariousCoordinates() {
        let samples = [
            (name: "北京", latitude: 39.908722, longitude: 116.397499),
            (name: "南半球", latitude: -33.868820, longitude: 151.209290),
            (name: "西半球", latitude: 40.712800, longitude: -74.006000),
            (name: "赤道", latitude: 0.0, longitude: 0.0),
        ]

        for sample in samples {
            let result = CoreBridge.selfCheckPatch(
                latitude: sample.latitude,
                longitude: sample.longitude,
                accuracy: 25
            )
            XCTAssertFalse(
                result.lowercased().hasPrefix("error"),
                "\(sample.name) 自检失败：\(result)"
            )
        }
    }

    func testSampleRequestHexIsValidHex() {
        let hex = CoreBridge.sampleRequestHex()

        XCTAssertFalse(hex.isEmpty, "示例请求不应为空")
        XCTAssertEqual(hex.count % 2, 0, "十六进制串长度应为偶数")

        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        XCTAssertTrue(
            hex.unicodeScalars.allSatisfy { allowed.contains($0) },
            "示例请求应只含十六进制字符"
        )
    }

    // MARK: - 验证 token

    func testRefreshVerifyTokenReturnsNonEmpty() {
        let token = CoreBridge.refreshVerifyToken()
        XCTAssertFalse(token.isEmpty, "刷新后应返回有效 token")
    }

    func testTokenRoundTrip() {
        let token = CoreBridge.refreshVerifyToken()

        XCTAssertTrue(
            CoreBridge.checkVerifyToken(token),
            "刚刷新的 token 应校验通过"
        )
    }

    func testStaleTokenIsRejected() {
        let stale = CoreBridge.refreshVerifyToken()
        // 再刷一次，旧的应当失效
        _ = CoreBridge.refreshVerifyToken()

        XCTAssertFalse(
            CoreBridge.checkVerifyToken(stale),
            "旧 token 应失效——否则无法确认本次代理链路真的通了"
        )
    }

    func testRandomTokenIsRejected() {
        _ = CoreBridge.refreshVerifyToken()

        XCTAssertFalse(
            CoreBridge.checkVerifyToken("abcdef0123456789"),
            "随机 token 不应通过校验"
        )
    }

    func testEmptyTokenIsRejected() {
        _ = CoreBridge.refreshVerifyToken()

        XCTAssertFalse(CoreBridge.checkVerifyToken(""), "空 token 不应通过校验")
    }

    // MARK: - 配置更新

    func testUpdatePatchConfigDoesNotCrash() {
        // 这个接口没有返回值，只能验证调用不崩溃，且随后自检仍然正常。
        CoreBridge.updatePatchConfig(
            latitude: 22.281508,
            longitude: 114.174700,
            enabled: true,
            accuracy: 30,
            motionEnabled: true
        )

        let result = CoreBridge.selfCheckPatch(
            latitude: 22.281508,
            longitude: 114.174700,
            accuracy: 30
        )
        XCTAssertFalse(result.lowercased().hasPrefix("error"), "配置更新后自检应正常：\(result)")

        // 恢复为关闭状态，避免影响同进程内其他测试
        CoreBridge.updatePatchConfig(
            latitude: 0,
            longitude: 0,
            enabled: false,
            accuracy: 25,
            motionEnabled: false
        )
    }

    func testUpdatePatchConfigHandlesExtremeValues() {
        // 极点与极端精度不应导致崩溃
        CoreBridge.updatePatchConfig(
            latitude: 90.0,
            longitude: 180.0,
            enabled: true,
            accuracy: 1,
            motionEnabled: false
        )
        CoreBridge.updatePatchConfig(
            latitude: -90.0,
            longitude: -180.0,
            enabled: false,
            accuracy: 5000,
            motionEnabled: false
        )
    }

    // MARK: - 日志搬运

    func testFlushLogsIsCallable() {
        // 触发一次 Core 操作产生日志
        _ = CoreBridge.selfCheckPatch(latitude: 39.9, longitude: 116.4, accuracy: 25)
        // 搬运不应崩溃
        CoreBridge.flushLogs(category: "Test")
    }

    func testFlushLogsWithNoPendingLogsIsHarmless() {
        CoreBridge.flushLogs(category: "Test")
        CoreBridge.flushLogs(category: "Test")
    }
}
