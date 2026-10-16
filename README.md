# Floc · 第三方客户端分发文件

本仓库**仅存放运行时需要的分发文件**，供各代理客户端远程加载。这里没有 App 源码，
也不需要构建。

## 内容

| 路径 | 说明 |
|---|---|
| `ThirdParty/ProxyScripts/wloc.js` | 改写逻辑主体，客户端每次请求时实时拉取 |
| `ThirdParty/ProxyScripts/wloc-settings.js` | 接收 App 写入的坐标 |
| `ThirdParty/ProxyScripts/modules/` | 各客户端模块外壳，及导入说明 |
| `Resources/remote-config.json` | 远端配置：脚本版本号、模块基地址 |

## 导入模块

五种客户端（Shadowrocket / Surge / Egern / Quantumult X / Loon / Stash）的
导入地址、MITM 主机名清单、常见坑，都写在：

**[`ThirdParty/ProxyScripts/modules/README.md`](ThirdParty/ProxyScripts/modules/README.md)**

## 说明

- 本仓库内容由发布脚本同步，**请勿直接修改**，改动会在下次同步时被覆盖。
- 客户端默认通过 jsDelivr CDN 拉取（`cdn.jsdelivr.net`），对分支 `@main`
  最长缓存 12 小时；刚更新完脚本若手机上仍是旧行为，等缓存过期或改用
  `raw.githubusercontent.com` 临时验证。
- 本仓库必须保持**公开**：私有仓库的地址客户端访问不到。
