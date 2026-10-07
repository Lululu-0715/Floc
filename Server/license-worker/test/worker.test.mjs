/**
 * Floc 授权 / 推荐服务端单元测试。
 *
 * 跑法：
 *     cd Server/license-worker && npm test
 *
 * 用 Node 22 内置的 `node:test` + 真实 SQLite（见 `harness.mjs`），
 * 不引入任何第三方依赖——这个仓库里所有测试都要求「克隆下来就能跑」。
 *
 * 时间相关的用例统一用 `at(时间戳, fn)` 冻结 `Date.now`：连续使用天数、
 * 到期叠加都跟「现在几点」强相关，靠 sleep 等待既慢又不稳。
 */
import test from 'node:test';
import assert from 'node:assert/strict';

import worker, { __test__ } from '../src/index.js';
import { createEnv, call, DAY_MS, dayKey } from './harness.mjs';

// ---------------------------------------------------------------- 小工具

/** 在指定时间戳下执行，期间 `Date.now()` 固定。 */
async function at(ms, fn) {
  const real = Date.now;
  Date.now = () => ms;
  try {
    return await fn();
  } finally {
    Date.now = real;
  }
}

/** 往卡密表里塞一张卡（测试专用，直接走 SQL 省一个管理接口）。 */
function addCard(env, key, type, days) {
  env.DB.exec(
    `INSERT INTO cards (card_key, type, days, created_at) VALUES ('${key}', '${type}', ${days}, 0)`
  );
}

/** 绕过心跳流程，直接造一个「已达标」的被推荐人，用来测阶梯补发。 */
function addQualifiedInvite(env, deviceId, code, createdAt) {
  env.DB.exec(
    `INSERT INTO devices (device_id, inviter_code, streak_days, referral_qualified, created_at)
     VALUES ('${deviceId}', '${code}', 3, 1, ${createdAt})`
  );
}

const T0 = Date.UTC(2026, 0, 1, 12);      // 2026-01-01 12:00 UTC，离日界足够远
const DAY = (n) => T0 + n * DAY_MS;

// ---------------------------------------------------------------- 常量同步

test('常量与客户端 LicenseConfig 保持一致', () => {
  // 这两组数字客户端也存了一份，改动必须成对同步，
  // 否则会出现「客户端按 3 天算、服务端按 7 天算」这种查不出原因的错位。
  assert.equal(__test__.TRIAL_DAYS, 3);
  assert.equal(__test__.REFERRAL_REQUIRED_DAYS, 3);
  assert.equal(__test__.REFERRAL_PAID_BONUS_DAYS, 15);
  assert.equal(__test__.REFERRAL_CAP_DAYS, 365 * 3);

  assert.deepEqual(__test__.REFERRAL_TIERS, [
    { count: 3, days: 7 },
    { count: 7, days: 15 },
    { count: 15, days: 30 },
    { count: 30, days: 90 },
    { count: 50, days: 180 },
    { count: 100, days: 365 },
  ]);
});

// ---------------------------------------------------------------- 卡密规范化

test('卡密规范化：手打形态都要认得', () => {
  const n = __test__.normalizeCardKey;

  // 空格换成连字符（而不是删掉）——这是用户最常手打的形态
  assert.equal(n(' floc test 2026 '), 'FLOC-TEST-2026');
  assert.equal(n('FLOC\tTEST'), 'FLOC-TEST');
  // 全角连字符 / 破折号
  assert.equal(n('floc—test－2026'), 'FLOC-TEST-2026');
  // 连续连字符折叠、首尾掐掉
  assert.equal(n('--floc--test--'), 'FLOC-TEST');
  // 大小写不敏感
  assert.equal(n('Floc-Test-2026'), 'FLOC-TEST-2026');

  assert.equal(n(''), '');
  assert.equal(n(null), '');
  assert.equal(n(undefined), '');
  assert.equal(n(20260101), '');
});

test('设备 ID 统一小写去空格', () => {
  assert.equal(__test__.normalizeDevice('  ABC-DEF  '), 'abc-def');
  assert.equal(__test__.normalizeDevice(null), '');
});

