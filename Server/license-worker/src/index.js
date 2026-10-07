/**
 * Floc 授权 / 推荐服务端。
 *
 * 客户端契约见 `Shared/License/LicenseAPI.swift`，两边的字段名必须一一对应。
 * 所有接口都是 POST + JSON，业务错误也用 JSON 返回（HTTP 非 2xx）：
 *
 *     { "ok": false, "error": "错误码", "message": "给人看的话" }
 *
 * 设计上的几个取舍：
 *
 *   1. **试用在首次 /api/verify 时自动开始**，没有单独的登记接口。
 *      客户端启动就会 verify 一次，多一个登记步骤只会多一处失败点。
 *   2. **卡密与设备一对一**，激活时如果设备上已有卡，天数**叠加**到已有
 *      到期时间之后，而不是覆盖——用户续费不该让剩余时长缩水。
 *   3. **推荐奖励带自己的到期时间**，累计封顶 3 年。奖励与卡密时长相加
 *      得到总剩余，两者互不覆盖。
 *   4. 自助解绑每张卡限 1 次，防止一张卡在设备之间无限流转。
 */

const DAY_MS = 86_400_000;

/** 试用天数。改动必须与客户端 `LicenseConfig.trialDays` 同步。 */
const TRIAL_DAYS = 3;

/** 被推荐人需连续使用的天数。与 `LicenseConfig.referralRequiredDays` 同步。 */
const REFERRAL_REQUIRED_DAYS = 3;

/** 被推荐人付费后推荐人额外获得的天数。与 `LicenseConfig.referralPaidBonusDays` 同步。 */
const REFERRAL_PAID_BONUS_DAYS = 15;

/** 推荐奖励封顶天数。与 `LicenseConfig.referralCapDays` 同步。 */
const REFERRAL_CAP_DAYS = 365 * 3;

/** 推荐阶梯。与 `LicenseConfig.referralTiers` 同步。 */
const REFERRAL_TIERS = [
  { count: 3, days: 7 },
  { count: 7, days: 15 },
  { count: 15, days: 30 },
  { count: 30, days: 90 },
  { count: 50, days: 180 },
  { count: 100, days: 365 },
];

/** 卡密类型 → 天数。 */
const CARD_TYPES = {
  month: 30,
  quarter: 90,
  halfyear: 180,
  year: 365,
};

// ---------------------------------------------------------------- 工具

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });

const fail = (error, message, status = 400) =>
  json({ ok: false, error, message: message || error }, status);

/** 设备 ID 统一小写去空格，与服务端存储形态对齐。 */
const normalizeDevice = (raw) =>
  typeof raw === 'string' ? raw.trim().toLowerCase() : '';

/**
 * 卡密规范化。
 *
 * 必须与客户端 `LicenseConfig.normalizeCardKey` 逐字一致：卡密是拿这个
 * 结果去查库的，两边规则只要差一点就会出现「客户端说输对了、服务端查不到」。
 * 用空格代替连字符是最常见的手打形态，所以空格换成连字符而不是删掉。
 */
const normalizeCardKey = (raw) => {
  if (typeof raw !== 'string') return '';
  return raw
    .trim()
    .replace(/[—－]/g, '-')
    .replace(/[ \t]+/g, '-')
    .toUpperCase()
    .replace(/-{2,}/g, '-')
    .replace(/^-+|-+$/g, '');
};

const dayKey = (ms) => new Date(ms).toISOString().slice(0, 10);

const dayKeyBefore = (key) =>
  dayKey(Date.parse(key + 'T00:00:00.000Z') - DAY_MS);

/** 剩余天数按「向下取整」给，避免剩 23 小时被显示成 1 天。 */
const toDays = (ms) => Math.max(0, Math.floor(ms / DAY_MS));

async function readBody(request) {
  try {
    return await request.json();
  } catch {
    return {};
  }
}

// ---------------------------------------------------------------- 设备

/**
 * 取设备行，没有就建一条（同时开始试用）。
 *
 * 用 `INSERT OR IGNORE` + 再查一次，避免两个并发请求同时新建同一条。
 */
async function ensureDevice(env, deviceId, now) {
  await env.DB.prepare(
    `INSERT OR IGNORE INTO devices (device_id, trial_started_at, streak_days, created_at)
     VALUES (?, ?, 0, ?)`
  )
    .bind(deviceId, now, now)
    .run();

  return env.DB.prepare('SELECT * FROM devices WHERE device_id = ?')
    .bind(deviceId)
    .first();
}

