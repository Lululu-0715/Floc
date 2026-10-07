-- Floc 授权 / 推荐服务端的表结构（Cloudflare D1 / SQLite）。
--
-- 应用方式：
--   npx wrangler d1 execute floc-license --remote --file=./schema.sql
-- 本地开发：
--   npx wrangler d1 execute floc-license --local --file=./schema.sql
--
-- 时间一律用「毫秒时间戳」（INTEGER）。客户端传来的、返回去的都是毫秒，
-- 服务端不做单位换算就不会两边对不上。

-- 设备。一台设备一行，首次 /api/verify 时创建，同时开始试用。
CREATE TABLE IF NOT EXISTS devices (
  device_id           TEXT PRIMARY KEY,
  -- 试用开始时间；不发 /api/trial，客户端第一次 verify 就落这一笔
  trial_started_at    INTEGER,
  -- 我自己的邀请码（FLOC-XXXXXX 里的 6 位），首次取码时生成
  code                TEXT UNIQUE,
  -- 我填的别人的邀请码
  inviter_code        TEXT,
  -- 连续使用天数
  streak_days         INTEGER NOT NULL DEFAULT 0,
  -- 最近一次心跳的 UTC 日期（yyyy-MM-dd），用于「每天只记一次」
  last_heartbeat_day  TEXT,
  -- 是否已帮推荐人达成条件（1 = 已达成，只结算一次）
  referral_qualified  INTEGER NOT NULL DEFAULT 0,
  created_at          INTEGER NOT NULL
);

-- 我邀请了谁，是「数人头」用的；推荐人侧通过 inviter_code 反查。
CREATE INDEX IF NOT EXISTS idx_devices_inviter ON devices(inviter_code);
CREATE INDEX IF NOT EXISTS idx_devices_code    ON devices(code);

-- 卡密。先在后台批量生成，用户购买后拿到手，激活时绑定到设备。
CREATE TABLE IF NOT EXISTS cards (
  card_key      TEXT PRIMARY KEY,
  -- month / quarter / halfyear / year
  type          TEXT NOT NULL,
  -- 卡密本身的天数，跟着 type 走；单独存一列是为了以后出「活动卡」不改结构
  days          INTEGER NOT NULL,
  -- 当前绑定的设备；NULL 表示未使用
  device_id     TEXT,
  activated_at  INTEGER,
  -- 到期时间；未绑定时为 NULL。续费叠加就是在这个值上再加天数
  expire_at     INTEGER,
  -- 自助解绑次数，限 1 次
  unbind_count  INTEGER NOT NULL DEFAULT 0,
  -- 渠道 / 订单号，方便对账，可为空
  note          TEXT,
  created_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cards_device ON cards(device_id);

-- 推荐奖励的发放流水。
--
-- 每笔奖励自带到期时间（granted_at + days），所以「累计获得」和
-- 「当前剩余」是两个不同的数：前者只增不减，后者会随时间过期。
CREATE TABLE IF NOT EXISTS referral_awards (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  -- 拿奖励的人（推荐人）
  inviter_device  TEXT NOT NULL,
  -- 触发这笔奖励的人；阶梯奖是「某个被推荐人达成了」，付费奖是「某个被推荐人买了」
  invited_device  TEXT,
  -- 'tier' 阶梯奖 / 'paid' 付费奖
  kind            TEXT NOT NULL,
  -- 阶梯奖的档位下标（对应 REFERRAL_TIERS），付费奖为 NULL
  tier            INTEGER,
  days            INTEGER NOT NULL,
  granted_at      INTEGER NOT NULL,
  expire_at       INTEGER NOT NULL
);

-- 同一个 (推荐人, 被推荐人, 类型, 档位) 只发一次，靠唯一索引兜底，
-- 重复结算不会重复发奖。
CREATE UNIQUE INDEX IF NOT EXISTS idx_awards_unique
  ON referral_awards(inviter_device, IFNULL(invited_device, ''), kind, IFNULL(tier, -1));

CREATE INDEX IF NOT EXISTS idx_awards_inviter ON referral_awards(inviter_device);
