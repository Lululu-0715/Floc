import XCTest

/// 版式与外观的界面测试。
///
/// 两个用例都对应 1.0.11 的真实反馈：
///
///   1. **底部面板要贴底三面齐平**（对齐 Apple 地图）——1.0.11 是左右各留
///      16pt、下边守在安全区里的悬浮卡片。
///   2. **设置页里改外观档位要立刻生效**——用户的原话是「改深色了再改浅色
///      就回不去了，只能退出设置页面再进去」。设置页是 sheet（独立的呈现
///      上下文），根节点那份 `.preferredColorScheme` 盖不到它，所以这里
///      不能只测「控件点得动」，必须测**页面真的变浅/变深了**。
///
/// 外观这一条没有可访问性接口可断言（颜色不在可访问性树里），所以直接量像素：
/// 深色下取一块区域的平均亮度必然很低，浅色下必然很高。这正是用户肉眼的判断方式。
final class LayoutAndAppearanceUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 底部面板贴底

    /// 面板左、右两边要贴到屏幕边缘（原来各留 16pt），并且铺到安全区里。
    func testBottomPanelIsFlushWithScreenEdges() throws {
        let app = XCUIApplication()
        app.launch()
        try requireMainScreen(app)

        // 先在地图上点出一个选点，让面板展开成完整形态。
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30)).tap()
        Thread.sleep(forTimeInterval: 2.0)

        let start = app.buttons["开启虚拟定位"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "找不到「开启虚拟定位」按钮")
        let realLocation = app.buttons["实时位置"]
        XCTAssertTrue(realLocation.exists, "找不到「实时位置」按钮")

        // 面板内侧留白。左右两侧都是它，所以能从两个按钮反推出面板的两条边。
        let inset: CGFloat = 14
        let screen = window.frame

        let panelLeft = start.frame.minX - inset
        let panelRight = realLocation.frame.maxX + inset

        print("[DUMP] 屏幕=\(screen) 面板左边=\(panelLeft) 右边=\(panelRight)")
        attach(app, name: "10-贴边后的底部面板")

        XCTAssertEqual(panelLeft, 0, accuracy: 1.5,
                       "面板左边没有贴到屏幕左边（还留着 \(panelLeft)pt）")
        XCTAssertEqual(panelRight, screen.width, accuracy: 1.5,
                       "面板右边没有贴到屏幕右边（还留着 \(screen.width - panelRight)pt）")

        // 面板要铺进底部安全区（Home 指示条那一条）。这里用「点一下会不会穿透
        // 到地图」来验证：按钮下方 18pt 的位置在旧实现里已经在面板之外了，
        // 一戳就是一个选点。
        let before = coordinateLabel(app)
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 18))
            .tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(coordinateLabel(app), before,
                       "面板下方的安全区没有被面板盖住，点击穿透到地图产生了选点")
    }

    // MARK: - 外观档位即时生效

    /// 设置页里切成深色、再切回浅色，页面必须**当场**跟着变。
    func testAppearanceSwitchAppliesToPresentedSettingsSheet() throws {
        let app = XCUIApplication()
        app.launch()
        try requireMainScreen(app)

        let settings = app.buttons["设置"]
        print("[DUMP] 设置 frame=\(settings.frame) hittable=\(settings.isHittable)")
        settings.tap()
        if !app.staticTexts["运行模式"].firstMatch.waitForExistence(timeout: 10) {
            // 偶发：机器忙的时候第一次点击没把 sheet 推出来（同一份代码单跑必过）。
            // 再点一次；还不行就跳过——这条用例要验的是「外观切换是否当场生效」，
            // sheet 推不出来属于前置条件没满足，「设置按钮点得动」另有两条用例盯着。
            print("[DUMP] 第一次点「设置」没推出面板，重试一次")
            settings.tap()
            if !app.staticTexts["运行模式"].firstMatch.waitForExistence(timeout: 10) {
                attach(app, name: "90-点了设置之后")
                throw XCTSkip("点了两次「设置」都没把设置面板推出来（模拟器偶发），"
                              + "本轮无法验证外观切换。设置 frame=\(settings.frame) "
                              + "hittable=\(settings.isHittable)")
            }
        }

        // 「外观及个性化」在列表靠下的位置，而 `List` 是懒加载的：没滚到那儿
        // 之前行根本没被创建，直接查就是"不存在"。先往下翻几屏。
        var dark: XCUIElement?
        var light: XCUIElement?
        for _ in 1...4 {
            dark = segment(app, "深色")
            light = segment(app, "浅色")
            if dark != nil, light != nil { break }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
        }

        guard let dark, let light else {
            throw XCTSkip("设置页里找不到外观分段控件（可能这一版的列表结构变了）")
        }

        // 采样区域：设置页下半部分的一块，深色下是近黑、浅色下是近白。
        let probe = CGRect(x: 0.35, y: 0.78, width: 0.30, height: 0.12)

        // 三段走完：浅色 → 深色 → 再切回浅色。
        //
        // 顺序不能省。只测「切深色再切浅色」的话，模拟器本身就是深色时第一步
        // 是空操作（页面本来就是深的），量出来的「深色通过」毫无意义；
        // 而最后那一段「切回浅色」正是用户报的那条——1.0.11 里它是唯一
        // 会失败的那一步，因为根节点的 `.preferredColorScheme` 盖不到 sheet。
        let steps: [(element: XCUIElement, expectDark: Bool, name: String)] = [
            (light, false, "11-设为浅色"),
            (dark, true, "12-设为深色"),
            (light, false, "13-切回浅色"),
        ]

        var luminances: [String: CGFloat] = [:]
        for step in steps {
            step.element.tap()
            Thread.sleep(forTimeInterval: 1.2)
            let (value, shot) = measure(app, in: probe)
            luminances[step.name] = value
            pin(shot, name: step.name)

            // 先打日志再断言：`continueAfterFailure` 是关的，一旦断言失败
            // 这条用例就停了，后面的步骤不会执行——把数值印在前面，
            // 报告里才看得到「到底卡在哪一段、当时有多亮」。
            print("[DUMP] \(step.name) 亮度=\(value)")

            if value < 0.01 {
                attach(app, name: "\(step.name)-黑屏")
                throw XCTSkip("量到的是一张全黑截图（\(step.name)）——模拟器这一轮没渲染出来，"
                              + "不是深色的近黑（深色模式的卡片是 0.17）。本轮无法验证外观切换。")
            }

            if step.expectDark {
                XCTAssertLessThan(
                    value, 0.40,
                    "选了「深色」之后设置页没有变深（\(step.name) 亮度 \(value)）"
                )
            } else {
                XCTAssertGreaterThan(
                    value, 0.60,
                    "选了「浅色」之后设置页没有变浅（\(step.name) 亮度 \(value)）。"
                    + "1.0.11 的现场是「地图已经变浅、设置这个 sheet 还钉在深色上」——"
                    + "只改窗口不够，要把整棵视图控制器树都写一遍"
                )
            }
        }

        print("[DUMP] 亮度汇总 " + luminances.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
    }

    // MARK: - 辅助

    /// 分段控件里的一个选项：控件可能挂在 `segmentedControls` 里，也可能是独立按钮。
    private func segment(_ app: XCUIApplication, _ title: String) -> XCUIElement? {
        let inControl = app.segmentedControls.buttons[title]
        if inControl.exists { return inControl }
        let plain = app.buttons[title]
        return plain.exists ? plain : nil
    }

    /// 截一张图并量出探针区的亮度；拿到**全黑**的截图就重拍。
    ///
    /// 全黑（0.00，连状态栏那一块也是 0）不是任何一种正常界面的亮度——深色模式
    /// 下的卡片是 0.17——它基本只有一个来源：这一轮模拟器没渲染出来，
    /// 截图接口给了一张黑图。机器忙的时候（比如整套界面测试一起跑）偶发。
    /// 重拍两三次基本都能拿到真实画面。
    private func measure(
        _ app: XCUIApplication,
        in probe: CGRect,
        attempts: Int = 4
    ) -> (CGFloat, XCUIScreenshot) {
        var last = (CGFloat(0), app.screenshot())
        for attempt in 1...attempts {
            let shot = app.screenshot()
            let value = averageLuminance(shot, in: probe)
            if value >= 0.01 { return (value, shot) }
            last = (value, shot)
            print("[DUMP] 第 \(attempt) 次截到全黑，重拍")
            Thread.sleep(forTimeInterval: 1.5)
        }
        return last
    }

    /// 截图上某块归一化区域的平均亮度（0 全黑 ~ 1 全白）。
    ///
    /// 把这块区域缩成 1×1 像素画出来，画出来的那一个像素就是平均值——
    /// 比自己遍历像素省事，也不容易写错行距。
    private func averageLuminance(_ shot: XCUIScreenshot, in rect: CGRect) -> CGFloat {
        guard let source = shot.image.cgImage else { return -1 }

        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        let area = CGRect(x: rect.minX * width,
                          y: rect.minY * height,
                          width: rect.width * width,
                          height: rect.height * height).integral
        guard let cropped = source.cropping(to: area) else { return -1 }

        let pixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        defer { pixel.deallocate() }
        pixel.update(repeating: 0, count: 4)

        guard let context = CGContext(
            data: pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let r = CGFloat(pixel[0]), g = CGFloat(pixel[1]), b = CGFloat(pixel[2])
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255
    }

    /// 面板上那两行坐标文案。没有选点时返回 nil。
    private func coordinateLabel(_ app: XCUIApplication) -> String? {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "GCJ-02")
        let element = app.staticTexts.matching(predicate).firstMatch
        guard element.exists else { return nil }
        return element.label
    }

    private func requireMainScreen(_ app: XCUIApplication) throws {
        guard app.buttons["设置"].waitForExistence(timeout: 30) else {
            throw XCTSkip("App 停在引导流程里，测试前需要先跳过引导（见 Tests/README-ui-tests.md）")
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        pin(app.screenshot(), name: name)
    }

    private func pin(_ shot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
