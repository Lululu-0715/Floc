# Floc 第三方代理模块

这个目录里的 5 个文件是**同一份 WLOC 改写规则**，分别写成了各家代理客户端
认识的不同格式。**用哪一个只取决于你手机上装的是哪个客户端**，功能完全一致。

> **App 会自动帮你挑。** 在 Floc 的「设置 → 第三方代理」里选中客户端后，
> 点「复制模块订阅地址」拿到的就是对应文件，不需要你在这里手动判断。
> 下面这张表是给手动导入、或者排查问题时对照用的。

脚本本体在上一级目录（`wloc.js` 负责改写定位响应，`wloc-settings.js` 负责接收
App 写入的坐标）。本目录的模块文件只是「外壳」——告诉客户端去哪儿加载脚本、
要 MITM 哪些域名。

---

## 哪个文件配哪个客户端

| 文件 | 对应客户端 | 格式特征 |
|---|---|---|
| [`wloc.module`](wloc.module) | **Shadowrocket**（小火箭） | `[Rewrite]` 段 + `url script-response-body` |
| [`wloc.sgmodule`](wloc.sgmodule) | **Surge**、**Egern** | `[Script]` 段 + `type=http-response,pattern=...` |
| [`wloc.conf`](wloc.conf) | **Quantumult X** | `[rewrite_local]` + `[mitm]` 两段 |
| [`wloc.lpx`](wloc.lpx) | **Loon** | `#!name=` 开头的插件格式 |
| [`wloc.stoverride`](wloc.stoverride) | **Stash** | YAML override（`http.mitm` / `http.script`） |

⚠️ **Surge 和 Egern 共用 `wloc.sgmodule`**。这不是偷懒——两者都实现了 Surge
的模块格式，同一个文件可以直接导入。

---

## 导入地址

把对应那一行粘进客户端的「导入模块 / 添加订阅」即可：

| 客户端 | 导入地址 |
|---|---|
| Shadowrocket | `https://raw.githubusercontent.com/Lululu-0715/Floc/main/ThirdParty/ProxyScripts/modules/wloc.module` |
| Surge | `https://raw.githubusercontent.com/Lululu-0715/Floc/main/ThirdParty/ProxyScripts/modules/wloc.sgmodule` |
| Egern | `https://raw.githubusercontent.com/Lululu-0715/Floc/main/ThirdParty/ProxyScripts/modules/wloc.sgmodule` |
| Quantumult X | `https://raw.githubusercontent.com/Lululu-0715/Floc/main/ThirdParty/ProxyScripts/modules/wloc.conf` |
| Loon | `https://raw.githubusercontent.com/Lululu-0715/Floc/main/ThirdParty/ProxyScripts/modules/wloc.lpx` |
| Stash | `https://raw.githubusercontent.com/Lululu-0715/Floc/main/ThirdParty/ProxyScripts/modules/wloc.stoverride` |

直接在客户端里搜文件名是搜不到的，**要粘完整地址**。

---

## 导入之后必须做两件事

1. **开启模块**（导入完默认可能是关闭状态）；
2. **开启 MITM**，并确认下面这 14 个主机名已加进 MITM 名单：

```
gs-loc.apple.com
gs-loc-cn.apple.com
gsp-ssl.ls.apple.com
gsp10-ssl.ls.apple.com
gsp10-ssl.apple.com
gsp64-ssl.ls.apple.com
gspe1-ssl.ls.apple.com
gspe19-ssl.ls.apple.com
gspe19-2-ssl.ls.apple.com
gspe35-ssl.ls.apple.com
gspe79-ssl.ls.apple.com
gspe85-ssl.ls.apple.com
bluedot.is.autonavi.com
bluedot.is.autonavi.com.gds.alibabadns.com
```

前两台是 Apple 的全球 / 国内定位入口，中间那批 `gsp*` / `gspe*` 是
**新版本系统把定位查询分散过去的备用入口**。只拦前两三台的话，在 iOS 26+
上会表现成「模块装了、MITM 也开了，定位就是纹丝不动」。最后两台是
Apple 地图在国内使用的蓝点定位（高德）端点。

`wloc.module`（Shadowrocket）、`wloc.sgmodule`（Surge / Egern）两个文件的
`hostname` 用的是 `%APPEND%` 前缀，导入时会**追加**到你的 MITM 名单，
不会覆盖已有配置；其余三个文件是直接列出的，导入后建议自己核对一眼。

---

## 两个最常见的坑

### 1. 每个客户端要各自生成一次 CA，不能混用

每个代理客户端的根证书与它自己绑定。把 Surge 的 CA 拿给 Egern 用，
**MITM 会静默失败且不报错**——模块看着装好了、开关也开着，定位就是不变。

| 客户端 | 生成路径 |
|---|---|
| Surge | 设置 → MITM → 生成 CA |
| Egern | 设置 → MitM → 生成 CA |
| Shadowrocket | 设置 → 证书 → 生成新的 CA |
| Quantumult X | 设置 → MITM → 生成证书 |
| Loon / Stash | 设置 → MitM → 生成 CA |

生成后还要去 iOS「设置 → 通用 → 关于本机 → 证书信任设置」里逐个打开。

### 2. 绝不要给被拦截的主机加 DIRECT 规则

```ini
# 千万别这么写
DOMAIN,gs-loc.apple.com,DIRECT
```

这会让流量**绕过代理直连**，模块看起来安装成功却永远不会触发——
因为请求根本没经过 MITM。仓库里的检查脚本会拦住这种写法
（`Tests/check_proxy_modules.py` 第 5 项）。

---

## 脚本地址写死在本仓库

模块文件里的脚本 URL 指向本仓库的 raw 地址。**fork 或迁移到其他账号后
必须同步替换**，否则客户端拉脚本会 404。改动点见
[BUILD.md 第 7 节](../../../docs/BUILD.md)，改完用
`python3 Tests/check_branding.py` 验证一致性。

另外，仓库必须保持**公开**——私有仓库的 raw 地址客户端访问不到。