/** 设备当前绑定的卡密（取到期时间最晚的那张）。 */
async function currentCard(env, deviceId) {
  return env.DB.prepare(
    `SELECT * FROM cards
      WHERE device_id = ? AND expire_at IS NOT NULL
      ORDER BY expire_at DESC LIMIT 1`
  )
    .bind(deviceId)
    .first();
}

/**
 * 推荐奖励的剩余时长。
 *
 * 奖励自带到期时间：发放日 + 天数。已过期的奖励不再计入，所以
 * 「累计获得」与「当前剩余」是两个数，客户端两处都要用。
 */
async function bonusSummary(env, deviceId, now) {
  const { results } = await env.DB.prepare(
    'SELECT days, expire_at FROM referral_awards WHERE inviter_device = ?'
  )
    .bind(deviceId)
    .all();

  let grantedDays = 0;
  let remainingMs = 0;
  for (const row of results || []) {
    grantedDays += row.days;
    if (row.expire_at > now) {
      remainingMs += row.expire_at - now;
    }
  }

  return { grantedDays, remainingMs };
}

function resolveStatus({ cardRemainingMs, trialRemainingMs, bonusRemainingMs, hasCard, hasTrial }) {
  if (cardRemainingMs > 0) return 'active';
  if (trialRemainingMs > 0) return 'trial';
  if (bonusRemainingMs > 0) return 'bonus';
  if (hasCard) return 'expired';
  if (hasTrial) return 'trial_expired';
  return 'unregistered';
}

/** 组装客户端的 `LicenseState`。 */
async function buildState(env, device, now) {
  const card = await currentCard(env, device.device_id);
  const bonus = await bonusSummary(env, device.device_id, now);

  const cardRemainingMs = card && card.expire_at ? Math.max(0, card.expire_at - now) : 0;
  const trialExpireAt =
    device.trial_started_at != null
      ? device.trial_started_at + TRIAL_DAYS * DAY_MS
      : null;
  const trialRemainingMs = trialExpireAt ? Math.max(0, trialExpireAt - now) : 0;

  const status = resolveStatus({
    cardRemainingMs,
    trialRemainingMs,
    bonusRemainingMs: bonus.remainingMs,
    hasCard: Boolean(card),
    hasTrial: trialExpireAt != null,
  });

  // 展示用的剩余时长：卡密时长与试用时长二选一（有卡就以卡为准），再加推荐奖励。
  // 试用期不能漏掉——否则试用中的设备 `remainingMs` 为 0，客户端会显示
  // 「已到期」，可状态又是「试用中」且功能可用，前后矛盾；
  // 也不能与试用相加，同一段时间会被数两遍，所以取最大值。
  const remainingMs = Math.max(cardRemainingMs, trialRemainingMs) + bonus.remainingMs;

  return {
    ok: true,
    status,
    type: card ? card.type : null,
    days: card ? card.days : null,
    expireAt: card && card.expire_at ? card.expire_at : null,
    bonusDays: bonus.grantedDays,
    bonusMs: bonus.remainingMs,
    remainingDays: toDays(remainingMs),
    remainingMs,
    serverTime: now,
  };
}

// ---------------------------------------------------------------- 邀请码

/** 去掉容易看混的 0/O/1/I，用户报码时少一半口误。 */
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

function randomCode() {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  let out = '';
  for (const byte of bytes) {
    out += CODE_ALPHABET[byte % CODE_ALPHABET.length];
  }
  return out;
}

async function ensureInviteCode(env, device) {
  if (device.code) return device.code;

  // 32^6 ≈ 10 亿，碰撞概率极低；仍然重试几次，撞了就换。
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const candidate = randomCode();
    const taken = await env.DB.prepare(
      'SELECT 1 AS hit FROM devices WHERE code = ?'
    )
      .bind(candidate)
      .first();
    if (!taken) {
      await env.DB.prepare('UPDATE devices SET code = ? WHERE device_id = ?')
        .bind(candidate, device.device_id)
        .run();
      device.code = candidate;
      return candidate;
    }
  }

  throw new Error('invite_code_exhausted');
}

// ---------------------------------------------------------------- 推荐结算

/**
 * 结算推荐人当前应得的奖励。
 *
 * 每次被推荐人达成条件（连续使用满 3 天）都会重算一遍：先数「合格人数」，
 * 再对照阶梯补发还没发过的档位。**按档位补发而不是逐级累加**，
 * 所以中途漏发或多发都能自愈。
 */
