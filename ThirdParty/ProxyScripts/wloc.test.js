/**
 * wloc.js 改写逻辑的测试。
 *
 * 脚本本身面向代理客户端的脚本引擎，没有模块导出。测试的做法是：
 *   1. 提供一个最小的全局环境桩（$done / $response / console）；
 *   2. 用 Node 直接执行脚本源码；
 *   3. 断言 $done 收到的响应体确实是改写后的结果。
 *
 * 运行：node --test ThirdParty/ProxyScripts/
 */

import { test } from 'node:test';
import assert from 'node:assert';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const HERE = dirname(fileURLToPath(import.meta.url));
const WLOC_SOURCE = readFileSync(join(HERE, 'wloc.js'), 'utf8');
const SETTINGS_SOURCE = readFileSync(join(HERE, 'wloc-settings.js'), 'utf8');

// ---------------------------------------------------------------------------
// protobuf 测试数据构造（与 Core 侧测试保持一致的结构）
// ---------------------------------------------------------------------------

function writeVarint(value) {
  const out = [];
  let current = BigInt.asUintN(64, BigInt(value));
  while (current >= 0x80n) {
    out.push(Number(current & 0x7fn) | 0x80);
    current >>= 7n;
  }
  out.push(Number(current));
  return out;
}

function tag(number, wireType) {
  return writeVarint(BigInt(number * 8 + wireType));
}

function varintField(number, value) {
  return [...tag(number, 0), ...writeVarint(value)];
}

function lengthDelimited(number, payload) {
  return [...tag(number, 2), ...writeVarint(payload.length), ...payload];
}

function asciiBytes(text) {
  return Array.from(text, (ch) => ch.charCodeAt(0));
}

/** 构造一份 marker 信封包裹的 wloc 响应。 */
function buildSampleResponse() {
  const location = [
    ...varintField(1, 100),
    ...varintField(2, 200),
    ...varintField(3, 25),
  ];
  const device = [
    ...lengthDelimited(1, asciiBytes('aa:bb:cc:dd:ee:ff')),
    ...lengthDelimited(2, location),
  ];
  const payload = lengthDelimited(2, device);

  const magic = [0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00];
  return [
    ...magic,
    (payload.length >> 8) & 0xff,
    payload.length & 0xff,
    ...payload,
  ];
}

// ---------------------------------------------------------------------------
// 运行脚本
// ---------------------------------------------------------------------------

/**
 * 在沙箱里执行脚本，返回 $done 收到的参数。
 *
 * @param {string} source 脚本源码
 * @param {object} globals 注入的全局变量（$request、$response、$prefs 等）
 */
function runScript(source, globals) {
  let doneArg = undefined;

  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    $done: (arg) => { doneArg = arg; },
    JSON,
    Math,
    Number,
    String,
    Array,
    Object,
    BigInt,
    Date,
    decodeURIComponent,
    encodeURIComponent,
    ...globals,
  };

  vm.createContext(sandbox);
  vm.runInContext(source, sandbox, { timeout: 5000 });

  return doneArg;
}

/** 二进制字符串 → 字节数组 */
function toBytes(binaryString) {
  return Array.from(binaryString, (ch) => ch.charCodeAt(0) & 0xff);
}

/** 在最外层探测给定字段号是否存在，并返回其 varint 值。 */
function findVarint(bytes, fieldNumber) {
  let cursor = 0;
  while (cursor < bytes.length) {
    // 读 tag
    let value = 0n;
    let shift = 0n;
    const tagStart = cursor;
    while (cursor < bytes.length) {
      const byte = bytes[cursor];
      value |= BigInt(byte & 0x7f) << shift;
      cursor += 1;
      if ((byte & 0x80) === 0) break;
      shift += 7n;
    }
    if (cursor === tagStart) return null;

    const number = Number(value >> 3n);
    const wireType = Number(value & 7n);

    if (wireType === 0) {
      let itemValue = 0n;
      let itemShift = 0n;
      while (cursor < bytes.length) {
        const byte = bytes[cursor];
        itemValue |= BigInt(byte & 0x7f) << itemShift;
        cursor += 1;
        if ((byte & 0x80) === 0) break;
        itemShift += 7n;
      }
      if (number === fieldNumber) return itemValue;
    } else if (wireType === 2) {
      let length = 0n;
      let lengthShift = 0n;
      while (cursor < bytes.length) {
        const byte = bytes[cursor];
        length |= BigInt(byte & 0x7f) << lengthShift;
        cursor += 1;
        if ((byte & 0x80) === 0) break;
        lengthShift += 7n;
      }
      const size = Number(length);
      if (number === fieldNumber) return bytes.slice(cursor, cursor + size);
      cursor += size;
    } else if (wireType === 1) {
      cursor += 8;
    } else if (wireType === 5) {
      cursor += 4;
    } else {
      return null;
    }
  }
  return null;
}