// ---------------------------------------------------------------- 试用

test('首次 verify 自动开始试用，剩余时长落在 remainingMs 里', async () => {
  const env = createEnv();

  const { status, body } = await at(T0, () =>
    call(worker, env, '/api/verify', { deviceId: 'DEV-1' })
  );

  assert.equal(status, 200);
  assert.equal(body.ok, true);
  assert.equal(body.status, 'trial');
  assert.equal(body.serverTime, T0);
  // 试用剩余必须计入：漏掉的话客户端设置页会在「试用中」的同时
  // 显示「已到期」，前后矛盾。
  assert.equal(body.remainingMs, __test__.TRIAL_DAYS * DAY_MS);
  assert.equal(body.remainingDays, 3);

  assert.equal(env.DB.query('SELECT COUNT(*) AS n FROM devices')[0].n, 1);
});

test('重复 verify 不会重复建设备，试用起点也不刷新', async () => {
  const env = createEnv();

  await at(T0, () => call(worker, env, '/api/verify', { deviceId: 'dev-1' }));
  // 第二次用不同大小写：规范化后应当命中同一行
  const { body } = await at(DAY(1), () => call(worker, env, '/api/verify', { deviceId: 'DEV-1' }));

  assert.equal(env.DB.query('SELECT COUNT(*) AS n FROM devices')[0].n, 1);
  assert.equal(body.status, 'trial');
  // 已经过了 1 天，剩余应为 2 天
  assert.equal(body.remainingMs, 2 * DAY_MS);
});

test('试用到期后状态变为 trial_expired', async () => {
  const env = createEnv();

  await at(T0, () => call(worker, env, '/api/verify', { deviceId: 'DEV-1' }));
  const { body } = await at(DAY(4), () => call(worker, env, '/api/verify', { deviceId: 'DEV-1' }));

  assert.equal(body.status, 'trial_expired');
  assert.equal(body.remainingMs, 0);
});

test('缺少 deviceId 直接拒绝', async () => {
  const env = createEnv();
  const { status, body } = await at(T0, () => call(worker, env, '/api/verify', {}));

  assert.equal(status, 400);
  assert.equal(body.ok, false);
  assert.equal(body.error, 'bad_device');
});

// ---------------------------------------------------------------- 激活

test('激活卡密：卡密先规范化再查库，到期时间 = now + 天数', async () => {
  const env = createEnv();
  addCard(env, 'FLOC-MONTH-0001', 'month', 30);

  // 故意用「空格分隔 + 小写」输入，验证两边规范化规则一致
  const { status, body } = await at(T0, () =>
    call(worker, env, '/api/activate', { deviceId: 'D1', cardKey: 'floc month 0001' })
  );

  assert.equal(status, 200);
  assert.equal(body.ok, true);
  assert.equal(body.type, 'month');
  assert.equal(body.days, 30);
  assert.equal(body.expireAt, T0 + 30 * DAY_MS);

  const state = (await at(T0, () => call(worker, env, '/api/verify', { deviceId: 'D1' }))).body;
  assert.equal(state.status, 'active');
  assert.equal(state.type, 'month');
  assert.equal(state.remainingMs, 30 * DAY_MS);
  assert.equal(state.days, 30);
});

test('续费叠加：新卡接在旧到期时间之后，而不是把它覆盖掉', async () => {
  const env = createEnv();
  addCard(env, 'FLOC-A', 'month', 30);
  addCard(env, 'FLOC-B', 'month', 30);

  await at(T0, () => call(worker, env, '/api/activate', { deviceId: 'D1', cardKey: 'FLOC-A' }));

  // 用了 5 天之后再续一张
  const later = DAY(5);
  const { body } = await at(later, () =>
    call(worker, env, '/api/activate', { deviceId: 'D1', cardKey: 'FLOC-B' })
  );
  assert.equal(body.expireAt, T0 + 60 * DAY_MS);

  const state = (await at(later, () => call(worker, env, '/api/verify', { deviceId: 'D1' }))).body;
  assert.equal(state.remainingMs, 55 * DAY_MS);
});

