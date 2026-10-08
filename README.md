# Floc

iOS 虚拟定位工具。通过本机 MITM 代理拦截 Apple 定位服务响应，改写返回的经纬度，
让系统级定位落到指定位置。

- **Bundle ID**：`com.fff.loc`
- **App Group**：`group.com.fff.loc`
- **显示名**：Floc（三语言一致）

---

## 特性

- **应用内代理**：App 自带 MITM 代理与证书，装上即用，不需要任何第三方客户端
- **双坐标系**：WGS-84 与 GCJ-02 同时存储，按地图体系取值，不累积转换误差
- **地图选点**：搜索地点、地图单击/长按选点，直观指定目标位置
- **实时位置**：一键跳回真实 GPS 位置，长按回到已选点
- **运动模拟**：可选关闭 / 5 米 / 10 米 / 20 米原地漂移半径，让定位看起来在动
- **收藏位置**：最多 50 个常用位置，一键切换
- **环境自检**：6 项检查（权限 / 证书 / 代理链路 / 核心状态等），出问题能定位到具体环节
- **诊断日志**：实时查看运行日志，导出的内容自动脱敏（坐标 / MAC / 密钥 / 令牌）
- **后台保活**：静音音频保持代理进程存活
- **三语言**：简体中文 / 繁体中文 / English

---

## 快速开始

### 直接下载（不编译）

