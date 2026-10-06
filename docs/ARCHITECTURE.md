# 架构说明

本文档解释 Floc 是怎么工作的，以及代码为什么这样分层。

---

## 1. 核心原理

iOS 上 App 自己拿到的定位权限只能读，不能改。要改**系统级**定位（让所有 App
都看到假位置），唯一不越狱的路子是拦截系统的定位查询请求。

iPhone 判断位置时，会向 Apple 的定位服务发起请求：

```
POST https://gs-loc.apple.com/clls/wloc
```

请求体里带着周围 Wi-Fi 的 MAC 地址和蜂窝基站编号，Apple 返回这些热点对应的
经纬度，iOS 再结合 GPS 算出最终位置。

**这是我们的切入点**：在本机跑一个 HTTPS 中间人（MITM）代理，拦下
`gs-loc.apple.com` 的响应，把返回的经纬度改成我们想要的值。系统拿到假坐标，
所有 App 就都定位到那里了。

```
┌──────────┐   Wi-Fi 代理    ┌──────────────┐   真实请求   ┌──────────────┐
│  iOS     │ ──────────────▶ │ 本机代理     │ ──────────▶ │ gs-loc.apple │
│ 系统定位  │  127.0.0.1:8888 │ (MITM 拦截)  │             │   .com        │
└──────────┘                 └──────┬───────┘             └──────────────┘
                                    │
                                    │ 改写响应中的经纬度
                                    ▼
                              ┌──────────────┐
                              │ 注入假坐标    │
                              └──────────────┘
```

### 为什么必须装根证书

要拦截 HTTPS 就必须做中间人。iOS 只信任有合法证书链的 HTTPS 服务，所以：

1. App 生成一张自签根证书（CA）
2. 用户手动把它装进系统并开启完全信任
3. 代理用这张 CA 动态签出 `gs-loc.apple.com` 的叶子证书
4. iOS 校验通过（因为信任了根），代理就能解密并改写响应

---

## 2. 代码分层

```
Floc/
├── Core/                    Go 语言，编译为 iOS 静态库
│   ├── pbcodec.go           protobuf 线格式编解码
│   ├── wloc.go              WLOC 响应改写引擎 ★核心
│   ├── ca.go                证书签发
│   ├── certservice.go       证书分发 + 信任探测
│   ├── proxy.go             MITM 代理
│   ├── bridge.go            C 接口层（CGO export）
│   └── main.go              c-archive 入口（空 main）
│
├── Shared/                  Swift，无 UI，纯逻辑
│   ├── CoreBridge.swift     Go 静态库的 Swift 封装
│   ├── CoordinateConverter.swift   WGS-84 ↔ GCJ-02
│   ├── CertificateTrustVerifier.swift  证书信任验证
│   ├── ProxyManager.swift   本地代理生命周期
│   ├── ThirdPartyProxyManager.swift   第三方客户端对接
│   ├── MapLocationState.swift   全局状态
│   ├── FavoriteLocationStore.swift  收藏夹
│   ├── RuntimeLog.swift     脱敏日志
│   └── ...
│
├── App/                     SwiftUI 界面
│   ├── FlocApp.swift  入口
│   ├── SetupFlowView.swift   4 步引导
│   ├── MapHomeView.swift     主界面（地图选点）
│   ├── DiagnosticsView.swift 诊断页
│   └── ...
│
└── ThirdParty/ProxyScripts/ JS 脚本 + 客户端模块
    ├── wloc.js              响应改写脚本
    ├── wloc-settings.js     配置接口脚本
    └── modules/             5 种客户端模块格式
```

### 为什么用 Go 写核心

1. **protobuf 处理**：WLOC 是未公开的私有协议，没有 `.proto` 定义文件，
   要按字段号手工操作原始字节。Go 的切片和二进制操作写起来直接。
