# 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> 1.0.5 ~ 1.0.9 的详细记录见各版本的 `dist/RELEASE_NOTES_v*.md`（出包时会一并
> 归档到 `~/Desktop/Floc 发布包/<口味>/`），本文件从 1.0.10 起继续维护。

## [1.0.12] - 2026-10-09

把 1.0.11 之后用户实拍反馈的 5 件事全部做完：新增虚拟定位「生效检测」、
修掉「深色切不回浅色」、底部面板改成贴底三面齐平、设置页账号面板跟随主题、
把全项目散着的 11 档圆角收敛成 4 档。

### 新增：虚拟定位「生效检测」

- 点「开启虚拟定位」后去系统设置关开定位服务，回到 App 会自己检测到并提示
  「已生效」。新增 `Shared/SpoofEffectVerifier.swift`：
  `idle / verifying / effective(verifiedAt) / ineffective(reason)`
- 判据**不是**问系统「定位服务开着吗」（那个永远返回开着），而是**回读本机
  真实定位与目标点比距离**，阈值 **80 米**——移动模拟最大 20 米抖动 + 系统取整，
  阈值再小会把「其实已经生效」判成失败
- 读取必须走 `RealLocationProvider.forceFresh` **绕开 60 秒定位缓存**，
  否则拿到的是开虚拟定位之前的旧坐标，永远显示「未生效」
- 比对用的目标点必须与地图**同源**：`pair.coordinate(for:
  state.mapCoordinateSystem)`，否则境内会被 GCJ-02 偏移量骗过去
- 默认轮询 10 次 × 3 秒；`stopSpoofing` 开头 `verifier.reset()`，
  不把上一轮结果留在界面上。配套 12 条单测

### 修复

- **深色改回浅色回不去，必须退出设置页重进**。两层原因，缺一层都修不好：
  (a) `.preferredColorScheme` 挂在 `WindowGroup` 根节点**管不到已经弹出去的
  sheet**，而设置页正是 sheet；(b) 只写 `UIWindow.overrideUserInterfaceStyle`
  **仍然不够**——SwiftUI 弹 sheet 时会给那个**视图控制器**单独写一份 override，
  而**视图控制器的优先级高于窗口**。新增
  `Shared/WindowAppearanceBridge.swift`，把窗口 + **整棵视图控制器树**
  （`children` 顺着 `presentedViewController` 一起走）都写一遍
- 这条 bug 的定位靠**像素亮度**：颜色不在可访问性树里断言不了，改用
  `CGContext` 把截图里设置页卡片那块区域缩成 1×1 像素读平均亮度
  （深色 ≈ 0.17 / 浅色 ≈ 0.95~1.00）。修前量到「深 `0.173` → 切浅**仍**
  `0.173`」，修后 `1.0 / 0.173 / 1.0`

### 调整

- **底部面板贴底三面齐平（对齐 Apple 地图）**。原因是给面板加**负 padding
  只影响绘制，不会扩大父视图的布局区与命中区**。改法：外层
  `.ignoresSafeArea(edges: .bottom)` + 量真实安全区（`Color.clear` +
  `GeometryReader` + `allowsHitTesting(false)`）+ 内容侧
  `.padding(.bottom, 安全区 + 8)`；面板形状换成自建 `MapBottomSheetShape`
  （**只有上沿两个角是圆的**，下沿直角；不用 `UnevenRoundedRectangle`，
  那是 iOS 16+）。`mapPanelCornerRadius` 顺带从 34 收到 20——面板贴底后只有
  两个角可见，当年「又宽又高所以要 34」的理由不成立了，正好与地图浮层同档
- **设置页账号面板跟随配色主题**：那一组的 `listRowBackground` 换成
  `ThemedGroupedCardBackground()`（主题色 0.22 淡填充）；未选主题时
  （「跟随系统」）仍是原来的系统分组底色
- **圆角收敛成四档**：全项目原来散着 11 个数值（4 / 9 / 10 / 12 / 13 / 14 /
  15.5 / 16 / 18 / 20 / 28），相邻两档差 1~2pt，肉眼分不出、代码里却在
  「改一处漏一处」。按语义收进 `GlassMetrics`：
  `inlineCornerRadius = 10`（收 4/9/10）、`cardCornerRadius = 16`
  （收 12/13/14/15.5/16/18）、`mapCornerRadius = 20`、`heroCornerRadius = 28`。
  卡片档取 16 是因为它夹在中间：玻璃卡片本来就 16 **一处不动**，
  14 只往圆挪 2pt、18 往方 2pt，两边视觉位移都最小。
  `mapPanelCornerRadius` 改成 `mapCornerRadius` 的**别名**（两个名字一个值），
  将来面板与浮层要拆开只改定义那一行