test('同一张卡在同一设备重复激活：不再叠加天数', async () => {
  const env = createEnv();
  addCard(env, 'FLOC-A', 'month', 30);

  await at(T0, () => call(worker, env, '/api/activate', { deviceId: 'D1', cardKey: 'FLOC-A' }));
  // 隔一天又输了一遍同一张卡——不拦的话一张卡能刷出无限时长
  const { status, body } = await at(DAY(1), () =>
    call(worker, env, '/api/activate', { deviceId: 'D1', cardKey: 'FLOC-A' })
  );

  assert.equal(status, 200);
  assert.equal(body.ok, true);
  assert.equal(body.alreadyActivated, true);
  assert.equal(body.expireAt, T0 + 30 * DAY_MS, '到期时间不应被重新叠加');

  const state = (await at(DAY(1), () => call(worker, env, '/api/verify', { deviceId: 'D1' }))).body;
  assert.equal(state.remainingMs, 29 * DAY_MS);
});

test('卡密不存在 → 404，字段缺失 → 400', async () => {
  const env = createEnv();
  addCard(env, 'FLOC-A', 'month', 30);

  const missing = await at(T0, () =>
    call(worker, env, '/api/activate', { deviceId: 'D1', cardKey: 'FLOC-NOPE' })
  );
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error, 'card_not_found');

  const empty = await at(T0, () => call(worker, env, '/api/activate', { deviceId: 'D1' }));
  assert.equal(empty.status, 400);
  assert.equal(empty.body.error, 'bad_card');
});

test('卡密已绑其他设备 → 409', async () => {
  const env = createEnv();
  addCard(env, 'FLOC-A', 'month', 30);

  await at(T0, () => call(worker, env, '/api/activate', { deviceId: 'D1', cardKey: 'FLOC-A' }));
  const { status, body } = await at(T0, () =>
    call(worker, env, '/api/activate', { deviceId: 'D2', cardKey: 'FLOC-A' })
  );

  assert.equal(status, 409);
  assert.equal(body.error, 'card_bound');

  // 原绑定不能被抢走
  const row = env.DB.query("SELECT device_id FROM cards WHERE card_key = 'FLOC-A'")[0];
  assert.equal(row.device_id, 'd1');
});

// ---------------------------------------------------------------- 解绑

test('解绑会释放设备，且每张卡只能自助解绑 1 次', async () => {
  const env = createEnv();
  addCard(env, 'FLOC-A', 'month', 30);

  await at(T0, () => call(worker, env, '/api/activate', { deviceId: 'D1', cardKey: 'FLOC-A' }));

  const first = await at(T0, () => call(worker, env, '/api/unbind', { deviceId: 'D1', cardKey: 'FLOC-A' }));
  assert.equal(first.body.ok, true);

  const row = env.DB.query("SELECT * FROM cards WHERE card_key = 'FLOC-A'")[0];
  assert.equal(row.device_id, null);
  assert.equal(row.expire_at, null);
  assert.equal(row.unbind_count, 1);

  // 同一台机器再解一次：卡已经不在它名下了
  const again = await at(T0, () => call(worker, env, '/api/unbind', { deviceId: 'D1', cardKey: 'FLOC-A' }));
  assert.equal(again.status, 409);
  assert.equal(again.body.error, 'not_bound_to_device');

  // 换到新机器上激活、再解绑，这次该被次数限制拦住
  await at(T0, () => call(worker, env, '/api/activate', { deviceId: 'D2', cardKey: 'FLOC-A' }));
  const limited = await at(T0, () => call(worker, env, '/api/unbind', { deviceId: 'D2', cardKey: 'FLOC-A' }));
  assert.equal(limited.status, 409);
  assert.equal(limited.body.error, 'unbind_limit');
});

