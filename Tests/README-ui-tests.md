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

## 三、写完的新用例放哪

`Tests/FlocUITests/*.swift`。注意 `Tests/check_swift_sources.py` 的
「测试类型引用」那一项**只扫 `Tests/FlocTests`**，界面测试里引用项目内类型
不会被它校验——所以这里的代码风格要自己把关。