- 新增 `Tests/check_swift_sources.py` **第 10 项** `check_corner_radius_ladder`：
  四档的值必须是约定值、面板档必须挂在浮层档上、`App/` 与 `Shared/` 下除
  `GlassCard.swift` 外不得出现 `cornerRadius: <数字>`。负向测试过（塞一句
  `cornerRadius: 7` 立刻判红）。Swift 源码一致性检查因此从 9 项扩到 10 项

### 修复（测试）

- **修掉三语里重复定义的 `未验证` / `已生效`**：这两条早被「连接状态」胶囊
  用掉了，新加的校验文案又定义了一遍，`check_localization.py` 会拦下
  （en 里还撞出两种译法 `Unverified` / `Not verified`、`Active` / `In effect`）。
  改为复用前面的定义
- **两处界面测试的「模拟器偶发」不再判红**：
  (a) `XCUIScreenshot` 偶发返回全黑图 → `measure()` 重拍 4 次，仍全黑则
  `XCTSkip`；(b) 地图可交互之前的合成点击会被吞掉，负对照从「点屏幕正中」
  （App 启动会把当前位置自动选成选点，正好点在蓝点上 → 假失败）改成
  5 个地图空处落点轮流试、每次等 2 秒，全不动则 `XCTSkip`

### 重新生成

- **「仅内置代理」补丁**：本轮改了 5 个补丁覆盖到的文件（DiagnosticsView /
  ModeSelectionStep / ProxySetupStep / SettingsDetailViews / TipViews），补丁漂移。
  按三方合并重生成（ours = 新源码 / base = 打补丁前的旧源码 / theirs = 打了旧
  补丁的旧源码 → `git merge-file`）：16 个文件自动合并干净；`ProxySetupStep.swift`
  一处冲突（ours 在 `thirdPartyContent` 里改了圆角、theirs 把整段第三方 UI
  删掉）**按 theirs 解**；4 个在这一口味里被删除的文件按删除处理。
  实测跑过一遍 `git apply` → `xcodegen generate` → 编译 `BUILD SUCCEEDED`
  → `git apply -R` → 工作区干净

### 备注

- 远端 Release 仍停在 **v1.0.2**（1.0.3 起都只出了本地包），要不要发版等用户拍板
- 上一版遗留的两件待办仍未动：引导第一步「选择运行模式」的两张卡片是否统一成
  玻璃；第三方代理在真机上改不了位置（需真机环境）

## [1.0.11] - 2026-10-09

加上六套主题配色，并把 1.0.10 的液态玻璃修到真正有「Q 弹」手感。
**默认「跟随系统」，没挑过主题的用户外观与 1.0.10 完全一致。**

### 主题配色（新增）

- 新增 `Shared/ThemePalette.swift`（调色板 + `ThemeCatalog` 六套 + `Color(hex:)`）
  与 `Shared/ThemeStore.swift`（存储 + `ThemedBackground` + `\.themeAccent` 环境值）
- 六套色值直接取参考图的十六进制：玫红雪白 / 薄荷孔雀绿 / 夜紫橙金 /
  湖蓝淡粉 / 荧光水绿 / 电光蓝紫；`accentHex` 另给一个略深的值——原色在白色
  玻璃上做文字色对比度不够
- 落地位置：根节点 `.tint`、欢迎页（渐变背景 + 图标块 + 主按钮 + 指示点）、
  引导页背景、地图浮层玻璃染色、底部面板胶囊填充
- 设置页「外观及个性化」新增「配色主题」入口 → `ColorThemeSettingsView`
  （预览卡 + 7 个色卡，点一下即时生效）
- 主题按 **id 字符串**存盘，以后插入新主题不会让老用户的选择串位
- **踩坑：`Color.accentColor` 不跟 `.tint()`**。`EnvironmentValues.accentColor`
  在 SDK 里是 `package`，外部写不了。最后自建 `\.themeAccent` 环境值，
  根节点 `.tint` + `.environment` 两条都给，并把 17 处 `Color.accentColor`
  改成读环境值（用环境值而非 `ThemeStore.shared.accent`：后者不会让
  `GlassSegmentButton` 这种叶子视图重新求值）

### 液态玻璃做成「Q 弹」

- **玻璃加 `.interactive()`**：1.0.10 只写了 `.glassEffect`，那是静态折射材质，
  按下去毫无反应。`Glass.regular.interactive()` 才是触摸响应的来源
- **面板内胶囊修回可见**：1.0.10 把它降级成 `Color.primary.opacity(0.08)` 的淡灰
  且无描边，在玻璃上几乎看不见（用户反馈的「设置都点不亮」）。现在改成
  「主题色渐变填充 + 1pt 白色亮边」
- 新增 `glassPressEffect()`：按下缩到 0.94~0.96、`spring(response: 0.26,
  dampingFraction: 0.6)` 弹回。用 `ButtonStyle` 实现，避免和长按手势抢事件。
  **iOS 15 ~ 18 也生效**——这是交互反馈，不是液态玻璃外观
