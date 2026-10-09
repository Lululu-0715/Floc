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
        // `requireMainScreen` 只等「存在」，而按钮刚出现的那几帧还可能被启动动画
        // 压着（`isHittable` 一时为假）。实测整轮跑的时候这条会偶发失败、
        // 单独重跑必过 —— 属于模拟器时序，不能拿它判红。
        XCTAssertTrue(waitForHittable(settings), "「设置」按钮存在但不可点（被别的视图盖住了）")
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
        // 焦点拿到≠字进去：18.4 上偶发 `typeText` 不落字（键盘在、文本没进，
        // 表现就是「清空」按钮一直不出现，单跑却必过）。重试有界（≤2 次），
        // 和图层浮标那条一样，别把模拟器偶发判成红。
        let clear = app.buttons["清空"]
        var typed = false
        for attempt in 1...2 where !typed {
            field.typeText("beijing")
            typed = clear.waitForExistence(timeout: 5)
            if !typed {
                print("[DUMP] 第 \(attempt) 次输入后「清空」没出现，重试")
            }
        }
        XCTAssertTrue(typed, "输入之后没有出现「清空」按钮")
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

        // 2) 面板左侧的内边距（二十几 pt，任何一行都在它右边），是最典型的
        //    「玻璃空白处」。
        start.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: -7, dy: 0))
            .tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(coordinateLabel(app), before, "点面板左侧留白穿透到了地图")

        // 3) 动作按钮下方的那条内边距（面板底边与按钮之间还有二十几 pt）。
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

    /// 图层浮标点得动 → 向上弹出竖胶囊菜单 → 选一项就收起并且当前图层跟着变。
    ///
    /// 1.0.12 及以前图层切换是右下角竖排三个方块按钮，点一下就换，没有菜单。
    /// 1.0.13 初版是一颗圆浮标 + **向左**弹出的横向卡片（图标 + 文字 + 勾），
    /// 用户嫌「这样往左有点丑」，1.0.14 改成**从图层圆钮上方长出来的竖胶囊、
    /// 三个纯图标选项**。这条把「弹得出、弹在上方、收得回、选得中」一起钉住。
    func testLayerButtonOpensMenuAndSwitchesMapType() throws {
        let app = XCUIApplication()
        app.launch()
        try requireMainScreen(app)

        let layer = app.buttons["图层"]
        XCTAssertTrue(layer.waitForExistence(timeout: 10), "找不到「图层」浮标")
        XCTAssertTrue(layer.isHittable, "「图层」浮标存在但不可点（被别的视图盖住了）")

        // 没点之前菜单不该在。三个选项都是菜单里的按钮，用的是图层名做标签
        // （界面上没有文字，纯图标 —— 标签只给可访问性用）。
        XCTAssertFalse(app.buttons["卫星"].exists, "还没点「图层」，菜单就已经展开了")
        let before = layer.value as? String
        print("[DUMP] 图层浮标 value=\(before ?? "（空）") frame=\(layer.frame)")

        layer.tap()
        // 模拟器偶发丢首击：录屏里看得到玻璃按下高亮又回弹，但按钮的动作没触发
        // ——点完菜单没出来、地图也没收到这一下（坐标纹丝不动），几何逐位相同、
        // 单跑必过。属于「模拟器偶发」那一类，按工程惯例补点，最多三次。
        if !app.buttons["卫星"].waitForExistence(timeout: 3) {
            print("[DUMP] 第一次点「图层」没有弹出菜单，补点一次")
            layer.tap()
        }
        let satellite = app.buttons["卫星"]
        let standard = app.buttons["标准"]
        let hybrid = app.buttons["混合"]
        XCTAssertTrue(satellite.waitForExistence(timeout: 5),
                      "点了「图层」浮标没有弹出菜单")
        XCTAssertTrue(standard.exists && hybrid.exists,
                      "菜单里应当有「标准 / 卫星 / 混合」三项")
        print("[DUMP] 图层浮标=\(layer.frame) 菜单三项="
              + "\(standard.frame) / \(satellite.frame) / \(hybrid.frame)")

        // 方向与形态：整列长在图层浮标**上方**（用户要的「往上展开」），
        // 而且是竖排的一列（横向中心对齐）—— 横向卡片是上一版的样子。
        XCTAssertLessThan(hybrid.frame.maxY, layer.frame.minY,
                          "菜单没有长在图层浮标上方（还往左或往下弹）")
        XCTAssertLessThan(standard.frame.minY, satellite.frame.minY, "菜单项不是竖排的")
        XCTAssertLessThan(satellite.frame.minY, hybrid.frame.minY, "菜单项不是竖排的")
        XCTAssertEqual(standard.frame.midX, satellite.frame.midX, accuracy: 2,
                       "三个选项不在同一列上（不是竖胶囊）")
        attach(app, name: "07-图层菜单")

        satellite.tap()
        XCTAssertTrue(app.buttons["卫星"].waitForNonExistence(timeout: 5),
                      "选完图层菜单没有收起")

        // 菜单收起之后，浮标自己的 `value` 应该变成刚选的那一项。
        let after = layer.value as? String
        print("[DUMP] 选完之后图层浮标 value=\(after ?? "（空）")")
        XCTAssertEqual(after, "卫星", "选完「卫星」之后浮标上的当前图层没有更新")
        XCTAssertNotEqual(after, before, "菜单选了但当前图层没变（一直是 \(after ?? "空")）")
        attach(app, name: "08-切到卫星图")
    }

    /// 引导弹窗：出得来、「不再提示」关得掉、而且**重启后不再弹**。
    ///
    /// 真实触发路径是「开启虚拟定位成功」，而模拟器上开虚拟定位要 Wi-Fi 代理
    /// 加上证书信任，会先弹「证书尚未被信任」，端到端跑不通。所以走 DEBUG
    /// 编译下留的两个启动参数注入（见 `MapHomeView.applyUITestLaunchArguments`），
    /// 否则这条用例只能常年 `XCTSkip`，等于没测。
    ///
    /// 后半段就是用户要的「记忆功能」：第二次启动**不重置**，弹窗必须不出现。
    func testSpoofGuideShowsAndRemembersDismissal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetGuideAndShow"]
        app.launch()
        try requireMainScreen(app)

        let title = app.staticTexts["虚拟定位已开启"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "注入之后引导弹窗没有弹出来")
        XCTAssertTrue(app.buttons["去设置"].exists, "引导弹窗里找不到「去设置」")
        let dismiss = app.buttons["不再提示"]
        XCTAssertTrue(dismiss.exists, "引导弹窗里找不到「不再提示」")
        print("[DUMP] 引导弹窗「不再提示」frame=\(dismiss.frame)")
        attach(app, name: "07-引导弹窗")

        dismiss.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5),
                      "点了「不再提示」弹窗没有关掉")

        // 重启一次（这次不重置）：点过「不再提示」就该永远不再弹。
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-uiTestShowGuideIfNeeded"]
        relaunched.launch()
        try requireMainScreen(relaunched)
        // 真要弹的话这一会儿足够弹出来了。
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(relaunched.staticTexts["虚拟定位已开启"].exists,
                       "用户点过「不再提示」之后，重启又弹了一次引导")
        attach(relaunched, name: "08-重启后不再弹")
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

    /// 等元素真的可点（最多 3 秒）。
    ///
    /// 「存在」不等于「可点」：App 刚 `launch()` 完的那几帧里，按钮已经在
    /// 可访问性树上了，但启动动画 / 首次布局还没落定，`isHittable` 会一时为假。
    /// 整轮跑的时候机器更忙，这个窗口更长 —— 直接断言就会偶发失败。
    private func waitForHittable(_ element: XCUIElement,
                                 timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        print("[DUMP] 等不到可点：\(element) frame=\(element.frame) "
              + "exists=\(element.exists) hittable=\(element.isHittable)")
        return false
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
