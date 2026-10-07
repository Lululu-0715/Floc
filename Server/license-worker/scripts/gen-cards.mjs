#!/usr/bin/env node
/**
 * 批量生成卡密。
 *
 * 用法：
 *   node scripts/gen-cards.mjs --type month --count 50
 *   node scripts/gen-cards.mjs --type year  --count 10 --note "淘宝-2026-03"
 *   node scripts/gen-cards.mjs --type month --count 20 --days 45 --note "双十一加量卡"
 *
 * 会产出两个文件（默认写在 ./out/ 下）：
 *
 *   out/cards-<时间戳>.sql   可直接灌库：npx wrangler d1 execute floc-license --remote --file=./out/xxx.sql
 *   out/cards-<时间戳>.txt   卡密清单，拿去发给买家 / 导入发货系统
 *
 * 为什么生成 SQL 而不是直连数据库：D1 只能通过 wrangler 访问，
 * 让脚本自己去调 wrangler 会把「需要交互登录」这一步藏进脚本里，
 * 出错时很难查。生成 SQL 让用户显式执行一次，更可控也更透明。
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = resolve(HERE, '..', 'out');

/** 与 Worker 里的 CARD_TYPES 保持一致。 */
const CARD_TYPES = {
  month: 30,
  quarter: 90,
  halfyear: 180,
  year: 365,
};

/** 去掉容易看混的 0/O/1/I —— 卡密是要用户手输的，能少一半口误。 */
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/** 每组长度与组数：`FLOC-XXXX-XXXX-XXXX`，32^12 空间足够。 */
const GROUP_SIZE = 4;
const GROUP_COUNT = 3;

function parseArgs(argv) {
  const options = { type: null, count: null, days: null, note: '', prefix: 'FLOC' };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      const value = argv[i + 1];
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`参数 ${arg} 后面缺少值`);
      }
      i += 1;
      return value;
    };

    switch (arg) {
      case '--type':   options.type = next(); break;
      case '--count':  options.count = Number(next()); break;
      case '--days':   options.days = Number(next()); break;
      case '--note':   options.note = next(); break;
      case '--prefix': options.prefix = next().toUpperCase(); break;
      case '--help':
      case '-h':
        options.help = true;
        break;
      default:
        throw new Error(`无法识别的参数：${arg}`);
    }
  }

  return options;
}

function usage() {
  return [
    '批量生成卡密',
    '',
    '  node scripts/gen-cards.mjs --type <类型> --count <数量> [选项]',
    '',
    '必填：',
    '  --type    卡密类型，可选：' + Object.keys(CARD_TYPES).join(' / '),
    '  --count   生成张数',
    '',
    '可选：',
    '  --days    覆盖天数（做「活动卡」用，不填则按类型的天数）',
    '  --note    备注，写进 cards.note，方便对账',
    '  --prefix  卡密前缀，默认 FLOC',
    '  --help    显示这份说明',
  ].join('\n');
}

/** 生成一个 `FLOC-XXXX-XXXX-XXXX` 形式的卡密。 */
function randomCardKey(prefix) {
  const groups = [];
  for (let g = 0; g < GROUP_COUNT; g += 1) {
    let group = '';
    for (let i = 0; i < GROUP_SIZE; i += 1) {
      // 用 crypto 而不是 Math.random：卡密是凭据，不能可预测
      const bytes = new Uint8Array(1);
      crypto.getRandomValues(bytes);
      group += ALPHABET[bytes[0] % ALPHABET.length];
    }
    groups.push(group);
  }
  return `${prefix}-${groups.join('-')}`;
}

function escapeSql(value) {
  return String(value).replace(/'/g, "''");
}

function stamp(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate()),
  ].join('') + '-' + [pad(date.getHours()), pad(date.getMinutes()), pad(date.getSeconds())].join('');
}

function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`参数错误：${error.message}\n`);
    console.error(usage());
    process.exit(1);
  }

  if (options.help) {
    console.log(usage());
    return;
  }

  const { type, count, prefix } = options;

  if (!type || !(type in CARD_TYPES)) {
    console.error(`--type 必填，且必须是 ${Object.keys(CARD_TYPES).join(' / ')} 之一\n`);
    console.error(usage());
    process.exit(1);
  }
  if (!Number.isInteger(count) || count <= 0) {
    console.error('--count 必须是正整数\n');
    console.error(usage());
    process.exit(1);
  }

  const days = options.days ?? CARD_TYPES[type];
  if (!Number.isInteger(days) || days <= 0) {
    console.error('--days 必须是正整数');
    process.exit(1);
  }

  if (!/^[A-Z0-9]{2,8}$/.test(prefix)) {
    console.error('--prefix 只能是 2~8 位大写字母或数字');
    process.exit(1);
  }

  const keys = new Set();
  while (keys.size < count) keys.add(randomCardKey(prefix));

  const keyList = [...keys].sort();
  const now = Date.now();
  const note = options.note;

  // 用 INSERT OR IGNORE：撞上已有卡密时跳过而不是整个脚本失败。
  const sql = [
    `-- Floc 卡密批量生成 · ${new Date(now).toISOString()}`,
    `-- 类型 ${type}（${days} 天）· ${keyList.length} 张${note ? ` · 备注 ${note}` : ''}`,
    '-- 应用：npx wrangler d1 execute floc-license --remote --file=./out/<本文件>',
    '',
    'INSERT OR IGNORE INTO cards (card_key, type, days, note, created_at) VALUES',
    keyList
      .map((key) => `  ('${escapeSql(key)}', '${escapeSql(type)}', ${days}, ${note ? `'${escapeSql(note)}'` : 'NULL'}, ${now})`)
      .join(',\n') + ';',
    '',
  ].join('\n');

  mkdirSync(OUT_DIR, { recursive: true });
  const base = `cards-${type}-${stamp(new Date(now))}`;
  const sqlPath = join(OUT_DIR, `${base}.sql`);
  const txtPath = join(OUT_DIR, `${base}.txt`);

  writeFileSync(sqlPath, sql, 'utf8');
  writeFileSync(txtPath, keyList.join('\n') + '\n', 'utf8');

  console.log(`已生成 ${keyList.length} 张 ${type} 卡（每张 ${days} 天）`);
  console.log(`  SQL（灌库用）：${sqlPath}`);
  console.log(`  清单（发货用）：${txtPath}`);
  console.log('');
  console.log('下一步：');
  console.log(`  npx wrangler d1 execute floc-license --remote --file=${sqlPath.replace(resolve(HERE, '..') + '/', './')}`);
  console.log('');
  console.log('前 3 张预览：');
  for (const key of keyList.slice(0, 3)) console.log('  ' + key);
}

main();