async function settleReferralTiers(env, inviterDeviceId, now) {
  const { results } = await env.DB.prepare(
    `SELECT device_id FROM devices
      WHERE inviter_code = (SELECT code FROM devices WHERE device_id = ?)
        AND referral_qualified = 1`
  )
    .bind(inviterDeviceId)
    .all();

  const invitedCount = (results || []).length;
  const awarded = new Set();

  const existing = await env.DB.prepare(
    "SELECT tier FROM referral_awards WHERE inviter_device = ? AND kind = 'tier'"
  )
    .bind(inviterDeviceId)
    .all();
  for (const row of existing.results || []) awarded.add(row.tier);

  const { grantedDays } = await bonusSummary(env, inviterDeviceId, now);
  let used = grantedDays;

  for (let index = 0; index < REFERRAL_TIERS.length; index += 1) {
    const tier = REFERRAL_TIERS[index];
    if (invitedCount < tier.count) continue;
    if (awarded.has(index)) continue;

    // 封顶：超出部分直接不发，已发放的也不回收。
    const days = Math.min(tier.days, Math.max(0, REFERRAL_CAP_DAYS - used));
    if (days <= 0) continue;

    await env.DB.prepare(
      `INSERT OR IGNORE INTO referral_awards
         (inviter_device, invited_device, kind, tier, days, granted_at, expire_at)
       VALUES (?, NULL, 'tier', ?, ?, ?, ?)`
    )
      .bind(inviterDeviceId, index, days, now, now + days * DAY_MS)
      .run();
    used += days;
  }
}

/** 被推荐人付费后，给推荐人发一次性的「付费奖励」。 */
async function settlePaidBonus(env, invitedDevice, now) {
  if (!invitedDevice.inviter_code) return;

  const inviter = await env.DB.prepare('SELECT * FROM devices WHERE code = ?')
    .bind(invitedDevice.inviter_code)
    .first();
  if (!inviter) return;

  const already = await env.DB.prepare(
    `SELECT 1 AS hit FROM referral_awards
      WHERE inviter_device = ? AND invited_device = ? AND kind = 'paid'`
  )
    .bind(inviter.device_id, invitedDevice.device_id)
    .first();
  if (already) return;

  const { grantedDays } = await bonusSummary(env, inviter.device_id, now);
  const days = Math.min(
    REFERRAL_PAID_BONUS_DAYS,
    Math.max(0, REFERRAL_CAP_DAYS - grantedDays)
  );
  if (days <= 0) return;

  await env.DB.prepare(
    `INSERT OR IGNORE INTO referral_awards
       (inviter_device, invited_device, kind, tier, days, granted_at, expire_at)
     VALUES (?, ?, 'paid', NULL, ?, ?, ?)`
  )
    .bind(inviter.device_id, invitedDevice.device_id, days, now, now + days * DAY_MS)
    .run();
}

// ---------------------------------------------------------------- 路由处理

async function handleVerify(env, body) {
  const deviceId = normalizeDevice(body.deviceId);
  if (!deviceId) return fail('bad_device', '缺少 deviceId');

  const now = Date.now();
  const device = await ensureDevice(env, deviceId, now);
  return json(await buildState(env, device, now));
}

