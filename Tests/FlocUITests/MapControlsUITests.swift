import XCTest

/// 地图页控件的命中测试。
///
/// 存在的理由：1.0.10 的用户反馈里有两条是**明明看得见、就是点不动**：
///
///   1. 「地图页面设置很难点进去」
///   2. 「搜索框的 X 也点不了，点一下竟然是地图选点」
///
/// 这两条都不是逻辑错，单测覆盖不到——`Button` 的 action 写得再对，
/// 只要命中区域被别的东西（玻璃层、地图的手势识别器、被裁掉的布局）
/// 吃掉了，按下去就是没反应。只有在真实的命中测试里才暴露得出来。
///
/// 关键点：`XCUIElement.tap()` 是**按元素中心合成一次真实触摸**，
/// 触摸落到谁身上由 UIKit 的 hit-test 决定。所以如果按钮被盖住，
/// 这里点下去同样点不到东西——正是我们要复现的现场。
final class MapControlsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 把整棵可访问性树的坐标与可点状态倒出来。
    ///
    /// 命中类问题看这个最直接：帧位置对不对、按钮是不是 `hittable`、
    /// 有没有一个意料之外的视图压在它上面。
    func testDumpAccessibilityTree() throws {
        let app = XCUIApplication()
        app.launch()
        try requireMainScreen(app)

        let dump = app.debugDescription
        let attachment = XCTAttachment(string: dump)
        attachment.name = "可访问性树"
        attachment.lifetime = .keepAlways
        add(attachment)

        // 顺便把「设置」按钮自己的坐标与可点状态钉进报告。
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.exists, "找不到「设置」按钮")
        print("[DUMP] 设置 frame=\(settings.frame) hittable=\(settings.isHittable)")

        attach(app, name: "01-主界面")
    }

    /// 「设置」点得动 → 设置面板出来。
    func testSettingsButtonOpensSheet() throws {
        let app = XCUIApplication()
        app.launch()
        try requireMainScreen(app)

        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.isHittable, "「设置」按钮存在但不可点（被别的视图盖住了）")
        settings.tap()

        XCTAssertTrue(
            app.staticTexts["运行模式"].firstMatch.waitForExistence(timeout: 10),
            "点了「设置」之后设置面板没有出现"
        )
        attach(app, name: "02-设置面板")
    }

    /// 搜索结果出来之后，点 X 能清空搜索框。
    func testSearchClearButtonClearsQuery() throws {
        let app = XCUIApplication()
        app.launch()
        try requireMainScreen(app)

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "找不到搜索框")
        XCTAssertTrue(field.isHittable, "搜索框存在但不可点")

        // 焦点是要点：`tap()` 之后键盘不一定马上起来（地图页启动后有代理初始化、
        // 证书校验、网络监听一堆事在跑），直接 `typeText` 会抛
        // 「Neither element nor any descendant has keyboard focus」。
        // 这里重试几次，并把每次的焦点状态打进日志，出问题时有据可查。
        var focused = false
        for attempt in 1...3 where !focused {
            field.tap()
            Thread.sleep(forTimeInterval: 1.0)
            focused = (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
            print("[DUMP] 第 \(attempt) 次点搜索框：focused=\(focused) "
                  + "keyboards=\(app.keyboards.count) frame=\(field.frame)")
        }
        XCTAssertTrue(focused, "点搜索框拿不到键盘焦点")
        field.typeText("beijing")

        let clear = app.buttons["清空"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5),
                      "输入之后没有出现「清空」按钮")
        print("[DUMP] 清空 frame=\(clear.frame) hittable=\(clear.isHittable)")
        XCTAssertTrue(clear.isHittable, "「清空」按钮存在但不可点")
        attach(app, name: "03-输入后")

        clear.tap()

        // 清空之后 X 自己应该消失；如果没消失，说明点击根本没落到按钮上。
        XCTAssertTrue(
            clear.waitForNonExistence(timeout: 5),
            "点了「清除」之后按钮还在——说明这一下点击没命中按钮（落到了地图上）"
        )
        XCTAssertEqual(field.value as? String, AppLocalizationProbe.searchPlaceholder,
                       "搜索框没有被清空")
        attach(app, name: "04-清除后")
    }

    /// 底部面板不能把点击漏给下面的地图。
    ///
    /// 用户反馈的第 3 条：「开启虚拟定位按钮那一大块面板也会穿透然后选点」。
    /// 面板本身是玻璃底板，`.background` 画的底**不扩大命中区域**，所以 1.0.10
    /// 里面板上除了真正的控件以外全是洞 —— 点偏一点就变成一次地图选点。
    /// 修法是给浮层补 `contentShape`（见 `Shared/GlassCard.swift` 的说明），
    /// 这个用例负责钉住它。
    ///
    /// 判定用「坐标文案有没有变」：选点成功时面板上会出现 GCJ-02 / WGS-84 两行
    /// 坐标，穿透一次就会多出（或换掉）这行字。
    func testBottomPanelDoesNotLeakTapsToMap() throws {
        let app = XCUIApplication()
        app.launch()
        try requireMainScreen(app)

        let start = app.buttons["开启虚拟定位"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "找不到「开启虚拟定位」按钮")
        print("[DUMP] 开启虚拟定位 frame=\(start.frame) enabled=\(start.isEnabled) "
              + "hittable=\(start.isHittable)")

        let before = coordinateLabel(app)
        print("[DUMP] 面板点击前的坐标文案=\(before ?? "（无选点）")")

        // 1) 主按钮自己。未选点时它是 disabled 的，disabled 的控件不参与命中，
        //    这一下必须被面板吃掉，而不是落到地图上变成一个选点。
        if start.isEnabled {
            print("[DUMP] 已有选点，主按钮是启用状态，跳过这一档（点了会真的开启虚拟定位）")
        } else {
            start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
            XCTAssertEqual(coordinateLabel(app), before,
                           "点「开启虚拟定位」（置灰）穿透到了地图，产生了选点")
        }

        // 2) 面板左侧的内边距（14pt，任何一行都在它右边），是最典型的「玻璃空白处」。
        start.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: -7, dy: 0))
            .tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(coordinateLabel(app), before, "点面板左侧留白穿透到了地图")

        // 3) 动作按钮下方的那条内边距（面板底边与按钮之间还有 14pt）。
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 6))
            .tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(coordinateLabel(app), before, "点面板底部留白穿透到了地图")
        attach(app, name: "05-面板留白点击后")

        // 负对照：地图上的点击**必须**能选出点来。没有这一条，上面的断言可能
        // 因为「选点这个反馈根本不出现」而假通过。
        //
        // 两个坑（都是 2026-10-09 实测踩到的）：
        //
        //   1. **别点在屏幕正中那一带**。App 启动时会把「当前位置」自动选成选点、
        //      地图也以它为中心，蓝点就画在 (0.5, 0.30) 附近；点在蓝点上得到的
        //      坐标和原选点**逐位相同**，负对照就假失败（文案前后都是
        //      `50.035581, 108.792002`）。下面这几个落点都在地图空处。
        //   2. **地图可交互之前，合成点击会被吞掉**。整套跑（机器更累）时偶发，
        //      单跑必过。所以多个落点轮流试、每次等 2 秒。
        //
        // 试完还是不动就 skip：上面那几条防穿透断言**已经跑过**了，这里只是
        // 想证明它们不是"因为选点根本出不来"而假通过；驱动不了地图不该把
        // 整套用例判红。
        let window = app.windows.firstMatch
        let probePoints: [CGVector] = [
            CGVector(dx: 0.22, dy: 0.42),
            CGVector(dx: 0.80, dy: 0.38),
            CGVector(dx: 0.20, dy: 0.58),
            CGVector(dx: 0.68, dy: 0.55),
            CGVector(dx: 0.35, dy: 0.25),
        ]
        var after = before
        for (index, point) in probePoints.enumerated() {
            window.coordinate(withNormalizedOffset: point).tap()
            Thread.sleep(forTimeInterval: 2.0)
            after = coordinateLabel(app)
            if after != before {
                print("[DUMP] 负对照第 \(index + 1) 次点击（\(point.dx), \(point.dy)）"
                      + "换掉了选点：\(before ?? "（无）") → \(after ?? "（无）")")
                break
            }
            print("[DUMP] 负对照第 \(index + 1) 次点击（\(point.dx), \(point.dy)）没有反应")
        }

        guard let after else {
            throw XCTSkip("在地图上点一下没有产生选点（模拟器没有地图数据 / 定位权限未授予），"
                          + "无法据此判断面板是否穿透")
        }
        guard after != before else {
            throw XCTSkip("地图连点 5 次都没有换掉选点：这一轮地图不可交互（模拟器偶发），"
                          + "无法据此判断面板是否穿透。防穿透的那几条断言在上面已经跑过。")
        }
        print("[DUMP] 地图点击后的坐标文案=\(after)")
        attach(app, name: "06-地图点击后")
    }

    // MARK: - 辅助

    /// 面板上那两行坐标文案。没有选点时返回 nil。
    private func coordinateLabel(_ app: XCUIApplication) -> String? {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "GCJ-02")
        let element = app.staticTexts.matching(predicate).firstMatch
        guard element.exists else { return nil }
        return element.label
    }

    /// 主界面上必须有「设置」按钮，否则说明 App 停在引导流程里。
    private func requireMainScreen(_ app: XCUIApplication) throws {
        guard app.buttons["设置"].waitForExistence(timeout: 30) else {
            throw XCTSkip("App 停在引导流程里，测试前需要先跳过引导（见 Tests/README-ui-tests.md）")
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// 搜索框的占位文案。
///
/// 界面测试里不引用项目内部的 `AppLocalization`（`Tests/FlocUITests` 不进主
/// target 的编译单元），所以这里写死一份。空搜索框的 `value` 就是占位文案。
enum AppLocalizationProbe {
    static let searchPlaceholder = "搜索地点或地址"
}