/** 在整棵嵌套结构里递归查找字段。 */
function findVarintDeep(bytes, fieldNumber) {
  const direct = findVarint(bytes, fieldNumber);
  if (direct !== null && typeof direct === 'bigint') return direct;

  let cursor = 0;
  while (cursor < bytes.length) {
    let value = 0n;
    let shift = 0n;
    while (cursor < bytes.length) {
      const byte = bytes[cursor];
      value |= BigInt(byte & 0x7f) << shift;
      cursor += 1;
      if ((byte & 0x80) === 0) break;
      shift += 7n;
    }
    const number = Number(value >> 3n);
    const wireType = Number(value & 7n);

    if (wireType === 2) {
      let length = 0n;
      let lengthShift = 0n;
      while (cursor < bytes.length) {
        const byte = bytes[cursor];
        length |= BigInt(byte & 0x7f) << lengthShift;
        cursor += 1;
        if ((byte & 0x80) === 0) break;
        lengthShift += 7n;
      }
      const size = Number(length);
      const inner = bytes.slice(cursor, cursor + size);
      cursor += size;
      const found = findVarintDeep(inner, fieldNumber);
      if (found !== null) return found;
    } else if (wireType === 0) {
      while (cursor < bytes.length) {
        const byte = bytes[cursor];
        cursor += 1;
        if ((byte & 0x80) === 0) break;
      }
    } else if (wireType === 1) {
      cursor += 8;
    } else if (wireType === 5) {
      cursor += 4;
    } else {
      return null;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

/** 断言 $done 收到的是「不做修改」的空对象。
 *
 * 不能用 assert.deepStrictEqual(result, {})：结果对象产生在 vm 沙箱里，
 * 它的原型是沙箱自己的 Object.prototype，与宿主侧的 {} 原型不同，
 * deepStrictEqual 会因原型不等而失败。这里只比较可观察的结构。
 */
function assertPassthrough(result) {
  assert.ok(result !== undefined, '$done 必须被调用');
  assert.ok(result !== null && typeof result === 'object', '$done 参数必须是对象');
  assert.strictEqual(
    Object.keys(result).length,
    0,
    `放行时不应修改响应，实际带了字段：${Object.keys(result).join(',')}`
  );
}

test('未启用时原样放行', () => {
  const response = buildSampleResponse();
  const result = runScript(WLOC_SOURCE, {
    $response: { body: String.fromCharCode(...response) },
    $persistentStore: { read: () => null },
  });

  assertPassthrough(result);
});

test('启用后改写坐标', () => {
  const response = buildSampleResponse();
  const settings = JSON.stringify({
    enabled: true,
    latitude: 22.281508,
    longitude: 114.1747,
    accuracy: 30,
  });

  const result = runScript(WLOC_SOURCE, {
    $response: { body: String.fromCharCode(...response) },
    $persistentStore: {
      read: (key) => (key === 'wloc_settings' ? settings : null),
    },
  });

  assert.ok(result && typeof result.body === 'string', '应当返回改写后的响应体');

  const bytes = toBytes(result.body);
  const latitude = findVarintDeep(bytes, 1);
  const longitude = findVarintDeep(bytes, 2);

  assert.strictEqual(Number(latitude), Math.round(22.281508 * 1e8));
  assert.strictEqual(Number(longitude), Math.round(114.1747 * 1e8));
});

test('改写后长度前缀与实际载荷一致', () => {
  const response = buildSampleResponse();
  const settings = JSON.stringify({
    enabled: true,
    latitude: -33.86882,
    longitude: 151.20929,
    accuracy: 50,
  });

  const result = runScript(WLOC_SOURCE, {
    $response: { body: String.fromCharCode(...response) },
    $persistentStore: {
      read: (key) => (key === 'wloc_settings' ? settings : null),
    },
  });

  const bytes = toBytes(result.body);
  const declared = (bytes[8] << 8) | bytes[9];

  assert.strictEqual(
    declared,
    bytes.length - 10,
    'marker 帧的长度前缀必须等于实际载荷长度'
  );
});

test('坐标无效时放行', () => {
  const response = buildSampleResponse();
  // 注意 JSON 无法表达 NaN，序列化后会变成 null——
  // 这正是线上最容易踩的坑：Number(null) === 0，会把定位静默改到 (0, 0)。
  const settings = JSON.stringify({
    enabled: true,
    latitude: NaN,
    longitude: NaN,
    accuracy: 25,
  });

  const result = runScript(WLOC_SOURCE, {
    $response: { body: String.fromCharCode(...response) },
    $persistentStore: {
      read: (key) => (key === 'wloc_settings' ? settings : null),
    },
  });

  assertPassthrough(result);
});

test('配置里坐标缺失时不得改写成 (0,0)', () => {
  const response = buildSampleResponse();
  // 模拟「启用了但坐标字段丢失」——JSON 里是 null。
  const settings = JSON.stringify({ enabled: true, accuracy: 25 });

  const result = runScript(WLOC_SOURCE, {
    $response: { body: String.fromCharCode(...response) },
    $persistentStore: {
      read: (key) => (key === 'wloc_settings' ? settings : null),
    },
  });

  assertPassthrough(result);
});

test('经纬度为零属于合法坐标，应当改写', () => {
  const response = buildSampleResponse();
  const settings = JSON.stringify({
    enabled: true,
    latitude: 0,
    longitude: 0,
    accuracy: 25,
  });

  const result = runScript(WLOC_SOURCE, {
    $response: { body: String.fromCharCode(...response) },
    $persistentStore: {
      read: (key) => (key === 'wloc_settings' ? settings : null),
    },
  });

  assert.ok(result && typeof result.body === 'string', '0,0 是合法坐标，必须改写');
  const bytes = toBytes(result.body);
  assert.strictEqual(Number(findVarintDeep(bytes, 1)), 0);
  assert.strictEqual(Number(findVarintDeep(bytes, 2)), 0);
});

test('配置接口在启用时返回坐标', () => {
  const settings = JSON.stringify({
    enabled: true,
    latitude: 31.230416,
    longitude: 121.473701,
    accuracy: 25,
  });

  const result = runScript(SETTINGS_SOURCE, {
    $request: { url: 'https://gs-loc.apple.com/wloc-settings/save?action=query' },
    $persistentStore: {
      read: (key) => (key === 'wloc_settings' ? settings : null),
    },
  });

  assert.ok(result && result.response, '应当返回响应对象');
  const payload = JSON.parse(result.response.body);

  assert.strictEqual(payload.success, true);
  assert.strictEqual(payload.latitude, 31.230416);
  assert.strictEqual(payload.longitude, 121.473701);
});

test('配置接口在未启用时返回 success=false', () => {
  const result = runScript(SETTINGS_SOURCE, {
    $request: { url: 'https://gs-loc.apple.com/wloc-settings/save?action=query' },
    $persistentStore: { read: () => null },
  });

  const payload = JSON.parse(result.response.body);
  assert.strictEqual(payload.success, false);
  assert.ok(payload.error, '应当给出错误说明');
});

test('配置接口可以保存坐标并回读', () => {
  let stored = null;

  const result = runScript(SETTINGS_SOURCE, {
    $request: {
      url: 'https://gs-loc.apple.com/wloc-settings/save?lon=113.264435&lat=23.129163&acc=25',
    },
    $persistentStore: {
      read: () => stored,
      write: (value) => { stored = value; return true; },
    },
  });

  const payload = JSON.parse(result.response.body);
  assert.strictEqual(payload.success, true);
  assert.strictEqual(payload.latitude, 23.129163);
  assert.strictEqual(payload.longitude, 113.264435);

  // 写入的内容必须能被再次读出，否则查询与改写脚本就读不到同一份配置。
  const saved = JSON.parse(stored);
  assert.strictEqual(saved.enabled, true);
  assert.strictEqual(saved.latitude, 23.129163);
});

test('配置接口拒绝越界坐标', () => {
  const result = runScript(SETTINGS_SOURCE, {
    $request: {
      url: 'https://gs-loc.apple.com/wloc-settings/save?lon=999&lat=23.1&acc=25',
    },
    $persistentStore: { read: () => null, write: () => true },
  });

  const payload = JSON.parse(result.response.body);
  assert.strictEqual(payload.success, false);
});

test('配置接口可以清除坐标', () => {
  let stored = JSON.stringify({
    enabled: true,
    latitude: 23.129163,
    longitude: 113.264435,
    accuracy: 25,
  });

  const result = runScript(SETTINGS_SOURCE, {
    $request: { url: 'https://gs-loc.apple.com/wloc-settings/save?action=clear' },
    $persistentStore: {
      read: () => stored,
      write: (value) => { stored = value; return true; },
    },
  });

  const payload = JSON.parse(result.response.body);
  assert.strictEqual(payload.success, true);
  assert.strictEqual(JSON.parse(stored).enabled, false);
});
