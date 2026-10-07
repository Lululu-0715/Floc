# Floc 授权服务端

卡密 / 试用 / 推荐奖励的后端，跑在 **Cloudflare Workers + D1**（免费额度足够：
D1 每天 500 万行读、10 万行写，Worker 每天 10 万次请求）。

客户端那边的契约在 `Shared/License/LicenseAPI.swift`，业务常量在
`Shared/License/LicenseConfig.swift` —— **两边改一处必须改另一处**（对照表见下）。

---

## 一、先搞清楚「不部署会怎样」

`LicenseConfig.baseURL` 现在还是占位符（含 `YOUR-SUBDOMAIN`），客户端因此判定
`isConfigured == false`，整个授权系统降级成 **本地模式**：

- 一个网络请求都不发（省掉每次启动 12 秒超时 + 一条「网络异常」弹窗）；
- 授权闸门放行，全部功能可用；
- 设置页「账号 → 设备码」旁的标签显示 **本地模式**。

所以**不部署也能正常用**，只是没有卡密收费能力。部署完把域名填进去，
校验与闸门自动恢复，不用改别的代码。

内置测试卡密 `FLOC-TEST-2026`（30 天，纯离线激活）在两种状态下都能用，
它的界面提示只在「未配置」时出现，填上真实域名后自动消失。

---

## 二、部署（一次性，约 10 分钟）

全部命令都在 `Server/license-worker` 目录下执行。

### 1. 装依赖并登录

```bash
cd Server/license-worker
npm install            # 只装 wrangler 一个 devDependency
npx wrangler login     # 会打开浏览器授权，点允许
npx wrangler whoami    # 确认已登录（打印邮箱和账号 ID）
```

> 没有 Cloudflare 账号的话先在 cloudflare.com 免费注册，不需要绑卡。

### 2. 建 D1 数据库

```bash
npx wrangler d1 create floc-license
```

输出里会有一行：

```
database_id = "a1b2c3d4-...-xxxxxxxxxxxx"
```

把这个值填进 `wrangler.toml` 的 **两处** `database_id`
（`[[d1_databases]]` 和 `[[env.production.d1_databases]]`），
替换掉 `REPLACE-WITH-YOUR-DATABASE-ID`。

> ⚠️ 这步不能跳。不填的话部署会报配置错误；填错的话部署能成功但所有请求 500。

### 3. 建表

```bash
npm run init:remote
```

（等价于 `npx wrangler d1 execute floc-license --remote --file=./schema.sql`）

脚本全是 `CREATE TABLE IF NOT EXISTS`，重复执行安全。

### 4. 本地先验一遍（可选，但建议）

```bash
npm test       # 26 个用例：卡密规范化 / 试用 / 续费叠加 / 解绑限次 / 推荐阶梯 / 封顶
npm run dev    # 本地起 worker，监听 http://localhost:8787
```

另开一个终端打一下：

```bash
curl -s http://localhost:8787/api/verify \
  -H 'content-type: application/json' \
  -d '{"deviceId":"test-device"}' | python3 -m json.tool
```

预期看到 `"ok": true` 且 `"status": "trial"`。

### 5. 部署

```bash
npm run deploy
```

（等价于 `npx wrangler deploy --env production`）

成功后输出里有一行地址，形如：

```
https://floc-license.<你的账号>.workers.dev
```

**记下这个域名，接下来两处都要用。**

### 6. 冒烟测试线上地址

```bash
curl -s https://floc-license.<你的账号>.workers.dev/api/verify \
  -H 'content-type: application/json' \
  -d '{"deviceId":"smoke-test"}' | python3 -m json.tool
```

必须返回 `"ok": true` / `"status": "trial"`。返回 500 基本就是第 2、3 步没做对。

---

## 三、接进客户端

### 1. 填域名

`Shared/License/LicenseConfig.swift`：

```swift
static let baseURL = "https://floc-license.<你的账号>.workers.dev"
```