async function handleActivate(env, body) {
  const deviceId = normalizeDevice(body.deviceId);
  const cardKey = normalizeCardKey(body.cardKey);
  if (!deviceId) return fail('bad_device', '缺少 deviceId');
  if (!cardKey) return fail('bad_card', '缺少 cardKey');

  const now = Date.now();
  const card = await env.DB.prepare('SELECT * FROM cards WHERE card_key = ?')
    .bind(cardKey)
    .first();

  if (!card) {
    return fail('card_not_found', '卡密不存在，请核对后重试', 404);
  }
  if (card.device_id && card.device_id !== deviceId) {
    return fail('card_bound', '该卡密已绑定其他设备', 409);
  }

  const alreadyActivated = card.device_id === deviceId;

  // 同一张卡在同一设备重复激活：**不再叠加天数**。
  // 不拦的话，同一个卡密反复输入就能刷出无限时长（每输一次 +30 天），
  // 这是个纯亏钱的洞。要续费得买新卡，这里只把当前状态原样回给客户端。
  if (alreadyActivated) {
    return json({
      ok: true,
      alreadyActivated: true,
      type: card.type,
      days: card.days,
      expireAt: card.expire_at,
      remainingDays: toDays(Math.max(0, (card.expire_at || 0) - now)),
    });
  }

  const device = await ensureDevice(env, deviceId, now);

  // 续费叠加：新时长接在现有到期时间之后，而不是把它覆盖掉。
  const existing = await currentCard(env, deviceId);
  const base = Math.max(now, existing && existing.expire_at ? existing.expire_at : 0);
  const expireAt = base + card.days * DAY_MS;

  await env.DB.prepare(
    `UPDATE cards
        SET device_id = ?, activated_at = COALESCE(activated_at, ?), expire_at = ?
      WHERE card_key = ?`
  )
    .bind(deviceId, now, expireAt, cardKey)
    .run();

  await settlePaidBonus(env, device, now);

  return json({
    ok: true,
    alreadyActivated,
    type: card.type,
    days: card.days,
    expireAt,
    remainingDays: toDays(Math.max(0, expireAt - now)),
  });
}

async function handleUnbind(env, body) {
  const deviceId = normalizeDevice(body.deviceId);
  const cardKey = normalizeCardKey(body.cardKey);
  if (!deviceId || !cardKey) return fail('bad_request', '缺少 deviceId 或 cardKey');

  const card = await env.DB.prepare('SELECT * FROM cards WHERE card_key = ?')
    .bind(cardKey)
    .first();

  if (!card) return fail('card_not_found', '卡密不存在', 404);
  if (card.device_id !== deviceId) {
    return fail('not_bound_to_device', '这张卡密不在当前设备上', 409);
  }
  if (card.unbind_count >= 1) {
    return fail('unbind_limit', '每张卡密只能自助解绑 1 次，请联系客服', 409);
  }

  await env.DB.prepare(
    `UPDATE cards
        SET device_id = NULL, expire_at = NULL, unbind_count = unbind_count + 1
      WHERE card_key = ?`
  )
    .bind(cardKey)
    .run();

  return json({ ok: true, alreadyActivated: false, type: card.type, days: card.days });
}

async function handleReferralCode(env, body) {
  const deviceId = normalizeDevice(body.deviceId);
  if (!deviceId) return fail('bad_device', '缺少 deviceId');

  const now = Date.now();
  const device = await ensureDevice(env, deviceId, now);
  await ensureInviteCode(env, device);

  return json(await referralStatus(env, device, now));
}

async function handleReferralBind(env, body) {
  const deviceId = normalizeDevice(body.deviceId);
  const code = typeof body.code === 'string' ? body.code.trim().toUpperCase() : '';
  if (!deviceId) return fail('bad_device', '缺少 deviceId');
  if (!code) return fail('bad_code', '请填写邀请码');

  const now = Date.now();
  const device = await ensureDevice(env, deviceId, now);

  if (device.inviter_code) {
    return fail('already_bound', '本设备已经填写过邀请码', 409);
  }

  const inviter = await env.DB.prepare('SELECT * FROM devices WHERE code = ?')
    .bind(code)
    .first();
  if (!inviter) return fail('code_not_found', '邀请码不存在', 404);
  if (inviter.device_id === deviceId) {
    return fail('self_referral', '不能填写自己的邀请码', 409);
  }

  await env.DB.prepare('UPDATE devices SET inviter_code = ? WHERE device_id = ?')
    .bind(code, deviceId)
    .run();

  device.inviter_code = code;
  return json(await referralStatus(env, device, now));
}

/**
 * 使用心跳。每天最多记一次，用于判定「连续使用 3 天」。
 *
 * 日期用 UTC 的 yyyy-MM-dd，与客户端 `LicenseManager` 的去重口径一致。
 */