- 设置按钮补 `contentShape`：玻璃本身没有 hit area，原来只有图标那几个像素
  是热的

### 修用户实拍反馈的 4 个问题

- **选点与实际落点差数百米（坐标体系判错）** —— 最严重的一个。
  `probeCoordinateSystem()` 拿天安门当锚点推断地图用哪套坐标，但锚点用的是
  **高德给天安门返回的 GCJ-02 数值** `116.397499, 39.908722`（百度百科「逆地理
  信息」词条原文那对数字），却当成了 WGS-84 传进去 —— 文档里写的
  「反算出对应的 WGS-84 坐标」那一步漏了。两个候选落点因此几乎重合在「高德
  那个点」上，**境内设备被恒定判成 WGS-84**，每个选点写进定位服务的坐标都差
  一个 GCJ 偏移（约 500 米），而界面上的选点标记仍然落在手指按下的地方
  （它用的是同一个错误值，自洽），所以看起来「选点没错、就是定位偏了」。
  改法：**不再让探测决定坐标怎么解释**。新增
  `CoordinateConverter.mapSystem(latitude:longitude:)`，按「点落在哪个区域」
  分流（境内 GCJ-02 / 境外 WGS-84，且换算在境外是恒等），地图点选、搜索结果、
  实时定位三处统一走它；`inferSystem` 只保留「确认 + 留痕」，
  判定与区域判据矛盾时直接作废并记一条 warn 日志
  （新增 `SystemProbe.contradictsRegion` / `separation`，`isConclusive` 也要求
  偏向幅度超过候选间距的四成，不再只是「两个距离不相等」）
- **地图浮层的空白处会穿透到地图变成选点**（用户：「搜索框的 X 也点不了，
  点一下竟然是地图选点」「开启虚拟定位按钮那一大块面板也会穿透然后选点」）——
  玻璃只用 `.background` 画了个底，**不扩大命中区域**，浮层上除了真正控件以外
  全是洞。三个玻璃入口统一补 `.contentShape(shape)`
- **「设置」很难点进去**：图标 42×42 提到 44×44（iOS 最小可靠触摸尺寸），
  并显式给整块定形
- **搜索框的「清空」按钮点不到**：图标触摸目标放大到 32×32 并加无障碍标签
  「清空」（原来图标本身只有约 20pt，也没有标签，界面测试都找不到它）

### 测试

- **新增界面（UI）测试目标 `Tests/FlocUITests`**：点「设置」断言设置面板出现、
  点搜索框的「清空」断言输入被清掉、点底部面板的留白断言不会穿透成选点
  （含一个「地图点击必须能选出点」的负对照，防止假通过），每步截图钉进报告。
  跑法见 `Tests/README-ui-tests.md`（模拟器没准备过时 `XCTSkip`，不会卡死出包流程）
- 坐标系单测补 6 例：锚点必须是**真 WGS-84**（回归锁，写错立刻红）、
  区域判据、探测接受 GCJ-02 / 拒绝境内的 WGS-84 判定 / 落点居中时不采信 /
  境外锚点两套候选重合测不出东西
- 本地化新增 10 条主题文案，共 **432 条 × 3 语**

## [1.0.10] - 2026-10-09

iOS 26 及以上换成系统「液态玻璃」，iOS 15 ~ 18 维持原样；修掉 5 个用户反馈的问题。

### 液态玻璃（Liquid Glass）

- 用 Xcode 26.3（自带的 iOS 26 SDK）编译。**开关是编译时的 SDK，不是运行系统版本**：
  同一个二进制在 iOS 26+ 自动换皮、在 15 ~ 18 保持旧外观，
  `project.yml` 的 `deploymentTarget` 仍是 **iOS 15.0**，没有提高
- 改动只落在 `Shared/GlassCard.swift` 的 **3 个入口**（`glassCard()` /
  `mapGlassSurface()` / `mapGlassCapsule()`）：iOS 26 走 `glassEffect`，
  老系统走原来的 Material 手工模拟（**逐字保留**，观感零漂移）
- **液态玻璃不能嵌套**：底部面板内部的胶囊一开始也套了玻璃，结果被外层吃掉、
  按钮底色整块消失。改由 `mapGlassCapsule(nested:)` 的 `nested` 参数区分——
  贴玻璃的那一档在 iOS 26 上退回淡色填充
- 新增 `Tests/check_swift_sources.py` **第 9 项**：玻璃 API 只能出现在
  `Shared/GlassCard.swift` 的 `if #available(iOS 26, *)` 块内，且最低版本必须
  仍是 15.0。已做负向测试确认能拦住越界写法

### 修复