- 只填到域名，**不要带 `/api/verify`**（代码自己拼路径）；
- 结尾不要带斜杠；
- 填完 `isConfigured` 自动变 true，本地模式关闭。

### 2. 核对常量（两边必须完全一致）

| 含义 | 客户端 `LicenseConfig` | Worker `src/index.js` |
|---|---|---|
| 试用天数 | `trialDays` = 3 | `TRIAL_DAYS` = 3 |
| 推荐所需连续天数 | `referralRequiredDays` = 3 | `REFERRAL_REQUIRED_DAYS` = 3 |
| 付费奖励天数 | `referralPaidBonusDays` = 15 | `REFERRAL_PAID_BONUS_DAYS` = 15 |
| 奖励累计封顶 | `referralCapDays` = 1095 | `REFERRAL_CAP_DAYS` = 1095 |
| 推荐阶梯 | `referralTiers` | `REFERRAL_TIERS` |
| 离线宽限 | `offlineGraceDays` = 3 | （客户端行为，服务端无对应） |

还有一条**最容易踩**的：卡密规范化规则在两边各写了一份
（`LicenseConfig.normalizeCardKey` / Worker `normalizeCardKey`）。
卡密是拿规范化之后的结果去数据库查的，两边规则差一点就会
「客户端说输对了、服务端说卡密不存在」。改一边必须改另一边。

### 3. 关掉内置测试卡密（上线前）

`LicenseConfig.testCardKeys` 清空即可整体关闭：不再识别、界面提示一并消失。
建议保留到正式发版前再清。

---

## 四、生成卡密

```bash
node scripts/gen-cards.mjs --type month --count 50 --note "淘宝-2026-03"
```

参数：

| 参数 | 说明 |
|---|---|
| `--type` | `month`(30) / `quarter`(90) / `halfyear`(180) / `year`(365) |
| `--count` | 张数 |
| `--days` | 覆盖天数，做活动卡用（如 `--days 45`） |
| `--note` | 备注，写进 `cards.note`，对账用 |
| `--prefix` | 卡密前缀，默认 `FLOC` |

产出两个文件（在 `out/` 下，**已被 .gitignore 忽略，别提交**）：

- `cards-month-<时间戳>.sql` —— 灌库用
- `cards-month-<时间戳>.txt` —— 卡密清单，拿去发货

灌库：

```bash
npx wrangler d1 execute floc-license --remote --file=./out/cards-month-<时间戳>.sql
```

看一眼库存：

```bash
npx wrangler d1 execute floc-license --remote \
  --command "SELECT type, COUNT(*) AS total, SUM(device_id IS NULL) AS unused FROM cards GROUP BY type"
```

卡密形如 `FLOC-2SEM-4BNF-BJNT`，字母表去掉了 `0/O/1/I`，用户报码时少一半口误。

---

## 五、接口一览

全部 **POST + JSON**。业务错误也返回 JSON（HTTP 非 2xx）：

```json
{ "ok": false, "error": "card_not_found", "message": "卡密不存在，请核对后重试" }
```

| 路径 | 作用 |
|---|---|
| `/api/verify` | 校验并返回授权状态；**首次调用会顺带登记设备并开始试用** |
| `/api/activate` | 卡密激活（续费叠加在现有到期时间之后） |
| `/api/unbind` | 自助解绑（每张卡限 1 次） |
| `/api/referral/code` | 取我的邀请码（首次自动生成 6 位） |
| `/api/referral/bind` | 填写别人的邀请码 |
| `/api/referral/heartbeat` | 每天一次使用心跳，用于判定「连续使用 3 天」 |
| `/api/referral/status` | 推荐进度 |

设计上的几个取舍写在 `src/index.js` 头部注释里，改行为前先读一遍。

---

## 六、装到手机上自测一遍（部署后必做）

