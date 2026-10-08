# 构建指南

本文档描述如何从源码构建 **Floc**（虚拟定位）并在 iPhone 上安装运行。

- 构建只支持 **macOS**：iOS 应用必须用 Apple 官方工具链编译，Linux / Windows 无法交叉编译。
- 出的是 **未签名 IPA**，需要用签名工具自签后才能安装到设备。

---

## 1. 环境准备

### 1.1 必需软件

| 软件 | 最低版本 | 安装方式 | 用途 |
|---|---|---|---|
| macOS | 13 (Ventura) | — | 构建宿主 |
| Xcode | 15.0 | App Store | iOS SDK 与编译器 |
| Xcode Command Line Tools | 随 Xcode | `xcode-select --install` | `xcodebuild` / `xcrun` |
| Go | 1.23 | `brew install go` | 编译定位改写核心 |
| XcodeGen | 2.38 | `brew install xcodegen` | 从 `project.yml` 生成工程 |
| Node.js | 22（可选） | `brew install node` | 跑授权服务端（Worker + D1）测试 |

安装完 Xcode 后，务必把命令行工具指向它：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version    # 应输出 Xcode 15.x 或更高
go version             # 应输出 go1.23 或更高
```

> **为什么需要 Go？** 定位改写核心（protobuf 解析、MITM 代理、证书签发）用 Go
> 实现，编译为 iOS 静态库 `libwloccore.a`，再通过 C 接口给 Swift 调用。

### 1.2 一次性安装

```bash
brew install go xcodegen node
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

---

## 2. 一键构建

```bash
cd Floc
chmod +x build.sh Scripts/*.sh     # 首次需要赋予执行权限
./build.sh
```

产物（**一次两个口味，共四个文件**）：

```
dist/Floc-1.0.1-unsigned.ipa           # 标准版：带卡密 / 授权 / 推荐
dist/Floc-1.0.1-纯净-unsigned.ipa      # 纯净版：没有卡密那套
dist/Floc-unsigned.ipa                 # 标准版固定名副本，发布链接引用这个
dist/Floc-纯净-unsigned.ipa            # 纯净版固定名副本
```

两个包是**同一个 App**：Bundle ID（`com.fff.loc`）与显示名（`Floc`）完全一样，
装一个会覆盖另一个，不共存。源码也只有一份，区别只在编译条件里有没有
`PURE_BUILD` —— 裁剪范围见 `Shared/BuildFlavor.swift`。

`./build.sh` 每次都会把 `MARKETING_VERSION` 末位 +1（`1.0.0` → `1.0.1`），
并写进 IPA 文件名，以及在 App 内的「设置 → 关于 → 应用版本」里显示
（纯净版会多一个「（纯净版）」后缀）。
桌面图标的显示名恒为 `Floc`，不随版本号变化——要区分多个自签构建，看 IPA
文件名或 App 内的版本号即可。构建失败会自动回退版本号，不会凭空跳号。

只想看版本号、不想构建：

```bash
python3 Scripts/bump-version.py            # 打印当前版本
python3 Scripts/bump-version.py --bump     # 手动自增
python3 Scripts/bump-version.py --set 2.0.0
```

同时跑单元测试：

```bash
./build.sh --test
```

> 编译缓存 `build/DerivedData` 会被保留以复用增量编译（Release 产物是覆盖写入的，
> 不会拿到旧包）。确实需要全量重编时用 `FULL_CLEAN=1 ./build.sh`。

---

## 3. 构建流程拆解

`./build.sh` 内部依次执行三步。任何一步都可以单独运行，便于排查问题。

### 3.1 编译 Go 核心

```bash
./Scripts/build-core.sh
```

对 `iphoneos`（真机 arm64）和 `iphonesimulator`（模拟器 arm64）各编译一次：

```
GOOS=ios GOARCH=arm64 CGO_ENABLED=1 \
  xcrun --sdk iphoneos clang ... \
  go build -buildmode=c-archive -o Core/build/iphoneos/libwloccore.a ./Core
```

输出：

```
Core/build/iphoneos/libwloccore.a
Core/build/iphoneos/locationcore.h
Core/build/iphonesimulator/libwloccore.a
Core/build/iphonesimulator/locationcore.h
```

`locationcore.h` 由 Go 的 cgo 自动生成，声明了所有 `locationcore_*` C 函数，
Swift 侧通过 `App/Floc-Bridging-Header.h` 引入。

> 修改 Go 代码后必须重新跑这一步，否则 Xcode 链接的还是旧静态库。

### 3.2 生成 Xcode 工程

```bash
xcodegen generate
```

根据 `project.yml` 生成 `Floc.xcodeproj`。