async function handleReferralHeartbeat(env, body) {
  const deviceId = normalizeDevice(body.deviceId);
  if (!deviceId) return fail('bad_device', '缺少 deviceId');

  const now = Date.now();
  const device = await ensureDevice(env, deviceId, now);
  const today = dayKey(now);

  if (device.last_heartbeat_day !== today) {
    const isConsecutive = device.last_heartbeat_day === dayKeyBefore(today);
    const streak = isConsecutive ? (device.streak_days || 0) + 1 : 1;

    const qualified =
      device.referral_qualified === 1 ||
      (device.inviter_code && streak >= REFERRAL_REQUIRED_DAYS) ? 1 : 0;

    await env.DB.prepare(
      `UPDATE devices
          SET streak_days = ?, last_heartbeat_day = ?, referral_qualified = ?
        WHERE device_id = ?`
    )
      .bind(streak, today, qualified, deviceId)
      .run();

    device.streak_days = streak;
    device.last_heartbeat_day = today;
    device.referral_qualified = qualified;

    if (qualified) {
      const inviter = await env.DB.prepare('SELECT * FROM devices WHERE code = ?')
        .bind(device.inviter_code)
        .first();
      if (inviter) await settleReferralTiers(env, inviter.device_id, now);
    }
  }

  return json(await referralStatus(env, device, now));
}

async function handleReferralStatus(env, body) {
  const deviceId = normalizeDevice(body.deviceId);
  if (!deviceId) return fail('bad_device', '缺少 deviceId');

  const now = Date.now();
  const device = await ensureDevice(env, deviceId, now);
  return json(await referralStatus(env, device, now));
}

/** 组装客户端的 `ReferralStatus`。 */
async function referralStatus(env, device, now) {
  const { grantedDays, remainingMs } = await bonusSummary(env, device.device_id, now);

  const { results } = await env.DB.prepare(
    `SELECT d.device_id FROM devices d
      WHERE d.inviter_code = (SELECT code FROM devices WHERE device_id = ?)
        AND d.referral_qualified = 1`
  )
    .bind(device.device_id)
    .all();

  const invitedCount = (results || []).length;

  const paidRows = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM referral_awards
      WHERE inviter_device = ? AND kind = 'paid'`
  )
    .bind(device.device_id)
    .first();

  const awardedRows = await env.DB.prepare(
    "SELECT tier FROM referral_awards WHERE inviter_device = ? AND kind = 'tier'"
  )
    .bind(device.device_id)
    .all();
  const awardedTiers = (awardedRows.results || [])
    .map((row) => row.tier)
    .filter((tier) => tier != null)
    .sort((a, b) => a - b);

  const nextIndex = REFERRAL_TIERS.findIndex((tier) => invitedCount < tier.count);
  const nextTier = nextIndex === -1 ? null : {
    count: REFERRAL_TIERS[nextIndex].count,
    days: REFERRAL_TIERS[nextIndex].days,
  };
  const towardNext = nextTier ? nextTier.count - invitedCount : 0;

  let asReferred = null;
  if (device.inviter_code) {
    asReferred = {
      inviterCode: device.inviter_code,
      streakDays: device.streak_days || 0,
      qualified: device.referral_qualified === 1,
      requiredDays: REFERRAL_REQUIRED_DAYS,
    };
  }

  return {
    ok: true,
    code: device.code || null,
    invitedCount,
    paidCount: paidRows ? paidRows.n : 0,
    bonusDays: grantedDays,
    awardedTiers,
    nextTier,
    towardNext,
    capDays: REFERRAL_CAP_DAYS,
    bonusRemainingDays: toDays(remainingMs),
    asReferred,
  };
}

// ---------------------------------------------------------------- 入口

const ROUTES = {
  '/api/verify': handleVerify,
  '/api/activate': handleActivate,
  '/api/unbind': handleUnbind,
  '/api/referral/code': handleReferralCode,
  '/api/referral/bind': handleReferralBind,
  '/api/referral/heartbeat': handleReferralHeartbeat,
  '/api/referral/status': handleReferralStatus,
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const handler = ROUTES[url.pathname];

    if (!handler) {
      return fail('not_found', '没有这个接口', 404);
    }
    if (request.method !== 'POST') {
      return fail('method_not_allowed', '该接口只接受 POST', 405);
    }

    try {
      return await handler(env, await readBody(request));
    } catch (error) {
      // 直接把堆栈丢给客户端既没用也不安全，只在日志里留全量。
      console.error('unhandled', url.pathname, error && error.stack);
      return fail('server_error', '服务端异常，请稍后重试', 500);
    }
  },
};

// 供单元测试直接引用，不需要另外复制一份常量。
export const __test__ = {
  DAY_MS,
  TRIAL_DAYS,
  REFERRAL_REQUIRED_DAYS,
  REFERRAL_PAID_BONUS_DAYS,
  REFERRAL_CAP_DAYS,
  REFERRAL_TIERS,
  CARD_TYPES,
  normalizeCardKey,
  normalizeDevice,
  dayKey,
};