- **蜂窝网络下仍显示 Wi-Fi 可用、还能开虚拟定位**：`NWPathMonitor` 原来指定了
  `requiredInterfaceType: .wifi`，**根本看不到蜂窝路径**，区分不了「没连 Wi-Fi」
  和「在用蜂窝」；且回调只在状态变化时触发，冷启动走蜂窝时一次都不来。
  改为不限接口类型的监听 + `NetworkTransport`（wifi / cellular / other）判定
  + 每次都回调 + 冷启动主动拉一次；**只有 `.cellular` 拦截**（`.other` 放行，
  误拦的代价是功能直接不可用）。蜂窝下开启会被拦下并提示，状态行同步换成
  「未连接 Wi-Fi」，设置页新增「当前接入方式」一行
- **「实时位置」反应慢**：原来每次都 `requestLocation()` 等 GPS 解算，
  改为优先采用 60 秒内的系统缓存位置
- **「实时位置」不放大**：推翻 1.0.6 起「只平移不缩放」的取舍，改回缩放到街道尺度
- **刚装好不自动弹定位授权**：欢迎页 / 权限页出现时自动请求一次
  （请求前复查 `notDetermined`；静态持有 manager，防弹窗未响应时被释放）
- **搜索结果列表显示不完整**：`VStack` + `.frame(maxHeight:)` **不产生滚动**，
  超出部分被裁且点不到。改成 `ScrollView` + 量高取 `min(内容高度, 280)`

### 备注

- 引导第一步「选择运行模式」的两张卡仍是系统分组列表样式
  （`secondarySystemGroupedBackground`），未改成玻璃 —— 理由见
  `dist/RELEASE_NOTES_v1.0.10.md`
- 「第三方代理改不了位置」这条**仍未定位**：托管与改写链路均已排除，
  缺真机环境，已向用户索取三条排查信息

## [1.0.4] - 2026-10-07

设置页重构为五个分组、新增账号体系与外观个性化；修复「未部署授权服务端
时连开发者都无法自测」的死锁。

### 未配置授权服务端时进入「本地模式」

- **问题**：`LicenseConfig.baseURL` 还是占位符，而 `LicenseStatus` 默认
  `.unregistered`、`isUsable == false`，`MapHomeView.toggleSpoofing()`
  的授权闸门会把「开启虚拟定位」直接拦掉；后端又不存在，卡密无处激活——
  全新安装连自测都做不了
- **改法**：新增 `LicenseConfig.isConfigured` 检测占位符。未配置时
  `LicenseManager` 进入本地模式：不发任何授权请求（省掉每次启动 12 秒
  超时和一条「网络异常」）、`isUsable` 直接放行、状态名显示「本地模式」
  而不是红锁「未激活」
- 把 `baseURL` 换成真实域名后校验与闸门**自动恢复**，不需要改其他代码；
  设置页「账号」分组会明说当前处于本地模式

### 设置页重构

- 从「一长条分组」改为五组：**账号 / 运行模式 / 连接状态 /
  外观及个性化 / 关于**
- **账号**（新增）：头像 + 昵称（二级页可改，头像存 App Group 容器、
  自动缩到 512px）、设备码 + 授权状态胶囊、剩余时间（精确到
  `3 天 3 小时 12 分钟`）+「升级套餐」入口
- **运行模式**：从单选行改为二级页点选，行尾带当前模式
- **连接状态**：本机代理开关 / 第三方代理状态、虚拟定位状态，下面四个
  二级入口——证书与环境、第三方代理、定位模拟、收藏位置
- **外观及个性化**：主题（跟随系统 / 浅色 / 深色）分段控件、
  语言（二级页三选一）、**字体大小**（小 / 标准 / 大，新增）
- **关于**：关于 Floc（版本、构建号、内核版本、工作原理、重置引导流程）、
  用户指南（使用方法 + 生效/失效说明 + 工作原理）、意见反馈（问题报告 +
  运行日志与诊断 + 联系我们）、联系我们

### 新增

- `Shared/ProfileStore.swift`：昵称 + 头像（落盘在 App Group 容器，
  不塞进 UserDefaults）
- `Shared/FontScaleStore.swift`：字号三档。同时挂在根节点的
  `.environment(\.sizeCategory, ...)` 和 `SettingsMetrics` 的固定字号上——
  只挂一处的话设置页自己那套 `.system(size:)` 不会跟着变，看起来就像
  开关没生效
- `Shared/AppContact.swift`：联系方式配置（邮箱 / 微信 / 反馈地址）。
  **空着的项界面上不显示**，所以没确定就留空，不用担心露出占位符；
  但发布前至少要填一项，否则用户想买卡找不到人

### 修复 Wi-Fi 一键跳转

- 原来只走 `App-Prefs:root=WIFI`，跳不过去时会静默回退到应用自己的设置页，
  表现成「点了跳到别的页面」。`Info.plist` 补上 `prefs` scheme，
  并把**手动路径直接写在界面上**
