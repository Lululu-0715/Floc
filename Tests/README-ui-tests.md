# 界面（UI）测试怎么跑

`Tests/FlocUITests` 下的用例会真的点界面，跑之前必须先把模拟器里的 App
**跳过引导流程**，否则它会停在欢迎页，找不到主界面上的按钮。

## 一、准备模拟器

```bash
UDID=<模拟器 UDID>
# 1) 先装一次 App（任意 Debug 构建即可），让它创建数据容器
xcrun simctl boot "$UDID"
xcrun simctl install "$UDID" build/DerivedData/Build/Products/Debug-iphonesimulator/Floc.app

# 2) 取数据容器路径（UUID 每一轮都会变，别复用）
C=$(xcrun simctl get_app_container "$UDID" com.fff.loc data)
F="$C/Library/Preferences/group.com.fff.loc.plist"
mkdir -p "$C/Library/Preferences"
[ -f "$F" ] || plutil -create xml1 "$F"

# 3) 写「已经走过引导」的四个键
for k in welcomeOnboardingSeen hasSelectedRuntimeMode localProxyInitialized thirdPartyInitialized; do
  plutil -insert "$k" -bool true "$F" 2>/dev/null || plutil -replace "$k" -bool true "$F"
done
plutil -insert proxyRuntimeMode -string localProxy "$F" 2>/dev/null \
  || plutil -replace proxyRuntimeMode -string localProxy "$F"
```

两个坑：

- **不能 `defaults write <路径>`**：那样只落到宿主机的 `cfprefsd` 缓存里，
  文件根本没变（`defaults read` 读的是缓存，看着像成功）。只能用 `plutil`。
- **`hasSelectedRuntimeMode` 最容易漏**：`hasSelectedMode` 判断用的是它，
  少了这个键即使其它三个都对，App 仍会停在模式选择页。
- iOS 26 上未签名 App 拿不到 App Group（`NOT_CODESIGNED`），
  但 `UserDefaults(suiteName:)` 仍返回非 nil，所以 `?? .standard` 兜底不会触发
  —— 必须写上面那份 **group** plist。

## 二、跑用例

```bash
xcodebuild -project Floc.xcodeproj -scheme Floc \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath build/DerivedData \
  -only-testing:FlocUITests test
```

截图会挂在 `result.xcresult` 里，用 Xcode 打开报告即可看到。

`./build.sh --test` 也会带上这些用例。**没准备过的模拟器不会把整条出包流程卡死**：
用例发现主界面上没有「设置」按钮时会 `XCTSkip`（报告里留一条 skip），
而不是失败。想让它真正跑到，就按上面第一节把模拟器准备好。

## 二·五、模拟器「硬件键盘」会伪装成 App 的 bug

**现象**：用例在 `typeText` 处报
`Failed to synthesize event: Neither element nor any descendant has keyboard focus`，
看着像「点了搜索框没反应」，其实是**模拟器连上了宿主机的硬件键盘**、
软件键盘不弹，XCUITest 因此判定为没有焦点。跟 App 没有关系。

```bash
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
```

用例本身也写了重试（点一次、等 1 秒、读一次 `hasKeyboardFocus`，最多三次），
并把每次的焦点状态打进日志——换台机器也能一眼看出是哪一类失败。

## 二·六、用「像素亮度」断言颜色

颜色**不在可访问性树里**，`XCUIElement` 断言不了「这块卡片是深色还是浅色」。
`LayoutAndAppearanceUITests` 里的做法是读截图：

```swift
// 把截图里某个矩形缩成 1×1 像素，取平均亮度 0.299R + 0.587G + 0.114B
func averageLuminance(_ shot: XCUIScreenshot, in rect: CGRect) -> CGFloat
```

实测基准：深色卡片 ≈ `0.17`，浅色 ≈ `0.95 ~ 1.00`。
**全黑 `0.00` 是「模拟器没渲染出来」的信号**（连状态栏都是 0），不是真的黑——
所以 `measure()` 会重拍最多 4 次，仍然全黑就 `XCTSkip` 而不是判红。

`testAppearanceSwitchAppliesToPresentedSettingsSheet` 就是靠这个抓到
「深色改回浅色回不去」那个 bug 的：修之前量到「深 `0.173` → 切浅**仍** `0.173`」。
断言本身要有余量（这里用 `> 0.5` 判浅、`< 0.5` 判深），别去比具体数值。

## 二·七、负对照别点在屏幕正中

「点空白处不该有反应」这类负对照，**不要点屏幕正中**：
App 启动时会把当前位置自动选成选点，蓝点就落在约 `(0.5, 0.30)` 处，
点在它上面坐标会**逐位相同**，于是用例假失败。

`MapControlsUITests.testBottomPanelDoesNotLeakTapsToMap` 改成在 5 个地图空处
落点轮流试（`(0.22,0.42)` / `(0.80,0.38)` / `(0.20,0.58)` / `(0.68,0.55)` /
`(0.35,0.25)`），每点一次等 2 秒再读坐标；5 个点全不动说明「地图当前还不可
交互、合成点击被吞了」，这时 `XCTSkip`（防穿透的断言前面已经跑过了）。

同理，推 sheet 这类操作也可能比等待慢：`LayoutAndAppearanceUITests` 里点
「设置」第一次没推出就重点一次，两次都不行才 `XCTSkip`。

## 二·八、跑不通的功能，用 DEBUG 启动参数注入

引导弹窗只在「开启虚拟定位成功」之后才弹，而模拟器上开虚拟定位要 Wi-Fi 代理
加上证书信任，会先弹「证书尚未被信任」，端到端跑不起来。硬测的结果就是这条
用例常年 `XCTSkip`，等于没测。

