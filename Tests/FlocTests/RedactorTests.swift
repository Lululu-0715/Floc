import XCTest
@testable import Floc

/// 日志脱敏测试。
///
/// 日志可能被用户复制后贴到公开 Issue，脱敏必须可靠。
/// 这里对每类敏感信息都构造样本验证，并额外验证「不该动的内容不被误伤」。
final class RedactorTests: XCTestCase {

    // MARK: - 经纬度

    func testRedactsCoordinates() {
        let input = "已设置位置 39.908722, 116.397499"
        let output = Redactor.redact(input)

        XCTAssertFalse(output.contains("39.908722"), "纬度必须被脱敏")
        XCTAssertFalse(output.contains("116.397499"), "经度必须被脱敏")
        XCTAssertTrue(output.contains("已设置位置"), "非敏感文本应保留")
    }

    func testRedactsNegativeCoordinates() {
        let input = "悉尼 -33.868820, 151.209290"
        let output = Redactor.redact(input)

        XCTAssertFalse(output.contains("-33.868820"))
        XCTAssertFalse(output.contains("151.209290"))
    }

    func testRedactsHighPrecisionCoordinates() {
        let input = "坐标 22.281508123456 114.174700987654"
        let output = Redactor.redact(input)

        XCTAssertFalse(output.contains("22.281508123456"))
        XCTAssertFalse(output.contains("114.174700987654"))
    }

    func testDoesNotRedactShortDecimals() {
        // 版本号、进度百分比这类短小数不应被当作坐标脱敏
        let input = "版本 1.0 进度 95.5 耗时 12.34 秒"
        let output = Redactor.redact(input)

        XCTAssertTrue(output.contains("1.0"), "版本号不应被脱敏")
        XCTAssertTrue(output.contains("95.5"), "小数不应被脱敏")
        XCTAssertTrue(output.contains("12.34"), "小数不应被脱敏")
    }

    // MARK: - MAC 地址

    func testRedactsMACAddress() {
        let input = "Wi-Fi 设备 aa:bb:cc:dd:ee:ff 已处理"
        let output = Redactor.redact(input)

        XCTAssertFalse(output.contains("aa:bb:cc:dd:ee:ff"), "MAC 必须被脱敏")
        XCTAssertTrue(output.contains("Wi-Fi 设备"), "非敏感文本应保留")
    }

    func testRedactsUppercaseMACAddress() {
        let input = "MAC AA:BB:CC:DD:EE:FF"
        let output = Redactor.redact(input)

        XCTAssertFalse(output.contains("AA:BB:CC:DD:EE:FF"))
    }

    // MARK: - 长十六进制串

    func testRedactsLongHexString() {
        let digest = String(repeating: "a1b2c3d4", count: 8) // 64 字符
        let input = "证书指纹 \(digest)"
        let output = Redactor.redact(input)

        XCTAssertFalse(output.contains(digest), "长十六进制串必须被脱敏")
    }

    func testDoesNotRedactShortHexString() {
        let input = "错误码 0x8f3a2b"
        let output = Redactor.redact(input)

        XCTAssertTrue(output.contains("8f3a2b"), "短十六进制不应被脱敏")
    }

    // MARK: - 私钥

    func testRedactsPEMPrivateKey() {
        let input = """
        加载密钥失败
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEA1234567890abcdefghijklmnop
        qrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0987
        -----END RSA PRIVATE KEY-----
        已回退
        """

        let output = Redactor.redact(input)

        XCTAssertFalse(output.contains("MIIEowIBAAKCAQEA"), "私钥体必须被脱敏")
        XCTAssertFalse(output.contains("BEGIN RSA PRIVATE KEY"), "私钥头必须被脱敏")
        XCTAssertTrue(output.contains("加载密钥失败"), "上下文应保留")
        XCTAssertTrue(output.contains("已回退"), "上下文应保留")
    }

    // MARK: - URL 令牌

    func testRedactsURLToken() {
        let input = "请求 https://example.com/api?token=abc123secret&page=2"
        let output = Redactor.redact(input)

        XCTAssertFalse(output.contains("abc123secret"), "令牌值必须被脱敏")
        XCTAssertTrue(output.contains("token="), "参数名应保留")
        XCTAssertTrue(output.contains("page=2"), "非敏感参数应保留")
    }

    func testRedactsKeyAndAuthParameters() {
        let inputs = [
            "https://api.test/?key=supersecret",
            "https://api.test/?sign=deadbeefsignature",
            "https://api.test/?auth=bearertoken123",
        ]

        for input in inputs {
            let output = Redactor.redact(input)
            XCTAssertTrue(
                output.contains("<已脱敏>"),
                "应脱敏查询参数值：\(input)"
            )
        }
    }

    // MARK: - 组合与幂等

    func testRedactsMultipleTypesAtOnce() {
        let input = """
        位置 39.908722,116.397499 设备 aa:bb:cc:dd:ee:ff
        请求 https://api.test/?token=secret123
        """

        let output = Redactor.redact(input)

        XCTAssertFalse(output.contains("39.908722"))
        XCTAssertFalse(output.contains("116.397499"))
        XCTAssertFalse(output.contains("aa:bb:cc:dd:ee:ff"))
        XCTAssertFalse(output.contains("secret123"))
    }

    func testRedactionIsIdempotent() {
        let input = "位置 39.908722,116.397499"
        let once = Redactor.redact(input)
        let twice = Redactor.redact(once)

        XCTAssertEqual(once, twice, "重复脱敏不应产生额外变化")
    }

    func testPlainTextIsUnchanged() {
        let input = "代理已启动，监听端口 8888"
        XCTAssertEqual(Redactor.redact(input), input, "无敏感内容时不应改动文本")
    }
}
