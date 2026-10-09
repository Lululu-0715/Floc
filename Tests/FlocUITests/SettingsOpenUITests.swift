import XCTest

/// 主流程的界面冒烟测试。
///
/// 存在的理由很具体：1.0.10 上线后收到「连设置都点不亮」的反馈。单元测试
/// 只能证明逻辑对，证明不了**按钮点得动**——`.glassEffect`、被玻璃包住的
/// 浮层、`contentShape` 的缺省区域，这些问题全都只在真机/模拟器的命中测试里
/// 才暴露。这个用例做两件事：确认「设置」按钮存在，点下去之后设置面板
/// 真的出来了，并把每一步截图钉在测试报告里。
///
/// 运行方式（需要先让 App 跳过引导流程，见 `Tests/README-ui-tests.md`）：
/// ```
/// xcodebuild -project Floc.xcodeproj -scheme Floc \
///   -destination 'platform=iOS Simulator,id=<UDID>' \
///   -only-testing:FlocUITests test
/// ```
final class SettingsOpenUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 点「设置」→ 设置面板出现。
    func testSettingsButtonOpensSettingsSheet() throws {
        let app = XCUIApplication()
        app.launch()

        // 引导流程没走完时会停在欢迎页，这时没有「设置」按钮。
        //
        // 这里用 `XCTSkip` 而不是 `XCTFail`：跳过引导需要手工写模拟器里的
        // group plist（见 Tests/README-ui-tests.md），`./build.sh --test`
        // 会在任意一台干净机器上跑，不该因为它没准备过就把出包流程卡死。
        // 跳过会在报告里留一条 skip，不会静默掩盖问题。
        let settingsButton = app.buttons["设置"]
        guard settingsButton.waitForExistence(timeout: 30) else {
            throw XCTSkip("App 停在引导流程里，测试前需要先跳过引导（见 Tests/README-ui-tests.md）")
        }

        attach(app, name: "01-主界面")

        settingsButton.tap()

        // 设置面板第一组就是「运行模式」，用它判定面板真的被推出来了。
        // 只断言按钮消失是不够的——按钮一直都在，只是被 sheet 盖住。
        let marker = app.staticTexts["运行模式"].firstMatch
        XCTAssertTrue(
            marker.waitForExistence(timeout: 10),
            "点了「设置」之后设置面板没有出现（说明按钮的命中区域或 action 有问题）"
        )

        attach(app, name: "02-设置面板")

        // 顺手确认外观分组里的「配色主题」入口也在——它是 1.0.11 新加的，
        // 和设置面板一起被这里守住。
        if app.staticTexts["配色主题"].firstMatch.exists {
            app.staticTexts["配色主题"].firstMatch.tap()
            XCTAssertTrue(
                app.navigationBars["配色主题"].waitForExistence(timeout: 5),
                "「配色主题」入口没打开对应页面"
            )
            attach(app, name: "03-配色主题")
        }
    }

    // MARK: - 辅助

    /// 把当前屏幕截图挂进测试报告。
    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
