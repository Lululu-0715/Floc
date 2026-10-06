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
| Node.js | 18（可选） | `brew install node` | 跑第三方代理脚本测试 |

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

产物：

```
dist/Floc-unsigned.ipa                     # 主产物
dist/Floc-20250101-120000-unsigned.ipa     # 带时间戳副本
```

同时跑单元测试：

```bash
./build.sh --test
```

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

内部执行：

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
cd build/UnsignedIPA && zip -qry ../../dist/Floc-unsigned.ipa Payload
```

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
   代价是主 App 与第三方代理模块不再共享配置目录。
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
| `ThirdParty/ProxyScripts/modules/wloc.*` | 模块名、`#!author`、脚本 URL |
| `Shared/ThirdPartyProxyManager.swift` | `defaultModuleBaseURL` |
| `Shared/AppRemoteConfiguration.swift` | 远端配置 URL |

改完跑一遍 `./build.sh --check`，再 `xcodegen generate` 构建。

> **注意**：`Bundle ID` 改了之后，原来装好的 App 需要**卸载重装**，
> 并且根证书也要**重新生成并重新信任**（证书 CN 跟着变了，
> iOS 里会变成两张证书，旧的记得删掉）。

### 关于脚本托管地址

第三方模块和远端配置指向 GitHub raw：

```
https://raw.githubusercontent.com/Lululu-0715/Floc/main/ThirdParty/ProxyScripts/modules
https://raw.githubusercontent.com/Lululu-0715/Floc/main/Resources/remote-config.json
```

如果仓库迁移到其他账号，改上面表格里的
`Shared/ThirdPartyProxyManager.swift` 与 `Shared/AppRemoteConfiguration.swift`
两处常量，以及 `ThirdParty/ProxyScripts/modules/` 下 5 个模块文件里的脚本 URL
（共 17 处）。

改完用这个命令确认 5 个模块全部对齐：

```bash
python3 Tests/check_proxy_modules.py
```

> **前提**：仓库必须是**公开**的。第三方代理客户端无法访问私有仓库的 raw 地址，
> 脚本下载会 404，表现为「模块装了但定位不变」。

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

不需要 Xcode，依次跑 Go 测试、代理脚本测试、本地化校验、Swift 源码一致性检查。
改完代码先跑这个，能拦住大部分低级问题：

```
==> 静态检查
    Go 核心测试通过
    代理脚本测试通过
    本地化校验通过
    Swift 源码一致性通过

静态检查全部通过。
```

`./build.sh` 和 `./build.sh --test` 在构建前也会自动跑一遍这些检查，
所以不必刻意先跑 `--check`。

### Go 核心测试

```bash
cd Core && go test ./... -v
```

覆盖：protobuf 编解码、坐标定点编码、位置条目改写、Wi-Fi 设备识别、
marker 帧长度回填、gzip 处理、CA 生成与解析、loopback 证书签发、自检。

### 第三方代理脚本测试

```bash
cd ThirdParty/ProxyScripts && node --test
```

覆盖：放行路径、坐标改写、长度前缀一致性、无效坐标拒绝、
配置接口的查询 / 保存 / 清除 / 越界拒绝。

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

### 第三方代理模块一致性检查

```bash
python3 Tests/check_proxy_modules.py
```

模块文件里写死了脚本 URL、配置接口路径、拦截主机名，这些一旦和代码不一致，
用户看到的现象是「模块装了但定位不变」，极难排查。这个脚本把这些约定固化：

- 每个模块都引用了两个脚本
- 配置接口路径与 `ThirdPartyProxyClient.settingsPath` 一致
- 拦截主机覆盖 `interceptedHosts` 的全部条目
- **没有给被拦截主机加 `DIRECT` 规则**
  （加了会让流量绕过代理，改写规则永远不触发）
- 按客户端的 `moduleFileExtension` 逐个核实模块文件存在
- 两个脚本用同一个存储键

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
- 第三方模块的脚本 URL 与远端配置 URL 指向同一个仓库
- 证书主题包含品牌名
- 代码里没有旧名称残留