2. **代理库成熟**：`github.com/elazarl/goproxy` 提供了稳定的 MITM 支持。
3. **交叉编译简单**：`go build -buildmode=c-archive` 一条命令出 iOS 静态库，
   不需要手写 Xcode 工程文件。

Go 侧通过 `//export` 暴露纯 C 接口，Swift 侧用 `cgo.Handle` 持有 Go 的
长生命周期对象（代理服务、证书服务）。

---

## 3. WLOC 协议改写

这是整个项目的技术核心。

### 3.1 信封格式

`gs-loc.apple.com/clls/wloc` 的请求体和响应体外面套了一层信封，有两种可能：

**ARPC 信封**
```
┌─────────┬──────────────┬──────────────┬──────────────┬────────────┬─────────┐
│ version │  字符串 1     │  字符串 2     │  字符串 3     │ functionId │ payload │
│  1 字节  │ uint16+内容   │ uint16+内容   │ uint16+内容   │   4 字节    │  剩余    │
└─────────┴──────────────┴──────────────┴──────────────┴────────────┴─────────┘
```

**marker 信封**
```
┌────────────────────────┬──────────────┬─────────┐
│  8 字节前缀             │  载荷长度     │ payload │
│ 00 01 00 00 00 01 00 00│   uint16 BE  │  剩余    │
└────────────────────────┴──────────────┴─────────┘
```

还有少量设备用 **6 字节魔数**（`00 00 00 01 00 00`）的变体。

> ⚠️ **踩过的坑**：6 字节魔数恰好是 8 字节前缀的后 6 字节。如果只按魔数搜索，
> 会在偏移 2 处产生伪匹配，把载荷前两字节误读成长度，导致改写静默失败。
> 所以 `wloc.js` 的 `patchMarkerFrame` 和 Go 的 `patchWlocBody` 都**先试 8 字节
> 前缀，再回退到魔数搜索**。

### 3.2 载荷结构

信封里面是 protobuf。响应载荷的字段布局：

| 字段号 | 类型 | 含义 |
|---|---|---|
| 2 | length-delimited | WiFi 设备条目（可重复） |
| 22 | length-delimited | 蜂窝基站数据段 |
| 24 | length-delimited | 蜂窝基站数据段（变体） |

WiFi 设备条目（字段 2 的内容）：

| 字段号 | 类型 | 含义 |
|---|---|---|
| 1 | length-delimited | MAC 地址（形如 `aa:bb:cc:dd:ee:ff`）★判定标志 |
| 2 | length-delimited | 位置条目（可重复） |

位置条目（嵌套在最里层）：

| 字段号 | 类型 | 含义 |
|---|---|---|
| 1 | varint | **纬度** —— 十进制度 × 1e8 |
| 2 | varint | **经度** —— 十进制度 × 1e8 |
| 3 | varint | 精度（米） |
| 11 | varint | 运动状态（开启运动模拟时补） |
| 12 | varint | 运动置信度（开启运动模拟时补） |

坐标用**定点整数**：`22.281508°` → `2228150800`。

### 3.3 改写策略

```
patchWlocBody(body, target)
  │
  ├─ 1. patchMarkerFrame   → 8 字节前缀 / 6 字节魔数 + uint16 长度
  ├─ 2. patchAtOffset      → 尝试偏移 0..96 的「8 字节 + uint16 长度」
  └─ 3. 裸载荷扫描          → 尝试偏移 0..256 直接当 protobuf 解析
```

逐层降级，任何一层成功就返回。这么设计是因为**不同 iOS 版本的信封格式不一样**，
而且 Apple 改过几次。硬编码单一格式在某个版本上就会失效。

**关键约束：改写时必须原样保留所有未知字段。**

我们只认识字段 1/2/3/11/12，其他字段（比如设备型号、时间戳）必须按原始字节
拷回去。如果重新序列化时丢字段，iOS 可能直接拒绝整个响应。