到 **[Releases](https://github.com/Lululu-0715/Floc/releases)** 下载已经打好的
`Floc-<版本号>-unsigned.ipa`（最新为 `Floc-1.0.4-unsigned.ipa`），跳过下面的编译步骤。
不想装卡密 / 授权那套的话，下带「-纯净-」的那一个（`Floc-<版本号>-纯净-unsigned.ipa`），
签名与安装步骤完全一样。

下载到的是**未签名**包，iOS 不会直接运行，需要自签工具（TrollStore / AltStore /
Sideloadly / 爱思助手），签名与安装的完整流程见
**[快速上手.md](快速上手.md)** 第 3 步。

> ⚠️ **免费 Apple ID 自签不支持 App Group**，装上后配置与收藏无法持久化。
> 用 TrollStore 或开发者账号签则不受影响。权衡与改法见快速上手第 3 步。

### 前置条件

- macOS 13+ 与 Xcode 15+
- Go 1.23+、XcodeGen、Node.js 18+（可选）

```bash
brew install go xcodegen node
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### 构建

```bash
git clone https://github.com/Lululu-0715/Floc.git
cd Floc
chmod +x build.sh Scripts/*.sh
./build.sh
```

产物在 `dist/`，**一次两个口味**：

```
Floc-<版本号>-unsigned.ipa         标准版：带卡密 / 授权 / 推荐
Floc-<版本号>-纯净-unsigned.ipa    纯净版：没有卡密那套（PURE_BUILD）
Floc-unsigned.ipa                  标准版的固定名副本，发布链接引用它
Floc-纯净-unsigned.ipa             纯净版的固定名副本
```

用 AltStore / Sideloadly 等工具自签后安装。两个包是同一个 App
（Bundle ID 与显示名都是 `Floc`），装一个会覆盖另一个。每次构建版本号末位
自动 +1，版本号体现在 IPA 文件名和 App 内的「设置 → 关于 → 应用版本」里；
桌面图标名字恒为 `Floc`，不随版本变化。裁剪范围见 `Shared/BuildFlavor.swift`，
完整说明见 **[docs/BUILD.md](docs/BUILD.md)**。

> **远端配置指向本仓库在 jsDelivr 上的镜像**（`Lululu-0715/Floc@main`）。
> 用 jsDelivr 而不是 `raw.githubusercontent.com` 是有原因的：raw 国内基本拉不到，
> 而远端配置拉不到时的表现是**静默降级**（公告不弹、失效警示不显示）。
> 如果你 fork 或迁移到其他账号，改 `Shared/AppRemoteConfiguration.swift` 里的
> `defaultConfigurationURL` 一处即可，改完用 `python3 Tests/check_branding.py` 确认。

### 首次使用

1. 打开 App，跟随 3 步引导完成设置
2. 授权定位权限（选「始终允许」）
3. 安装并信任根证书（设置 → 通用 → VPN与设备管理 → 关于本机 → 证书信任设置）
4. 设置 Wi-Fi 代理为 `127.0.0.1:8888`（App 内有一键跳转）
5. 回到 App 点「验证」，全绿即可开始

---

## 项目结构

```
Floc/
├── build.sh                    一键构建入口
├── project.yml                 XcodeGen 工程定义
│
├── Core/                       Go 核心（编译为 iOS 静态库）
│   ├── wloc.go                 WLOC 响应改写引擎 ★
│   ├── pbcodec.go              protobuf 编解码
│   ├── ca.go / certservice.go  证书签发与分发
│   ├── proxy.go                MITM 代理
│   └── bridge.go               C 接口层
│
├── Shared/                     Swift 逻辑层（无 UI）
│   ├── CoreBridge.swift        Go 库封装
│   ├── CoordinateConverter.swift  坐标系转换
│   ├── ProxyManager.swift      代理生命周期
│   └── ...
│
├── App/                        SwiftUI 界面
│   ├── SetupFlowView.swift     3 步引导
│   ├── MapHomeView.swift       主界面
│   ├── DiagnosticsView.swift   诊断页
│   └── ...
│
├── Server/license-worker/      授权 / 推荐服务端（Cloudflare Worker + D1，可选）
│   ├── src/index.js            全部接口（字段契约见 Shared/License/LicenseAPI.swift）
│   ├── schema.sql              D1 建表
│   ├── test/                   26 个单元测试
│   └── README.md               部署步骤
│
├── Resources/                  本地化、图标、Info.plist
├── Scripts/                    构建脚本
└── Tests/                      测试脚本
```

> **1.0.8 起只剩应用内代理。** 原来还有一条「第三方代理」链路
> （对接 Shadowrocket / Surge / QuantumultX / Loon / Stash / Egern，靠
> `ThirdParty/ProxyScripts/` 下的 5 个模块 + 2 个 JS 脚本在客户端里跑同样的改写），
> 已连同 `Shared/ThirdPartyProxyManager.swift`、客户端选择界面与三项配套检查一起删除。
> 这样仓库里不再有需要在运行时被外部拉取的资产，也不再需要为模块维护两套并行实现
> （`Core/wloc.go` 的 Go 版与 `wloc.js` 的 JS 版）。

---

## 工作原理

iPhone 判断位置时会向 Apple 的定位服务查询周围 Wi-Fi 和基站对应的经纬度。
本机代理拦下这些响应，把坐标改掉，系统就定位到假位置。

```
iOS 定位服务 → Wi-Fi 代理 127.0.0.1:8888 → MITM 拦截 → 改写坐标 → 返回
```

拦截范围是 **14 个主机**（`gs-loc.apple.com` / `gs-loc-cn.apple.com` / `gsp-ssl.ls.apple.com`
以及 `gsp*` / `gspe*` 系列）。这里**只逐个枚举，不用 `*.apple.com` 通配符**——
通配会连推送、App Store、激活等流量一起 MITM，既拖慢又容易出问题。

改写的关键难点：

- WLOC 是**未公开的私有 protobuf 协议**，需按字段号手工操作原始字节
- 坐标是**定点整数**（十进制度 × 1e8）
- 必须**原样保留所有未知字段**，否则 iOS 会拒绝整个响应
- 不同 iOS 版本信封格式不同，需要**逐层降级**尝试

技术细节见 **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**。

---

## 开发

```bash
# 一键自检（不需要 Xcode，最快）
./build.sh --check

# Go 核心测试（12 个用例）
cd Core && go test ./... -v

# 授权服务端测试（26 个用例，需要 Node 22+）
cd Server/license-worker && npm test

# iOS 单元测试（11 个测试文件）
./build.sh --test

# 本地化完整性校验
python3 Tests/check_localization.py

# Swift 源码一致性检查
python3 Tests/check_swift_sources.py

# 品牌命名一致性检查（Bundle ID / 显示名 / 证书主题 / 远端配置地址）
python3 Tests/check_branding.py
```

只改了 Go 代码时，重新编译核心即可：

```bash
./Scripts/build-core.sh
```

`./build.sh` 与 `./build.sh --test` 在构建前会自动跑一遍静态检查，
把 Go 测试失败、桥接头漏声明、文案不齐这类问题拦在编译之前。

---

## 免责声明

本项目仅供**学习和技术研究**使用。

- 使用者应自行遵守当地法律法规及目标服务的使用条款
- 不得用于伪造考勤、规避监管、网络欺诈等任何违法用途
- 虚拟定位可能违反部分 App 的服务条款，由此产生的账号风险由使用者自负
- 作者不对使用本工具造成的任何直接或间接损失承担责任

请在使用前确认你的用途合法合规。