test('解绑不存在的卡密 → 404', async () => {
  const env = createEnv();
  const { status, body } = await at(T0, () =>
    call(worker, env, '/api/unbind', { deviceId: 'D1', cardKey: 'FLOC-NOPE' })
  );
  assert.equal(status, 404);
  assert.equal(body.error, 'card_not_found');
});

// ---------------------------------------------------------------- 邀请码

test('邀请码：6 位、不含易混字符、同一设备只会生成一次', async () => {
  const env = createEnv();

  const first = await at(T0, () => call(worker, env, '/api/referral/code', { deviceId: 'A' }));
  const code = first.body.code;

  assert.match(code, /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/);
  assert.doesNotMatch(code, /[0O1I]/);

  const second = await at(DAY(1), () => call(worker, env, '/api/referral/code', { deviceId: 'A' }));
  assert.equal(second.body.code, code);

  assert.equal(second.body.invitedCount, 0);
  assert.equal(second.body.nextTier.count, 3);
  assert.equal(second.body.towardNext, 3);
  assert.equal(second.body.capDays, __test__.REFERRAL_CAP_DAYS);
});

test('填写邀请码：不能填自己的、不能填不存在的、不能填两次', async () => {
  const env = createEnv();

  const code = (await at(T0, () => call(worker, env, '/api/referral/code', { deviceId: 'A' }))).body.code;

  const self = await at(T0, () => call(worker, env, '/api/referral/bind', { deviceId: 'A', code }));
  assert.equal(self.status, 409);
  assert.equal(self.body.error, 'self_referral');

  const ghost = await at(T0, () => call(worker, env, '/api/referral/bind', { deviceId: 'B', code: 'ZZZZZZ' }));
  assert.equal(ghost.status, 404);
  assert.equal(ghost.body.error, 'code_not_found');

  const ok = await at(T0, () => call(worker, env, '/api/referral/bind', { deviceId: 'B', code }));
  assert.equal(ok.body.ok, true);
  assert.equal(ok.body.asReferred.inviterCode, code);
  assert.equal(ok.body.asReferred.streakDays, 0);
  assert.equal(ok.body.asReferred.qualified, false);
  assert.equal(ok.body.asReferred.requiredDays, __test__.REFERRAL_REQUIRED_DAYS);

  const twice = await at(T0, () => call(worker, env, '/api/referral/bind', { deviceId: 'B', code }));
  assert.equal(twice.status, 409);
  assert.equal(twice.body.error, 'already_bound');
});

// ---------------------------------------------------------------- 连续使用