代码里的做法是 `decodeFields` 解析出每个字段的 `raw`（含 tag 的完整原始字节），
改写时逐字段判断：认识的字段重新编码，不认识的直接 `concat(field.raw)`。

### 3.4 gzip 处理

响应体可能是 gzip 压缩的。Go 侧用 `compress/gzip` 解压后改写、再压缩回去
（`gunzipIfNeeded`）。JS 侧因为客户端脚本引擎对 gzip 支持不一，
选择**检测到 gzip 就放行并记日志**，不冒险处理。

---

## 4. 坐标系转换

中国大陆的地图服务（高德、百度、腾讯）用的是 **GCJ-02**（火星坐标系），
而 GPS 原始数据是 **WGS-84**。两者偏差可达数百米。

### 双坐标存储

每个收藏的位置**同时存两套坐标**：

```swift
struct CoordinatePair {
    let wgs84: CLLocationCoordinate2D
    let gcj02: CLLocationCoordinate2D
    let conversionVersion: Int
}
```

使用时按当前地图体系直接取对应值，**不做二次转换**。

> 为什么不存一套用时再转？因为 GCJ-02 → WGS-84 是**迭代逼近**（3 次迭代），
> 反复转换会累积误差。存两套、直接取，精度最高。

### 转换算法

```swift
// WGS-84 → GCJ-02：正向计算，确定
func wgs84ToGCJ02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D

// GCJ-02 → WGS-84：反向，用 3 次迭代逼近
func gcj02ToWGS84(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D
```

用 Krasovsky 1940 椭球参数：

```swift
static let semiMajorAxis = 6378245.0
static let eccentricitySquared = 0.00669342162296594323
```

**境外坐标不转换** —— `isOutOfChina` 判断在国界外时直接返回原值。
GCJ-02 偏移只在中国境内生效。

### 地图体系自动探测

用户不用手动选坐标系。App 用**天安门锚点**探测：

1. 取已知 GCJ-02 坐标 `(39.908722, 116.397499)`
2. 反算出对应的 WGS-84 坐标
3. 看地图 SDK 把哪个当成天安门，判断它用的是哪套体系

---

## 5. 代理模式

App 支持两种运行模式，对应两类用户场景。

### 5.1 本地代理模式

App 内自带代理服务，监听 `127.0.0.1:8888`。

```
用户在 App 内选点 → 开启虚拟定位
                        │
                        ├─ 启动 Go 代理（Go 侧监听 8888）
                        ├─ 启动后台保活（播放静音音频）
                        └─ 引导用户设置 Wi-Fi 代理为 127.0.0.1:8888
```

**链路**：`iOS 定位服务` → `Wi-Fi 代理 127.0.0.1:8888` → `Go MITM 代理` → `改写` → `返回`

**必须解决的三个问题**：

1. **证书信任**：代理要用 CA 签出的证书提供 HTTPS。
   验证方法是：用签出的 `127.0.0.1` 叶子证书起一个 `/health` 端点，
   再用系统默认信任策略去请求它。成功 = 证书已装好且被信任。
   （iOS 没有公开 API 能查询证书信任状态，只能这样间接验证）

2. **代理链路验证**：刷新一次性 token，请求
   `https://www.baidu.com/location-verify-<token>`。
   如果本机代理拦到这个请求并回显 token，就证明 Wi-Fi 代理确实生效了。
   用百度而不是 Apple 的域名，是因为它不会被其他规则干扰。

3. **后台保活**：iOS 会杀掉后台 App。解决办法是播放静音音频 +
   声明 `UIBackgroundModes: audio`。音频用代码手写 WAV 的 RIFF 头生成，
   不占包体积。

### 5.2 第三方代理模式

给已经在用 Shadowrocket / Surge / QuantumultX 等工具的用户。
App 只负责把配置写进去，代理本身交给用户的客户端。

