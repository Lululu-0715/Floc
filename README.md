# Floc

iOS 虚拟定位工具。通过本机 MITM 代理拦截 Apple 定位服务响应，改写返回的经纬度，
让系统级定位落到指定位置。

- **Bundle ID**：`com.fff.loc`
- **App Group**：`group.com.fff.loc`
- **显示名**：Floc（三语言一致）

---

## 特性

- **两种运行模式**
  - **本地代理**：App 内自带 MITM 代理，无需额外软件
  - **第三方代理**：对接 Shadowrocket / Surge / QuantumultX / Loon / Stash / Egern
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
`Floc-<版本号>-unsigned.ipa`（最新为 `Floc-1.0.1-unsigned.ipa`），跳过下面的编译步骤。

下载到的是**未签名**包，iOS 不会直接运行，需要自签工具（TrollStore / AltStore /
Sideloadly / 爱思助手），签名与安装的完整流程见
**[快速上手.md](快速上手.md)** 第 3 步。

> ⚠️ **免费 Apple ID 自签不支持 App Group**，装上后第三方代理模式不可用。
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

产物在 `dist/Floc-<版本号>-unsigned.ipa`（另有固定名副本 `dist/Floc-unsigned.ipa`），
用 AltStore / Sideloadly 等工具自签后安装。每次构建版本号末位自动 +1，
版本号体现在 IPA 文件名和 App 内的「设置 → 关于 → 应用版本」里；
桌面图标名字恒为 `Floc`，不随版本变化。
完整说明见 **[docs/BUILD.md](docs/BUILD.md)**。

> **第三方模块的脚本地址写死在本仓库的 raw 地址上**（`Lululu-0715/Floc`）。
> 如果你 fork 或迁移到其他账号，必须同步改 3 个常量与 5 个模块文件（共 17 处 URL），
> 否则模块下载会 404。改动点见
> [BUILD.md 第 7 节](docs/BUILD.md#关于脚本托管地址)，
> 改完用 `python3 Tests/check_branding.py` 确认对齐。

### 首次使用

1. 打开 App，跟随 4 步引导完成设置
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
│   ├── ThirdPartyProxyManager.swift  第三方客户端对接
│   └── ...
│
├── App/                        SwiftUI 界面
│   ├── SetupFlowView.swift     4 步引导
│   ├── MapHomeView.swift       主界面
│   ├── DiagnosticsView.swift   诊断页
│   └── ...
│
├── ThirdParty/ProxyScripts/    第三方代理脚本与模块
│   ├── wloc.js                 响应改写脚本
│   ├── wloc-settings.js        配置接口脚本
│   └── modules/                6 种客户端模块（对照表见该目录 README.md）
│
├── Resources/                  本地化、图标、Info.plist
├── Scripts/                    构建脚本
└── Tests/                      测试脚本
```

---

## 第三方代理模块对照

`ThirdParty/ProxyScripts/modules/` 下的 5 个文件是**同一份改写规则写成的 5 种格式**，
用哪个只看你手机上装的是哪个客户端，功能完全一致。

**App 会自动按你选中的客户端挑对应文件**——在「设置 → 第三方代理」里选好客户端后，
点「复制模块订阅地址」拿到的就是对的。下表供手动导入时对照：

| 模块文件 | 对应客户端 | 格式特征 |
|---|---|---|
| `wloc.module` | **Shadowrocket**（小火箭） | `[Rewrite]` + `url script-response-body` |
| `wloc.sgmodule` | **Surge**、**Egern** | `[Script]` + `type=http-response,pattern=...` |
| `wloc.conf` | **Quantumult X** | `[rewrite_local]` + `[mitm]` |
| `wloc.lpx` | **Loon** | `#!name=` 开头的插件格式 |
| `wloc.stoverride` | **Stash** | YAML override |

> Surge 与 Egern 共用 `wloc.sgmodule`：两者都实现了 Surge 的模块格式。

导入后必须**开启模块 + 开启 MITM**，并且**每个客户端要各自生成一次 CA**——
CA 混用时 MITM 会静默失败、不报错。完整说明、导入地址与排查见
**[ThirdParty/ProxyScripts/modules/README.md](ThirdParty/ProxyScripts/modules/README.md)**。

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

# 第三方脚本测试（11 个用例）
cd ThirdParty/ProxyScripts && node --test

# iOS 单元测试（6 个测试文件）
./build.sh --test

# 本地化完整性校验
python3 Tests/check_localization.py

# Swift 源码一致性检查
python3 Tests/check_swift_sources.py

# 第三方代理模块一致性检查
python3 Tests/check_proxy_modules.py

# 品牌命名一致性检查（Bundle ID / 显示名 / 证书主题）
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