- 如实说明：iOS 没有公开 API 能跳到「无线局域网 → 当前网络 → 配置代理」
  那一屏，最多只能到 Wi-Fi 列表，剩下两下要用户自己点

### 地图页

- 精度选择器从独立一行移到两行坐标最右侧，底部面板少一行高度
- 开启虚拟定位成功后提示「关掉定位服务总开关，等 5–10 秒再打开，
  一次不行就多试几次」，并给一键跳转「定位服务」的按钮（每次启动最多提示一次）

### 本地化

- 三语各 409 条，key 完全一致（1.0.3 的 339 + 本轮 70）
- 补回 1.0.3 遗漏在 `generate_localizations.py` EN 表之外的 37 条映射——
  此前脚本一跑就报「缺少英文翻译」，只能手工改 `en.lproj`，很容易两边漏改

### 测试与检查

- 新增 `LicenseLocalModeTests`（本地模式契约 + 剩余时长文案边界）、
  `FontScaleTests`、`ProfileStoreTests`、`DeviceIdentityTests`
- `Tests/check_swift_sources.py` 修两个假失败：类型收集改用 `rglob`
  （`Shared/License/` 这类子目录此前整块被漏掉），类型引用匹配前先摘掉
  字符串与注释（域名里的 `XXX.workers.dev` 会被误判成类型名）

## [1.0.3] - 2026-10-07

修复 Quantumult X 模块不生效与内置代理状态误判；地图页 UI 重排；
新增卡密与推荐系统。

### 地图页

- 图层三连从左上角移到右下角，竖排保持
- GCJ-02 / WGS-84 两行末尾各加复制图标，删掉原来单独一行的两个「复制坐标」按钮
- 收藏星标移到地名正后方

### Quantumult X 模块不生效

- **根因**：QX 的 `script-echo-response` 要求脚本顶层返回
  `status` / `headers` / `body`，且 `status` 必须是完整的
  `"HTTP/1.1 200 OK"` 字符串；其他客户端用的是 `{ response: {...} }`
- `wloc-settings.js` 的 `respond()` 按客户端分派，回归用例 16 → 18

### 内置代理误报「跳过」

- **根因**：`ProxyManager.status` 是自维护状态，进程被挂起时 Go 侧监听
  socket 已失效但进程没退出，`status` 不会变成 `.stopped`，环境检测把
  「代理其实已死」当成「在跑」
- 新增 Go `isProxyListening()`（实测 dial `127.0.0.1:8888`）+ 导出
  `locationcore_isproxylistening` + Swift 封装 `syncStatusWithReality()`，
  三处调用点改为先实测

### 新增卡密与推荐系统

- `Shared/License/`：`LicenseConfig` / `LicenseModels` / `DeviceIdentity` /
  `LicenseAPI` / `LicenseManager` / `LicenseViews`
- 设备 ID 存 Keychain（重装不换），3 天离线宽限；授权闸门只在「要开启」时拦
- 授权卡片 + 激活弹窗 + 推荐页（六档进度、累进发放、3 年封顶）

### 兼容性

- `LicenseViews.swift` 原本用了 `NavigationStack`（iOS 16+），工程
  deploymentTarget 是 15.0，Release 直接编译失败；改为 `NavigationView`，
  与工程其余 5 处保持一致

## [1.0.2] - 2026-10-07

界面精修 + 修复 Quantumult X 模块无法导入 + 新增打包前的模块联通性检查。

### 品牌与版本号

- **桌面显示名恢复为 `Floc`（不带版本号）**。1.0.1 曾把版本号拼进显示名
  （`Floc 1.0.1`），但显示名应保持稳定；版本号改由 **IPA 文件名**和
  **App 内「设置 → 关于 → 应用版本」**体现。`Tests/check_branding.py`
  已改为「显示名必须是裸 `Floc`」，并继续禁止 `InfoPlist.strings` 里出现
  `CFBundleDisplayName`（该键优先级更高，会把主 `Info.plist` 的值盖掉）

### 修复 Quantumult X 模块「配置失败、未生效」

- **根因**：`wloc.conf` 写成了 **主配置格式**（带 `[rewrite_local]` /
  `[mitm]` 段名），而 Quantumult X 的「远程重写资源」是**另一种格式**——
  裸规则列表（可选 `hostname = ...` 行 + 若干规则），注释用 `;` 而非 `#`，
  不能出现任何段名。格式不对会被 QX 直接拒绝导入
- 重写 `ThirdParty/ProxyScripts/modules/wloc.conf` 为正确的重写资源格式
- `Tests/check_proxy_modules.py` 新增 `check_quantumultx_format()`：
  禁止段名、要求 `hostname =` 声明、禁止 `#` 注释、恰好 2 条规则
- 模块 `README.md` 补充「Quantumult X 特别注意」：两种格式对照表 + 4 步导入流程