test('连续使用 3 天后达标；同一天重复上报只算一次', async () => {
  const env = createEnv();
  const code = (await at(T0, () => call(worker, env, '/api/referral/code', { deviceId: 'A' }))).body.code;
  await at(T0, () => call(worker, env, '/api/referral/bind', { deviceId: 'B', code }));

  const day0 = await at(DAY(0), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  assert.equal(day0.body.asReferred.streakDays, 1);

  // 同一天再打开一次 App —— 不该算成第 2 天
  const again = await at(DAY(0) + 3_600_000, () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  assert.equal(again.body.asReferred.streakDays, 1);

  const day1 = await at(DAY(1), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  assert.equal(day1.body.asReferred.streakDays, 2);
  assert.equal(day1.body.asReferred.qualified, false);

  const day2 = await at(DAY(2), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  assert.equal(day2.body.asReferred.streakDays, 3);
  assert.equal(day2.body.asReferred.qualified, true);

  // 只有 1 个被推荐人时还够不到 3 人档，这时不该发奖
  const statusA = (await at(DAY(2), () => call(worker, env, '/api/referral/status', { deviceId: 'A' }))).body;
  assert.equal(statusA.invitedCount, 1);
  assert.deepEqual(statusA.awardedTiers, []);
  assert.equal(statusA.bonusDays, 0);
  assert.equal(statusA.nextTier.count, 3);
  assert.equal(statusA.towardNext, 2);
});

test('中断一天则连续天数重置', async () => {
  const env = createEnv();
  const code = (await at(T0, () => call(worker, env, '/api/referral/code', { deviceId: 'A' }))).body.code;
  await at(T0, () => call(worker, env, '/api/referral/bind', { deviceId: 'B', code }));

  await at(DAY(0), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  // 跳过 DAY(1)，直接到 DAY(2)
  const after = await at(DAY(2), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  assert.equal(after.body.asReferred.streakDays, 1);
  assert.equal(after.body.asReferred.qualified, false);
});

test('心跳日期用 UTC 日界，与服务端 dayKey 口径一致', () => {
  // 同一天的 00:00 与 23:59 必须落在同一个 key 上
  assert.equal(dayKey(Date.UTC(2026, 0, 1, 0, 0, 0)), '2026-01-01');
  assert.equal(dayKey(Date.UTC(2026, 0, 1, 23, 59, 59)), '2026-01-01');
});

// ---------------------------------------------------------------- 阶梯奖励

test('阶梯奖励按档位补发，且重复结算不会多发', async () => {
  const env = createEnv();
  const code = (await at(T0, () => call(worker, env, '/api/referral/code', { deviceId: 'A' }))).body.code;

  // 先造 6 个已达标的老被推荐人
  for (let i = 0; i < 6; i += 1) addQualifiedInvite(env, `OLD-${i}`, code, T0);
  await at(T0, () => call(worker, env, '/api/referral/bind', { deviceId: 'B', code }));

  // 第 7 个走完整心跳流程：第 3 天达标时触发结算
  await at(DAY(0), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  await at(DAY(1), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  const reached = await at(DAY(2), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  assert.equal(reached.body.asReferred.qualified, true);

  // 7 人一次跨过 3 人档（7 天）与 7 人档（15 天）
  const afterFirst = (await at(DAY(2), () => call(worker, env, '/api/referral/status', { deviceId: 'A' }))).body;
  assert.equal(afterFirst.invitedCount, 7);
  assert.deepEqual(afterFirst.awardedTiers, [0, 1]);
  assert.equal(afterFirst.bonusDays, 22);
  assert.equal(afterFirst.nextTier.count, 15);
  assert.equal(afterFirst.towardNext, 8);

  // 再结算一次（第二天又上报）：已发的档位不该重发
  const later = await at(DAY(3), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  assert.equal(later.body.asReferred.streakDays, 4);
  const afterSecond = (await at(DAY(3), () => call(worker, env, '/api/referral/status', { deviceId: 'A' }))).body;
  assert.deepEqual(afterSecond.awardedTiers, [0, 1]);
  assert.equal(afterSecond.bonusDays, 22);
});

test('奖励剩余天数会随时间衰减，累计获得则只增不减', async () => {
  const env = createEnv();
  const code = (await at(T0, () => call(worker, env, '/api/referral/code', { deviceId: 'A' }))).body.code;
  for (let i = 0; i < 3; i += 1) addQualifiedInvite(env, `OLD-${i}`, code, T0);
  await at(T0, () => call(worker, env, '/api/referral/bind', { deviceId: 'B', code }));

  await at(DAY(0), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  await at(DAY(1), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));
  await at(DAY(2), () => call(worker, env, '/api/referral/heartbeat', { deviceId: 'B' }));

  const onDay2 = (await at(DAY(2), () => call(worker, env, '/api/referral/status', { deviceId: 'A' }))).body;
  assert.equal(onDay2.bonusDays, 7);
  assert.equal(onDay2.bonusRemainingDays, 7);

  // 过 2 天再看：累计仍是 7 天，剩余只剩 5 天
  const onDay4 = (await at(DAY(4), () => call(worker, env, '/api/referral/status', { deviceId: 'A' }))).body;
  assert.equal(onDay4.bonusDays, 7);
  assert.equal(onDay4.bonusRemainingDays, 5);

  // 只剩奖励时长可用时，状态是 bonus（试用早已过期、又没有卡密）
  const stateA = (await at(DAY(4), () => call(worker, env, '/api/verify', { deviceId: 'A' }))).body;
  assert.equal(stateA.status, 'bonus');
  assert.equal(stateA.remainingMs, 5 * DAY_MS);
});

// ---------------------------------------------------------------- 付费奖励

test('被推荐人付费 → 推荐人拿 15 天，且只发一次', async () => {
  const env = createEnv();
  addCard(env, 'FLOC-A', 'month', 30);
  addCard(env, 'FLOC-B', 'month', 30);

  const code = (await at(T0, () => call(worker, env, '/api/referral/code', { deviceId: 'A' }))).body.code;
  await at(T0, () => call(worker, env, '/api/referral/bind', { deviceId: 'B', code }));

  await at(T0, () => call(worker, env, '/api/activate', { deviceId: 'B', cardKey: 'FLOC-A' }));

  const afterPaid = (await at(T0, () => call(worker, env, '/api/referral/status', { deviceId: 'A' }))).body;
  assert.equal(afterPaid.paidCount, 1);
  assert.equal(afterPaid.bonusDays, __test__.REFERRAL_PAID_BONUS_DAYS);

  // 同一个被推荐人再买一张：不该再发一次
  await at(T0, () => call(worker, env, '/api/activate', { deviceId: 'B', cardKey: 'FLOC-B' }));
  const afterSecond = (await at(T0, () => call(worker, env, '/api/referral/status', { deviceId: 'A' }))).body;
  assert.equal(afterSecond.paidCount, 1);
  assert.equal(afterSecond.bonusDays, __test__.REFERRAL_PAID_BONUS_DAYS);
});

test('没有推荐人的设备付费不产生奖励', async () => {
  const env = createEnv();
  addCard(env, 'FLOC-A', 'month', 30);

  await at(T0, () => call(worker, env, '/api/activate', { deviceId: 'LONER', cardKey: 'FLOC-A' }));

  assert.equal(env.DB.query('SELECT COUNT(*) AS n FROM referral_awards')[0].n, 0);
});

test('付费奖励受累计封顶限制', async () => {
  const env = createEnv();
  addCard(env, 'FLOC-A', 'month', 30);

  const code = (await at(T0, () => call(worker, env, '/api/referral/code', { deviceId: 'A' }))).body.code;
  await at(T0, () => call(worker, env, '/api/referral/bind', { deviceId: 'B', code }));

  // 直接塞一笔接近封顶的奖励（1090 天），只剩 5 天的额度
  env.DB.exec(
    `INSERT INTO referral_awards (inviter_device, invited_device, kind, tier, days, granted_at, expire_at)
     VALUES ('a', 'ghost', 'tier', 99, 1090, ${T0}, ${T0 + 1090 * DAY_MS})`
  );

  await at(T0, () => call(worker, env, '/api/activate', { deviceId: 'B', cardKey: 'FLOC-A' }));

  const status = (await at(T0, () => call(worker, env, '/api/referral/status', { deviceId: 'A' }))).body;
  assert.equal(status.bonusDays, __test__.REFERRAL_CAP_DAYS);

  const paid = env.DB.query("SELECT days FROM referral_awards WHERE kind = 'paid'")[0];
  assert.equal(paid.days, 5, '超出封顶的部分不该发放');
});

// ---------------------------------------------------------------- 入口

test('未知路径 → 404，非 POST → 405', async () => {
  const env = createEnv();

  const unknown = await worker.fetch(new Request('https://floc-license.test/api/nope', { method: 'POST' }), env);
  assert.equal(unknown.status, 404);
  assert.equal((await unknown.json()).error, 'not_found');

  const wrongMethod = await worker.fetch(new Request('https://floc-license.test/api/verify', { method: 'GET' }), env);
  assert.equal(wrongMethod.status, 405);
  assert.equal((await wrongMethod.json()).error, 'method_not_allowed');
});

test('请求体不是合法 JSON 时不抛 500', async () => {
  const env = createEnv();

  const response = await worker.fetch(
    new Request('https://floc-license.test/api/verify', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{oops',
    }),
    env
  );

  // 读不出 body 就当空对象，最后由参数校验拒绝，而不是 500
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error, 'bad_device');
});
