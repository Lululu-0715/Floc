/**
 * 测试用的最小 D1 替身。
 *
 * 直接跑真实 SQLite（Node 22 内置 `node:sqlite`），而不是手写一个假的
 * 查询引擎：schema 里的 `INSERT OR IGNORE`、表达式唯一索引这些恰恰是最
 * 容易出错的地方，用假引擎测等于没测。
 *
 * 只需把 D1 的三个方法（first / all / run）对上即可。
 */
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCHEMA = join(HERE, '..', 'schema.sql');

class Statement {
  constructor(db, sql) {
    this.db = db;
    this.sql = sql;
    this.params = [];
  }

  bind(...params) {
    // D1 允许链式 bind，且返回新对象；这里沿用同样的语义。
    const next = new Statement(this.db, this.sql);
    next.params = params;
    return next;
  }

  async first() {
    const row = this.db.prepare(this.sql).get(...this.params);
    return row === undefined ? null : row;
  }

  async all() {
    const rows = this.db.prepare(this.sql).all(...this.params);
    return { results: rows, success: true };
  }

  async run() {
    const info = this.db.prepare(this.sql).run(...this.params);
    return { success: true, meta: info };
  }
}

class FakeD1 {
  constructor() {
    this.db = new DatabaseSync(':memory:');
    this.db.exec(readFileSync(SCHEMA, 'utf8'));
  }

  prepare(sql) {
    return new Statement(this.db, sql);
  }

  /** 测试里直接改数据用，比如把上次心跳挪到「昨天」。 */
  exec(sql) {
    this.db.exec(sql);
  }

  query(sql) {
    return this.db.prepare(sql).all();
  }
}

/** 起一个全新的环境，每个用例一份，互不干扰。 */
export function createEnv() {
  return { DB: new FakeD1() };
}

/** 按 Worker 的入口契约发一个 POST，返回 { status, body }。 */
export async function call(worker, env, path, body) {
  const response = await worker.fetch(
    new Request('https://floc-license.test' + path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body ?? {}),
    }),
    env
  );

  return { status: response.status, body: await response.json() };
}

export const DAY_MS = 86_400_000;

export const dayKey = (ms) => new Date(ms).toISOString().slice(0, 10);