### 打包前新增模块联通性检查

- 新增 `Tests/check_module_reachability.py`（约 330 行），作为 `build.sh`
  的第 7 项静态检查，**打包前必跑**：
  - 本地：7 个模块/脚本文件存在；模块内 raw 地址指向真实文件；
    URL 仓库与 `git remote origin` 一致；配置地址同源
  - 联网：远端 200 且非空；**远端内容与本地逐字节比对**——本地改了没推，
    会明确报「内容漂移」，避免用户导入到旧版本
  - 离线时用 `SKIP_MODULE_REACHABILITY=1` 跳过；`--offline` / `--allow-drift`
    为脚本级开关

### 地图页

- **初始地图样式为「标准」**，初始缩放与「点实时位置」都收敛到 **200 米**比例
- **玻璃浮层提高不透明度**：新增 `MapGlassSurfaceModifier`
  （`regularMaterial` + `systemBackground` 0.55 叠色），比原来的
  `glassCard` 更实，文字不再被地图背景干扰
- 设置入口图标由 `ellipsis` 改为**齿轮**（`gearshape`）
- 「开启虚拟定位 / 实时位置」两个按钮统一为 `.mapGlassSurface()` 材质，
  主按钮按下状态用 `spoofButtonTint` 着色（未选点=灰、已启用=红、待启用=强调色）
- 地图页横幅（开启成功 / 失败提示）改为**居中大圆角**卡片，圆角与地图浮层一致

### 设置页

- 行标题 17 → **16（regular）**、数值 16 → 15、副标题 13 → 12、
  分组头 15 → **13 semibold**、图标 36 → 30，整体更紧凑
- **新增「外观」分组**：横向分段选择 **跟随系统 / 白天 / 黑暗**，
  由 `AppearanceStore` 统一持久化（`appearanceMode`），App 根部
  `.preferredColorScheme` 生效
- **「说明」「工作原理」上移到「支持」分组之上**
- 「支持」分组新增 **「使用方法」** 入口（`UsageGuideView`），
  4 步图文步骤 + 注意事项卡片
- 新增 16 条三语文案（外观 / 显示模式 / 白天 / 黑暗 / 使用方法等）

### 定位偶发跳回真实位置

排查结论：

- **未在白名单的定位端点是主因之一**：Apple 会在一大批带编号的
  `gsp<N>-ssl*` / `gspe<N>-ssl*` 主机间轮换，静态枚举永远追不全。
  漏掉的那台会被 `OkConnect` 原样透传，系统直接拿到**真实坐标**。
  现在这类主机在开启虚拟定位时会被记进运行日志，不再无声无息
- **回前台自愈**：新增 `scenePhase` 处理，回到前台时实际探测一次代理是否
  还在监听（`status` 是自维护状态，进程被挂起时不会变成 `.stopped`），
  掉了就重新拉起，并顺带重新确认静音保活

### 已知问题

- iOS 挂起应用会连同进程内的代理一起挂起；静音保活是最主要的对抗手段，
  但仍可能被系统（低电量模式、音频会话被抢占）中断。回前台已能自动恢复

## [1.0.1] - 2026-10-07

界面重排 + 运动模拟做可用 + 扩大定位端点拦截范围，并引入每次出包自动递增的版本号。

### 地图页

- **地图样式切换移到左上角，改为纵向排列**（原来是右上角横向胶囊）
- **压缩「开启虚拟定位」区域高度**，主按钮改为 44pt 高的整行按钮
- **新增「实时位置」按钮**：单击跳回真实 GPS 位置，长按回到已选点
- **地图页所有浮层统一圆角与材质**（`GlassMetrics.mapCornerRadius` = 20pt +
  `.ultraThinMaterial` + 0.5pt 白色描边 + 10pt 阴影），与地图样式切换器完全一致

### 设置页

- 行标题字号 15 → **17（medium）**，数值 16，副标题 13；白色卡片行不再拥挤
- 分组头统一为 15pt semibold
- **「第三方代理」分组移到「状态」下面**
- **复制模块地址给出反馈**：绿色对勾 +「已复制到剪贴板」，2 秒后自动消失
- 分组结构本身保持不变

### 运动状态模拟（原先点击无反应）

- 改为可选项 **关闭 / 5 米 / 10 米 / 20 米**
- 语义是「原地抖动的半径」：在半径内按**面积均匀**采样（`r = R·√u`），
  而不是固定偏移，所以不会全挤在圆心
- 经度按 `cos(纬度)` 修正，极点附近有保护
- 三层都做取值收敛（Swift `MotionDriftOption`、JS `DRIFT_STEPS`、Go
  `normalizeMotionRadius`），非法值一律退化为「关闭」
- 持久化键 `spoofMotionSimulation` → `spoofMotionDriftRadius`