```
用户在 App 内选点 → App 请求 http://gs-loc.apple.com/wloc-settings/save?lat=..&lon=..
                        │
                        ├─ 客户端脚本 wloc-settings.js 拦截该请求
                        ├─ 把坐标写进客户端持久化存储
                        └─ 返回 success
                        
iOS 定位请求 → 客户端代理 → wloc.js 拦截 → 读存储 → 改写坐标
```

支持 6 种客户端，各自模块格式：

| 客户端 | 扩展名 | URL Scheme |
|---|---|---|
| Shadowrocket | `.module` | `shadowrocket://` |
| Surge | `.sgmodule` | `surge://` |
| QuantumultX | `.conf` | `quantumult-x://` |
| Loon | `.lpx` | `loon://` |
| Stash | `.stoverride` | `stash://` |
| Egern | `.yaml` | `egern://` |

### 5.3 脚本的存储兼容

第三方客户端的持久化 API 各不相同：

| 客户端 | 读 | 写 |
|---|---|---|
| Surge / Loon / Stash | `$persistentStore.read(key)` | `$persistentStore.write(v, key)` |
| QuantumultX | `$prefs.valueForKey(key)` | `$prefs.setValueForKey(v, key)` |
| Shadowrocket | `$rocket.settings.read(key)` | `$rocket.settings.write(key, v)` |

> ⚠️ **踩过的坑**：最初按客户端名字 `switch (ENV)` 分派，结果任何**未列出的
> 客户端**（ENV 返回 `'unknown'`）都会走进没有匹配分支的路径，直接返回
> `undefined`，虚拟定位**静默失效**。
>
> 改成**按 API 能力探测**：依次尝试 `$prefs.valueForKey` →
> `$persistentStore.read` → `$rocket.settings.read`，哪个存在用哪个。
> 这样不认识的客户端也能正常工作。

### 5.4 各客户端的 CA 不能混用

**这是第三方模式下最常见的坑。**

代理客户端各自生成并管理自己的根证书，每张 CA 与生成它的 App 绑定。
把 Surge 的 CA 拿去给 Egern 用，**MITM 会静默失败且不报任何错误** ——
模块看起来装好了、开关也是开的，但定位就是不变。

正确的做法是每个客户端各自生成一次：

| 客户端 | 生成路径 |
|---|---|
| Surge | 设置 → MITM → 生成 CA |
| Egern | 设置 → MitM → 生成 CA |
| Shadowrocket | 设置 → 证书 → 生成新的 CA |
| QuantumultX | 设置 → MitM → 生成证书 |
| Loon / Stash | 设置 → MitM → 生成 CA |

生成后在 iOS「设置 → 通用 → 关于本机 → 证书信任设置」里逐个打开完全信任。

App 内「验证」页的第 3 项检查会探测模块连通性，失败时会提示这一点。

### 5.5 模块文件与客户端的对应

```
ThirdParty/ProxyScripts/modules/
├── wloc.module         Shadowrocket
├── wloc.sgmodule       Surge、Egern（两者共用同一格式）
├── wloc.conf           QuantumultX
├── wloc.lpx            Loon
└── wloc.stoverride     Stash
```

> **不要把被拦截的主机名写进 `DIRECT` 规则。** 那样流量会绕过代理，
> 改写规则永远不会触发。`Tests/check_proxy_modules.py` 会检查这一点。

---

## 6. 数据流

```
┌──────────────────────────────────────────────────────────────┐
│                          SwiftUI 界面                         │
│  MapHomeView（地图选点） ──▶ MapLocationState（状态）          │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                        ProxyManager                          │
│  start() / stop() / updateCoordinates() / verifyCertificate() │
└───────────────────────────┬──────────────────────────────────┘
                            │ C 接口
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                     Go 核心（libwloccore.a）                  │
│  locationcore_setpatchconfig(lat, lon, acc, motion, enabled)  │
│  locationcore_startproxy(certPEM, keyPEM, ...) → handle       │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                        MITM 代理                             │
│  拦截 gs-loc.apple.com → rewriteLocationResponse → 改写坐标   │
└──────────────────────────────────────────────────────────────┘
```