**`Floc.xcodeproj` 是生成物，不要手动改也不建议入库** —— 所有配置
都写在 `project.yml` 里。改了 `project.yml` 后重新跑 `xcodegen generate` 即可。

### 3.3 构建并打包 IPA

```bash
./Scripts/build-unsigned-ipa.sh
```

内部执行（两遍，第二遍多带一个编译条件）：

```bash
xcodebuild -project Floc.xcodeproj \
  -scheme Floc \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build

mkdir -p build/UnsignedIPA/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/Floc.app \
      build/UnsignedIPA/Payload/
cd build/UnsignedIPA && zip -qry ../../dist/Floc-"$VERSION"-unsigned.ipa Payload

# 纯净版：同样的命令，只多一个编译条件
xcodebuild ... \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PURE_BUILD' \
  build
# 再打包成 dist/Floc-"$VERSION"-纯净-unsigned.ipa
```

`VERSION` 由 `build.sh` 自增后通过环境变量传进来；单独跑这个脚本时
它会自己读一次当前版本号，所以也能用。

---

## 4. 用 Xcode 调试运行

想在 Xcode 里打断点调试，走这条路：

```bash
xcodegen generate
open Floc.xcodeproj
```

然后在 Xcode 中：

1. 选中 **Floc** target → **Signing & Capabilities**
2. 勾选 **Automatically manage signing**，选择你的 Apple ID 团队
3. 如果 App Group（`group.com.fff.loc`）报红，
   说明你的开发者账号没开这个能力 —— 见 [第 6 节](#6-常见问题)
4. 选择模拟器或真机，`⌘R` 运行

**用模拟器验证功能有个前提**：模拟器不支持系统级 Wi-Fi 代理，所以
「本地代理」模式在模拟器上无法完整验证。界面、坐标转换、收藏夹等功能可以正常测。

---

## 5. 安装到 iPhone

未签名 IPA 无法直接安装，需要自签。常见方案：

| 方案 | 说明 | 是否需要电脑 |
|---|---|---|
| **AltStore / SideStore** | 免费 Apple ID 签名，7 天有效期，可自动续签 | 需要（AltServer） |
| **Sideloadly** | 免费 Apple ID 签名，7 天有效期 | 需要 |
| **TrollStore** | 永久签名，仅支持特定 iOS 版本（14.0–16.6.1 等） | 不需要 |
| **爱思助手 / i4Tools** | 图形化自签工具 | 需要 |
| **付费开发者账号** | 1 年有效期，可装 100 台设备 | 需要 |

### 签名时必须保留的权限

App 依赖以下能力，自签时要确保它们在 provisioning profile 里被包含：

- **App Group**（`group.com.fff.loc`）—— 主 App 与扩展共享配置
- **Background Modes → Audio** —— 后台保活，代理才不会被杀
- **Wi-Fi Information**（`com.apple.developer.networking.wifi-info`）—— 读取当前 Wi-Fi 名

免费 Apple ID 签名的最大障碍就是 **App Group 不可用**，见第 6 节。

### 安装后第一次运行

1. 打开 App，按引导完成 4 步设置（模式选择 → 权限 → 代理配置 → 验证）
2. 授权「始终允许」定位权限
3. 本地代理模式下，需要去 **设置 → 无线局域网 → 当前网络 → 配置代理**，
   手动填 `127.0.0.1 : 8888`（App 内有引导页和跳转按钮）
4. 安装并信任根证书：**设置 → 通用 → VPN与设备管理** 安装描述文件，
   再去 **设置 → 通用 → 关于本机 → 证书信任设置** 打开完全信任
5. 回到 App 点「验证」，全绿即可开始使用

---

## 6. 常见问题

### `xcodegen: command not found`

```bash
brew install xcodegen
```

### `error: unable to find utility "xcodebuild"`

命令行工具没指向 Xcode：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### `ld: library not found for -llocationcore`

Go 静态库没编译，或者路径不对：

```bash
./Scripts/build-core.sh
ls Core/build/iphoneos/libwloccore.a     # 确认存在
```

如果 `libwloccore.a` 存在但仍报错，检查 `project.yml` 里的
`LIBRARY_SEARCH_PATHS` 是否指向 `$(PROJECT_DIR)/Core/build/$(PLATFORM_NAME)`。

### `App Group group.com.fff.loc is not available`

免费 Apple ID 不支持 App Group。三个选择：

1. **用付费开发者账号**（推荐，一次配好长期可用）
2. **删掉 App Group 依赖**：把 `Resources/Floc.entitlements` 里的
   `com.apple.security.application-groups` 整段删除，同时把
   `Shared/AppGroup.swift` 的 `AppGroup.defaults` 改成 `UserDefaults.standard`。
   代价是配置与收藏只在 App 进程内可见，不再跨进程共享。
3. **换 TrollStore** 安装，绕过签名限制

### `Signing for "Floc" requires a development team`

在 Xcode 里给 target 选一个 Team，或者命令行加：

```bash
xcodebuild ... DEVELOPMENT_TEAM=你的TeamID
```

### Go 编译报 `gcc: error: unrecognized command-line option '-arch'`

`CC` 没被正确指向 Xcode 的 clang。确认 `Scripts/build-core.sh` 里设置的
`CC="$(xcrun --sdk "$SDK" --find clang)"` 生效，并且已执行
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。

### 装好后定位没变

按顺序排查：

1. **App 内「验证」是否全绿** —— 有红项就先解决红项
2. **Wi-Fi 代理是否生效** —— 设置 → 无线局域网 → 当前网络，确认代理配置还在
   （iOS 在某些情况下会重置代理设置）
3. **证书是否被信任** —— 设置 → 通用 → 关于本机 → 证书信任设置
4. **代理进程是否还活着** —— 看 App 内「诊断」页的日志，或者看后台保活是否开着
5. **重启过手机** —— 重启后 Wi-Fi 代理配置会保留，但 App 进程被杀，
   需要重新打开 App 让代理跑起来

---

## 7. 改名与换 Bundle ID

项目当前使用：

| 项目 | 值 |
|---|---|
| 显示名 | `Floc`（三语言一致） |
| Bundle ID | `com.fff.loc` |
| App Group | `group.com.fff.loc` |
| 根证书 CN | `Floc Root CA` |

**如果只是发布，不需要改任何东西** —— 这些就是正式值。
下面这张表是给「以后想再改名」用的：

| 文件 | 需要改的字段 |
|---|---|
| `project.yml` | `name`、`bundleIdPrefix`、`targets.*.settings.PRODUCT_BUNDLE_IDENTIFIER` |
| `build.sh` | `APP_NAME` |
| `Scripts/build-unsigned-ipa.sh` | `APP_NAME` |
| `Resources/Info.plist` | `CFBundleDisplayName` |
| `Resources/Floc.entitlements` | 文件名 + `application-groups` 值 |
| `Shared/AppGroup.swift` | `identifier` |
| `Shared/CertificateAuthorityStore.swift` | `serviceName` |
| `Core/bridge.go` | `bundlePrefix` |
| `Core/proxy.go` | `caCommonName`、`caOrganization`、`leafCommonName` |
| `Resources/*.lproj/InfoPlist.strings` | 三个语言的显示名 |
| `Shared/AppRemoteConfiguration.swift` | 远端配置 URL |

改完跑一遍 `./build.sh --check`，再 `xcodegen generate` 构建。

> **注意**：`Bundle ID` 改了之后，原来装好的 App 需要**卸载重装**，
> 并且根证书也要**重新生成并重新信任**（证书 CN 跟着变了，
> iOS 里会变成两张证书，旧的记得删掉）。

### 关于远端配置地址

1.0.8 起只剩应用内代理，仓库里不再有需要在运行时被外部拉取的脚本或模块文件。
只剩下**一个**远端地址——`Resources/remote-config.json`，指向本仓库在
**jsDelivr**（GitHub 的 CDN 镜像）上的副本：

```
https://cdn.jsdelivr.net/gh/Lululu-0715/Floc@main/Resources/remote-config.json
```

它承担「不发版也能改行为」：Apple 改了 WLOC 协议导致拦截失效、或要挂一条公告时，
改这个 JSON 就够。拉不到不会崩（有本地缓存 + 默认值 + 静默降级）。

> **不要改回 `raw.githubusercontent.com`。** 它在国内基本不可用（DNS 污染、
> 无 CDN），而配置拉不到时的表现是**静默降级**：公告不弹、兼容性警示不显示，
> 日志里只有一行 debug。踩过一次同源的坑：模块脚本指向 raw，用户看到的是
> 「切出去一分钟左右自己恢复真实位置」——客户端到期后重新拉取失败。
>
> 代价是 jsDelivr 对分支（`@main`）的缓存最长 12 小时，**改完要等一阵子
> 手机上才会生效**（这也是让用户「改完马上验证」时容易误判的地方）。
>
> `Tests/check_branding.py` 把这条锁死了：`defaultConfigurationURL` 出现 raw
> 地址直接失败，`remote-config.json` 里出现已删除的 `moduleBaseURL` 字段也失败。

如果仓库迁移到其他账号，改 `Shared/AppRemoteConfiguration.swift` 里的
`defaultConfigurationURL` 一处即可，然后：

```bash
python3 Tests/check_branding.py       # 托管地址与仓库归属
```

> **前提**：仓库必须是**公开**的。jsDelivr 与 raw 对私有仓库都不提供服务，
> 指到私有仓库等于让远端配置永远停在缓存值（且不报错）。

---

## 8. 清理构建缓存

```bash
rm -rf build dist Core/build Floc.xcodeproj
# Xcode 派生数据（可选，清理后首次构建会慢）
rm -rf ~/Library/Developer/Xcode/DerivedData/Floc-*
```

---

## 9. 运行测试

### 一键自检（最快）

```bash
./build.sh --check
```

不需要 Xcode，依次跑 Go 测试、授权服务端测试、本地化校验、Swift 源码一致性、
品牌命名一致性五项。改完代码先跑这个，能拦住大部分低级问题：

```
==> 静态检查
    Go 核心测试通过
    授权服务端测试通过
    本地化校验通过
    Swift 源码一致性通过
    品牌命名一致性通过

静态检查全部通过。
```

> 五项都不需要联网。1.0.8 起只剩应用内代理，原来那三项围绕第三方模块的
> 检查（代理脚本测试 / 代理模块一致性 / 模块联通性）连同被检查的对象一起删除了。

`./build.sh` 和 `./build.sh --test` 在构建前也会自动跑一遍这些检查，
所以不必刻意先跑 `--check`。

### Go 核心测试

```bash
cd Core && go test ./... -v
```

覆盖：protobuf 编解码、坐标定点编码、位置条目改写、Wi-Fi 设备识别、
marker 帧长度回填、gzip 处理、CA 生成与解析、loopback 证书签发、自检。

### 授权服务端测试

```bash
cd Server/license-worker && npm test
```

需要 Node 22+（用内置的 `node:sqlite` 跑真实 SQLite，不引入任何第三方依赖，
所以克隆下来不装 `node_modules` 也能跑）。覆盖：卡密规范化、试用登记、
续费叠加、同卡重复激活不叠加、解绑限次、推荐绑定、连续使用判定、
阶梯补发与幂等、付费奖励只发一次、奖励封顶、路由与错误体。

`./build.sh --check` 里也会跑这一项；Node < 22 时自动跳过。
服务端的部署步骤见 `Server/license-worker/README.md`。

### iOS 单元测试

```bash
./build.sh --test
# 或指定模拟器
SIMULATOR_DESTINATION='platform=iOS Simulator,name=iPhone 16 Pro' ./build.sh --test
```

测试文件在 `Tests/FlocTests/`：

| 文件 | 覆盖内容 |
|---|---|
| `CoordinateConverterTests.swift` | 坐标系转换、往返一致性、地图体系探测 |
| `CoreBridgeTests.swift` | Go 静态库链接、证书签发与校验、token 机制 |
| `RedactorTests.swift` | 日志脱敏（坐标 / MAC / 密钥 / 令牌） |
| `FavoriteLocationStoreTests.swift` | 收藏夹增删改查、容量上限、持久化 |
| `ThirdPartyProxyClientTests.swift` | 客户端元数据、协议契约、URL 构造 |
| `AppLocalizationTests.swift` | 三语言切换、查表兜底、App Group 降级 |

### 本地化完整性检查

```bash
python3 Tests/check_localization.py
```

校验三种语言的 `.strings` 语法正确、条目数一致、键名对齐。三语言各 241 条。

### Swift 源码一致性检查

```bash
python3 Tests/check_swift_sources.py
```

在没有 Xcode 的环境（比如 CI 容器）里做力所能及的校验：

- 38 个 Swift 文件的括号 / 引号配平
- 桥接头声明与 Go 的 `//export` 函数逐一对齐（少一个就是链接错误）
- 测试中引用的类型确实存在（捕捉拼写错误）
- `project.yml` 引用的源目录存在
- 资源文件与三语言目录齐全

### 品牌命名一致性检查

```bash
python3 Tests/check_branding.py
```

改名是跨 15+ 个文件的活儿，漏改一处的后果很隐蔽：Bundle ID 与 App Group
不一致会导致配置写不进去；脚本 URL 与常量不一致会让用户导入模块后下载 404。
这个脚本把这些约定全部核对：

- `project.yml` 的 Bundle ID 与 `Core/bridge.go`、`AppGroup.swift`、
  `CertificateAuthorityStore.swift`、`entitlements`、测试断言一致
- `project.yml` 引用的桥接头 / entitlements / Info.plist 文件真实存在
- `build.sh` 与构建脚本的 `APP_NAME` 与工程名一致
- `@testable import` 指向正确的模块名
- 三语言显示名统一
- 远端配置 URL 不是 `raw.githubusercontent.com`，且 `remote-config.json`
  里没有指向已删除模块的 `moduleBaseURL` 字段
- 证书主题包含品牌名
- 代码里没有旧名称残留