### 拦截更多 Apple 定位端点

- MITM 主机白名单 **5 → 14**，新增 `gsp10-ssl(.ls).apple.com`、
  `gsp64-ssl.ls.apple.com`、`gspe1/19/19-2/35/79/85-ssl.ls.apple.com`
- **刻意逐个枚举，不用通配符**——`*.apple.com` 会误伤大量非定位请求；
  并用单元测试锁死「不许出现通配符」
- 应用内代理与 6 个第三方客户端模块同步更新

### 实时位置

- 新增 `RealLocationProvider`：单次 `requestOnce` 取真实坐标，不持续定位
- 坐标按当前地图体系（WGS-84 / GCJ-02）转换后落点

### 构建与发布

- **每次出包版本号末位 +1**（`1.0.0` → `1.0.1`），并同步写进 App 显示名
  （`Floc 1.0.1`）与 IPA 文件名（`Floc-1.0.1-unsigned.ipa`）
  —— *（该「显示名带版本号」的做法在 1.0.2 已回退，显示名恒为 `Floc`）*
- 新增 `Scripts/bump-version.py`：`--bump` / `--set` / `--show-build` / `--set-build`
- `build.sh` 构建失败会同时回退 `MARKETING_VERSION` 与
  `CURRENT_PROJECT_VERSION`，不会凭空跳号
- 三语言 `InfoPlist.strings` 移除 `CFBundleDisplayName` 覆盖，
  否则会盖掉显示名（1.0.2 起显示名本身就是裸 `Floc`，该键依旧禁止出现）
- 不再删除 `build/DerivedData`（增量编译更快，Release 产物是覆盖写入的，
  不会拿到旧包）；需要全量重编用 `FULL_CLEAN=1 ./build.sh`
- `#Preview` 用 `#if DEBUG` 包起来，Release 出包不再依赖预览宏插件

### 缺陷修复

1. **运动模拟开关点了没反应**
   原实现只有开/关两态，`motionEnabled` 一路透传到 Go 侧，但 Go 里
   只在「响应中恰好存在运动状态字段」时才写入，实际几乎从不触发。
   **修复**：改为按半径抖动，主动改写坐标，不再依赖响应里有没有那个字段。

2. **失败构建会吃掉一个 build 号**
   回滚逻辑只还原 `MARKETING_VERSION`，`CURRENT_PROJECT_VERSION` 留在自增后的值。
   **修复**：回滚时两个号一起还原。

3. **显示名会被语言包盖掉**
   `InfoPlist.strings` 里的 `CFBundleDisplayName` 优先级高于主 `Info.plist`。
   **修复**：删除语言包中的该键，并在 `check_branding.py` 里禁止再次出现。
   （1.0.2 进一步把显示名固定为裸 `Floc`。）

### 测试

- **Go**：18 个用例（新增 `Core/drift_test.go`：半径收敛、抖动不越界、
  主机白名单覆盖与主机名归一化）
- **代理脚本**：16 个用例（原 11 个，新增漂移保存/回显、非法值拒绝、
  旧配置兼容、改写后仍在目标附近、关闭时坐标精确不变）
- **iOS**：106 个用例（原 94 个，新增运动档位、主机白名单、
  `drift` 参数契约等）
- **本地化**：简繁英各 279 条，键名完全对齐

---

## [1.0.0] - 初始版本

首个完整版本。功能覆盖两种代理模式、双坐标系、环境自检与诊断日志。

**标识信息**

| 项目 | 值 |
|---|---|
| 显示名 | Floc |
| Bundle ID | `com.fff.loc` |
| App Group | `group.com.fff.loc` |
| 根证书 CN | `Floc Root CA` |

### Go 核心（`Core/`）

**WLOC 响应改写引擎**
- 手写 protobuf 线格式编解码器（varint / fixed64 / length-delimited / fixed32）
- 改写位置条目的纬度（字段 1）、经度（字段 2）、精度（字段 3）
- 运动模拟：按需补充运动状态（字段 11）与置信度（字段 12）
- 按 MAC 地址格式识别 WiFi 设备条目
- 支持蜂窝基站数据段（字段 22 / 24）
- **未知字段按原始字节原样保留**，避免 iOS 拒绝响应
- 三种信封格式逐层降级：ARPC → marker（8 字节前缀 / 6 字节魔数）
  → 偏移扫描 → 裸载荷扫描
- 处理 gzip 压缩的响应体

**证书服务**
- 生成 RSA 2048 自签根证书（有效期 5 年）
- 动态签发叶子证书（有效期 397 天，符合 Apple 上限）
- 通过 HTTP 分发根证书（`/ca.cer`）
- 用签出的 loopback 叶子证书提供 HTTPS `/health` 探测端点，
  用于间接验证证书是否已被系统信任