所以 `MapHomeView` 里留了**只在 `#if UI_TEST_HOOKS` 编译**的注入口
（`applyUITestLaunchArguments`），两个启动参数分工不同：

| 参数 | 行为 | 谁在用 |
|---|---|---|
| `-uiTestResetGuideAndShow` | 先把「不再提示」开关**重置**，再显示弹窗 | 每条用例的第一段 |
| `-uiTestShowGuideIfNeeded` | **不重置**，按持久化状态决定弹不弹 | 验证「重启后不再弹」 |

两个是分开的，就是为了能在一轮里把「弹出来 → 点不再提示 → 重启不再弹」
串起来测：第二段如果也用第一个参数，重置会把 `false` 又写回 `true`，
永远测不出持久化。用例见
`MapControlsUITests.testSpoofGuideShowsAndRemembersDismissal`。

**前提：Debug 配置要定义 `UI_TEST_HOOKS` 编译条件**（`project.yml` 的
`settings.configs.Debug.SWIFT_ACTIVE_COMPILATION_CONDITIONS`）。XcodeGen 不会
像 Xcode 新建工程模板那样自动补编译条件，缺了它 `#if` 里的代码**静默编不进去、
编译还不报错** —— 表现就是「启动参数传了但弹窗没出来」。1.0.13 之前这个条件
一直是缺的，注入用例因此必然失败。

**为什么不直接用 `DEBUG`**：`#Preview`（ContentView / SpoofGuideOverlay）包在
`#if DEBUG` 里，而 `#Preview` 宏要 `swift-plugin-server` 展开；在受限环境
（沙箱 / CI）里插件进程起不来，一开 `DEBUG` 就是每次 Debug 编译都报
`PreviewsMacros.SwiftUIView could not be found`。所以用一个只服务于界面测试的
条件，绕开 `#Preview` 那摊。

## 二·九、底部卡片尺寸怎么量

`LayoutAndAppearanceUITests.testBottomPanelFloatsWith12ptInset`：卡片本身不在
可访问性树里（SwiftUI 把纯布局容器摊平成 `Other`），所以它**自己挂了一个
Debug 专供的可访问性容器**：

```swift
// App/MapHomeView.swift（#if UI_TEST_HOOKS）
.mapGlassSurface(cornerRadius: GlassMetrics.mapPanelCornerRadius)
.uiTestPanelProbe()          // accessibilityElement(children: .contain) + identifier
.padding(.horizontal, GlassMetrics.mapPanelEdgeInset)
```

探针挂在**外层留边之前**，所以它报出来的 frame 就是卡片本体：

```swift
let card = app.otherElements["uiTestBottomPanel"].frame
XCTAssertEqual(card.minX, 12, accuracy: 1.5)                       // 左
XCTAssertEqual(screen.width - card.maxX, 12, accuracy: 1.5)        // 右
XCTAssertEqual(screen.height - card.maxY, 12, accuracy: 1.5)       // 下
```

`children: .contain` 只是把这一块包成容器，里面的按钮照旧各自可点可查。
Release 产物里这个修饰器是**恒等变换**（`#else` 分支），可访问性树一个节点都不多。

**1.0.14 之前这里是「反推」的，而且推错了。** 当时只能从「卡片里那颗占满
整行的主按钮」往外加一圈「内容留边」，那圈留边 = 卡片圆角 − 23、卡片圆角 =
屏幕圆角 − 12。而**测试进程读不到屏幕圆角**：`UIScreen._displayCornerRadius`
在那里取到 0，会退到 55 的兜底（App 侧同机型读到的是 62），算出来比真值小
7pt —— iPhone Air 上量出 `19` 而不是 `12`，是**量具**错了，不是卡片错了。
所以在测试里复刻 App 的式子这条路是走不通的，改成直接量卡片。

主按钮仍拿来找「内容留边左右是否一致」：卡片内容留边 = 卡片圆角 − 23，跟屏幕
圆角走，16 Pro Max 是 27、15/16 是 20，所以只钉 `≥ 20（下限）` 与「左右相等」
—— 这两条正是「跟卡片同心」的前提。下边不直接量（已由上面的 `card.maxY` 钉死），
另钉一条「主按钮完全躲开 Home 指示条那 34pt」：`屏幕高 - 主按钮.maxY ≥ 34`
（= 卡片下边距 12 + 内容下边距；留边取下限 20 时正好顶到安全区 − 12 那条线）。
浮标的位置（卡片正上方、贴右侧）同理用 `图层` / `实时位置` 两颗按钮的 frame
与 `card.minY` 断言。

图层菜单那条（`MapControlsUITests.testLayerButtonOpensMenuAndSwitchesMapType`）
还按 frame 钉了**形态**：三个选项都在图层浮标**上方**、竖排一列 —— 1.0.14 之前
是向左弹出的横向卡片，用户嫌「往左有点丑」。

这条也顺带钉住了**安全区高度必须读对**：`bottomPanelContentInset` 读成 0 时
（SwiftUI 的 `GeometryReader` 在 ignore 过安全区的视图里恒返回 0，
见 `MapHomeView.refreshBottomSafeInset`），主按钮离下沿只剩 26pt，
这条断言立刻变红。

## 三、写完的新用例放哪

`Tests/FlocUITests/*.swift`。注意 `Tests/check_swift_sources.py` 的
「测试类型引用」那一项**只扫 `Tests/FlocTests`**，界面测试里引用项目内类型
不会被它校验——所以这里的代码风格要自己把关。