1. 装新包 → **设置 → 账号**：状态应为「试用中」，剩余时间显示倒计时；
2. **输入卡密** → 填一张刚生成的卡 → 状态变「已激活」，剩余时间跳到 30 天；
3. 再输一遍同一张卡 → **天数不该变化**（服务端已拦重复激活）；
4. **升级套餐 → 推荐好友**：能看到 6 位邀请码，进度显示「再邀请 3 人」；
5. 换一台设备填这个码，连续 3 天打开 App → 原设备显示「已邀请 1 人」但**还拿不到奖励**
   （第一档要 3 人达标才发 7 天，第 3 个人达标时才结算）；
6. 同一被推荐人再买一张卡激活 → 推荐人得 15 天（每对关系只发一次）；
7. **解绑设备** → 卡密回到未绑定状态；同一台机器再解绑会被拦。

---

## 七、日常运维

```bash
npm run tail     # 实时看日志（console.error 的堆栈都在这里）
```

查数据：

```bash
# 最近登记的 20 台设备
npx wrangler d1 execute floc-license --remote \
  --command "SELECT device_id, code, inviter_code, streak_days, referral_qualified, created_at FROM devices ORDER BY created_at DESC LIMIT 20"

# 发出去的奖励
npx wrangler d1 execute floc-license --remote \
  --command "SELECT inviter_device, kind, tier, days, granted_at FROM referral_awards ORDER BY id DESC LIMIT 20"
```

手动补时长（客服补偿之类）：

```bash
npx wrangler d1 execute floc-license --remote --command \
  "INSERT INTO referral_awards (inviter_device, invited_device, kind, tier, days, granted_at, expire_at) VALUES ('<device_id>', NULL, 'tier', NULL, 30, <now_ms>, <now_ms + 2592000000>)"
```

`device_id` 是完整的**小写 UUID**（36 位）。App 里「设置 → 账号 → 设备码」
显示的是它的前 8 位大写形式，用来人工报给你识别，入库时要用完整值——
可以直接按前缀查：`SELECT device_id FROM devices WHERE device_id LIKE '<前8位小写>%'`。

顺手把某张卡解绑/改绑：

```bash
npx wrangler d1 execute floc-license --remote \
  --command "UPDATE cards SET device_id = NULL, expire_at = NULL, unbind_count = 0 WHERE card_key = 'FLOC-XXXX-XXXX-XXXX'"
```

备份：

```bash
npx wrangler d1 export floc-license --remote --output=backup-$(date +%Y%m%d).sql
```

---

## 八、数据与隐私

- 只存：设备 ID（App 生成的随机 UUID）、卡密、邀请码、推荐关系、时间戳；
- 不存：IP、手机号、Apple ID、位置——Worker 里没有任何 `console.log` 打印这些；
- 设备 ID 存在 iOS Keychain 里（卸载重装不变，抹机才变），与真人身份无关联；
- 用户想删数据：把对应 `devices` / `cards` 行的绑定关系清掉即可（无级联外键）。

---

## 九、排错

| 现象 | 原因 / 处理 |
|---|---|
| 客户端一直显示「本地模式」 | `baseURL` 还是占位符或写错了（不能带路径、不能带结尾斜杠） |
| 所有请求 500 | `wrangler.toml` 的 `database_id` 没填对，或第 3 步建表没做 |
| 部署报 `d1_databases must be an array` | 环境段写成了 `[env.production.d1_databases]`，必须是双中括号 |
| 「卡密不存在」但确实是刚生成的 | 卡没灌进库，或规范化不一致——查 `SELECT card_key FROM cards LIMIT 5` 里的真实值 |
| 客户端提示「网络异常」但功能还能用 | 这是离线宽限（`offlineGraceDays` 天内继续可用），配合 `npm run tail` 看真实错误 |
| 推荐奖励没发 | 结算发生在被推荐人「连续第 3 天心跳」那一刻；且第一档要 3 人达标，1 人不够 |
| 试用天数不对 | 两边常量没同步（见第三节表格） |
| 改了 `src/index.js` 但线上没变 | 忘了 `npm run deploy`；改 schema 还要额外 `npm run init:remote` |

改完代码，本地 `npm test` 必须先全绿（26 个用例）再部署。