**MITM 代理**
- 基于 `goproxy` 的 HTTPS 中间人代理，监听 8888
- 仅拦截定位相关域名，其他流量透明放行
- 一次性 token 回显机制，验证 Wi-Fi 代理链路是否生效
- 环形日志缓冲（保留 200 条）

**C 接口层**
- 18 个 `locationcore_*` 导出函数
- 用 `cgo.Handle` 管理 Go 侧长生命周期对象
- 句柄失效时用 `defer`/`recover` 兜底，避免崩溃

**测试**：11 个用例，覆盖坐标定点编码、varint 往返、畸形输入拒绝、
字段改写与未知字段保留、MAC 校验、marker 帧长度回填、运动字段、
gzip 处理、CA 生成解析、叶子证书签发、自检。

---

### Swift 逻辑层（`Shared/`）

**坐标系转换**
- WGS-84 ↔ GCJ-02 双向转换（Krasovsky 1940 椭球）
- GCJ-02 → WGS-84 用 3 次迭代逼近
- 境外坐标不做转换
- 双坐标并存存储，避免重复转换累积误差
- 通过天安门锚点自动探测地图所用坐标系

**代理管理**
- 本地代理生命周期管理（启动 / 停止 / 更新坐标）
- 证书信任验证（自签 loopback 请求探测）
- Wi-Fi 代理链路验证（百度回显 token）
- 6 种第三方客户端对接，各自模块格式与 URL Scheme
- 第三方客户端脚本接口（查询 / 保存 / 清除）

**其他**
- 证书持久化到 Keychain（`AfterFirstUnlockThisDeviceOnly`）
- 日志脱敏（坐标 / MAC / 长十六进制 / PEM 私钥 / URL 令牌）
- 日志保留 3 天，内存上限 500 条
- 后台保活（代码生成静音 WAV）
- 网络状态监听，Wi-Fi 变化时提示重设代理
- 收藏位置存储，上限 50 个
- 远端配置拉取（脚本版本 / 系统版本黑名单 / 公告）

---

### SwiftUI 界面（`App/`）

- **4 步引导**：模式选择 → 权限申请 → 代理配置 → 环境验证
- **主界面**：搜索（400ms 防抖）、地图选点（单击 / 长按）、收藏夹、
  双坐标卡片（可分别复制）、开关控制
- **设置页**：坐标系偏好、精度、运动模拟、语言、模式切换、模块链接
- **诊断页**：6 项环境自检 + 实时日志（2 秒刷新）
- **问题反馈**：生成脱敏报告，可复制 / 分享
- **提示卡片**：4 类上下文提示，带「不再显示」偏好

---

### 第三方代理脚本（`ThirdParty/ProxyScripts/`）

- `wloc.js`：响应改写脚本，能力探测式存储读取
- `wloc-settings.js`：配置接口脚本，处理查询 / 保存 / 清除
- 6 种客户端模块：Shadowrocket `.module`、Surge `.sgmodule`、
  QuantumultX `.conf`、Loon `.lpx`、Stash `.stoverride`、Egern `.yaml`
- **测试**：11 个用例，覆盖放行路径、坐标改写、长度前缀一致性、
  无效坐标拒绝、配置接口各动作

---

### 本地化

- 简体中文 / 繁体中文 / English 三语言
- 各 241 条字符串，键名完全对齐
- `Tests/check_localization.py` 校验语法与条目数一致性

---

### 修复记录

开发过程中发现并修复的缺陷：

1. **marker 帧伪匹配导致改写静默失败**
   6 字节魔数 `00 00 00 01 00 00` 恰好是 8 字节前缀 `00 01 00 00 00 01 00 00`
   的后 6 字节。只按魔数搜索会在偏移 2 处误匹配，把载荷前两字节读成长度。
   **修复**：先试 8 字节前缀，再回退魔数搜索。

2. **响应体被 UTF-8 重编码破坏**
   代理客户端给的是「二进制字符串」（每字符一字节），原实现对高位字符做
   UTF-8 编码，把 `0x92` 变成两字节，protobuf 结构直接损坏。
   **修复**：改为 `charCodeAt(i) & 0xff`，不做编码。

3. **`Number(null) === 0` 把定位静默改到 (0, 0)**
   配置里坐标缺失时 JSON 序列化为 `null`，`Number(null)` 得 0，
   被当成合法坐标，定位落到几内亚湾。
   **修复**：新增严格数值解析，`null` / `undefined` / 空串一律拒绝；
   同时保留 `0` 作为合法坐标（赤道 / 本初子午线）。

4. **未识别客户端下虚拟定位失效**
   原实现按客户端名字 `switch (ENV)` 分派存储 API，未列出的客户端
   ENV 返回 `'unknown'`，走进无匹配分支直接返回 `undefined`。
   **修复**：改为按 API 能力探测（`$prefs` → `$persistentStore` → `$rocket.settings`）。