状态是**单向流**：界面改 `MapLocationState` → 触发 `ProxyManager` →
调 C 接口更新 Go 侧的 `spoofState`。Go 侧用 `sync.Mutex` 保护，
因为代理是并发处理请求的。

---

## 7. 日志脱敏

诊断日志会导出给用户看，也可能贴到 issue 里，所以**必须在写入时就脱敏**。

`RuntimeLog.Redactor` 用正则处理 5 类敏感信息：

| 类型 | 正则 | 替换为 |
|---|---|---|
| 经纬度 | `-?\d{1,3}\.\d{6,}` | `<coord>` |
| MAC 地址 | `([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}` | `<mac>` |
| 长十六进制串 | `\b[0-9a-fA-F]{32,}\b` | `<hex>` |
| PEM 私钥 | `-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END...` | `<private-key>` |
| URL 令牌 | `(token\|key\|secret)=[^&\s]+` | `$1=<redacted>` |

日志保留策略：内存最多 500 条，磁盘保留 3 天（启动时清理）。

---

## 8. 界面流程

### 首次启动：4 步引导

```
① 模式选择        ② 权限申请        ③ 代理配置        ④ 验证
┌──────────┐   ┌──────────┐    ┌──────────┐    ┌──────────┐
│ 本地代理  │ → │ 定位权限  │ →  │ 装证书    │ →  │ 6 项检查  │
│ 第三方    │   │ 本地网络  │    │ 设代理    │    │ 全绿完成  │
└──────────┘   └──────────┘    └──────────┘    └──────────┘
```

`SetupCoordinator` 管理步骤状态机（`select` / `advance` / `goBack` /
`jump` / `complete` / `reset`），用户可以随时跳回前面的步骤重做。

### 日常使用：主界面

- **搜索框**（400ms 防抖）→ 地理编码找地点
- **地图**（MKMapView 桥接）→ 单击/长按选点
- **收藏夹** → 最多 50 个常用位置
- **坐标卡片** → 同时显示 WGS-84 和 GCJ-02，各自可复制
- **开关按钮** → 开始/停止虚拟定位

### 其他页面

- **设置**：坐标系偏好、精度、运动模拟、语言、代理模式切换
- **诊断**：6 项环境自检 + 实时日志（2 秒刷新）
- **问题反馈**：生成脱敏报告，一键复制/分享

---

## 9. 关键设计决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 核心语言 | Go + CGO | protobuf 二进制操作直接，代理库成熟，交叉编译简单 |
| 改写策略 | 逐层降级 | 不同 iOS 版本信封格式不同，硬编码单一格式会失效 |
| 未知字段 | 原样保留原始字节 | 丢字段会导致 iOS 拒绝整个响应 |
| 坐标存储 | 双坐标并存 | 避免 GCJ-02 反向迭代累积误差 |
| 脚本存储 API | 能力探测而非名字分派 | 未列出的客户端也能工作 |
| 证书信任验证 | 自签 loopback 证书自测 | iOS 无公开 API 查询信任状态 |
| 代理链路验证 | 请求百度回显 token | 证明代理确实拦到了流量 |
| 后台保活 | 代码生成静音音频 | 不占包体积 |
| 日志 | 写时就脱敏 | 日志可能外传，事后脱敏不可靠 |
| 数值解析 | 严格拒绝 null/空串 | `Number(null) === 0` 会把定位静默改到几内亚湾 |
| 模块文件 | 每客户端一份，Surge 与 Egern 共用 | 各客户端格式不同，共用的不做无谓复制 |
| CA 使用 | 每客户端各自生成 | 跨客户端 CA 会导致 MITM 静默失败 |
| 构建前检查 | 脚本固化跨文件约定 | 「模块装了但定位不变」排查成本极高 |

