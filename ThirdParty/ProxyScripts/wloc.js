/**
 * WLOC 定位响应改写脚本
 *
 * 职责：拦截 Apple 定位服务的 /clls/wloc 响应，把其中的 WiFi 热点、蜂窝基站
 * 和位置条目里的经纬度替换为配置文件里保存的目标坐标。
 *
 * 这个脚本运行在第三方代理客户端（Shadowrocket / Surge / Quantumult X /
 * Loon / Stash / Egern）的脚本引擎里，不是普通浏览器环境，因此：
 *   - 只能用各客户端共同支持的 API 子集；
 *   - 不能依赖 fetch、Promise 之外的东西；
 *   - 持久化必须走客户端的 key-value 存储。
 *
 * 坐标系：配置里保存的是 WGS-84，直接写入响应，不做转换。
 */

// ---------------------------------------------------------------------------
// 运行环境探测
// ---------------------------------------------------------------------------

const ENV = (() => {
  if (typeof $task !== 'undefined') return 'quantumultx';
  if (typeof $loon !== 'undefined') return 'loon';
  if (typeof $rocket !== 'undefined') return 'shadowrocket';
  if (typeof $environment !== 'undefined' && $environment['surge-version']) return 'surge';
  if (typeof $environment !== 'undefined' && $environment['stash-version']) return 'stash';
  if (typeof $environment !== 'undefined' && $environment['egern-version']) return 'egern';
  return 'unknown';
})();

const TAG = '[WLOC]';

/** 持久化存储键名，与 wloc-settings.js 共用。 */
const SETTINGS_KEY = 'wloc_settings';

// ---------------------------------------------------------------------------
// 存储读写
// ---------------------------------------------------------------------------

// 各客户端的持久化 API 名字不同。这里按「能力探测」而非「客户端名字」来选择，
// 好处是遇到未列出的客户端（或客户端改了 API 名字）时仍能工作。
// 按优先级排列：Quantumult X 用 $prefs，其余用 $persistentStore，少数用 $rocket.settings。
function readRawSettings() {
  try {
    if (typeof $prefs !== 'undefined' && typeof $prefs.valueForKey === 'function') {
      return $prefs.valueForKey(SETTINGS_KEY);
    }
  } catch (error) {
    log(`$prefs 读取失败: ${error}`);
  }

  try {
    if (typeof $persistentStore !== 'undefined'
        && typeof $persistentStore.read === 'function') {
      return $persistentStore.read(SETTINGS_KEY);
    }
  } catch (error) {
    log(`$persistentStore 读取失败: ${error}`);
  }

  try {
    if (typeof $rocket !== 'undefined' && $rocket.settings
        && typeof $rocket.settings.read === 'function') {
      return $rocket.settings.read(SETTINGS_KEY);
    }
  } catch (error) {
    log(`$rocket.settings 读取失败: ${error}`);
  }

  return null;
}

function readSettings() {
  const raw = readRawSettings();
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    // 简单校验，避免读到半截数据就往下走。
    if (!parsed || typeof parsed !== 'object') return null;
    return parsed;
  } catch (error) {
    log(`配置解析失败: ${error}`);
    return null;
  }
}

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------

function log(message) {
  console.log(`${TAG} ${message}`);
}

// ---------------------------------------------------------------------------
// Protobuf 编解码
// ---------------------------------------------------------------------------

const WIRE_VARINT = 0;
const WIRE_FIXED64 = 1;
const WIRE_LENGTH_DELIMITED = 2;
const WIRE_FIXED32 = 5;

/** 读取一个 varint，返回值与消耗字节数。 */
function readVarint(bytes, offset) {
  let value = 0n;
  let shift = 0n;
  let cursor = offset;

  while (cursor < bytes.length) {
    const byte = bytes[cursor];
    value |= BigInt(byte & 0x7f) << shift;
    cursor += 1;
    if ((byte & 0x80) === 0) {
      return { value, length: cursor - offset };
    }
    shift += 7n;
    if (shift > 63n) throw new Error('varint 过长');
  }
  throw new Error('varint 被截断');
}

/** 把 non-negative BigInt 编码成 varint 字节数组。 */
function writeVarint(value) {
  const out = [];
  let current = BigInt.asUintN(64, value);
  while (current >= 0x80n) {
    out.push(Number(current & 0x7fn) | 0x80);
    current >>= 7n;
  }
  out.push(Number(current));
  return out;
}

function writeTag(number, wireType) {
  return writeVarint(BigInt(number * 8 + wireType));
}

function writeLengthDelimited(number, payload) {
  return [...writeTag(number, WIRE_LENGTH_DELIMITED),
          ...writeVarint(BigInt(payload.length)),
          ...payload];
}

function writeVarintField(number, value) {
  return [...writeTag(number, WIRE_VARINT), ...writeVarint(value)];
}

/** 解析一段 protobuf 载荷，返回字段数组（保留原始字节）。 */
function decodeFields(bytes) {
  const fields = [];
  let cursor = 0;

  while (cursor < bytes.length) {
    const start = cursor;
    const tag = readVarint(bytes, cursor);
    cursor += tag.length;

    const number = Number(tag.value >> 3n);
    const wireType = Number(tag.value & 7n);
    if (number === 0) throw new Error('字段号为 0');

    let payload;

    if (wireType === WIRE_VARINT) {
      const item = readVarint(bytes, cursor);
      payload = bytes.slice(cursor, cursor + item.length);
      cursor += item.length;
    } else if (wireType === WIRE_FIXED64) {
      payload = bytes.slice(cursor, cursor + 8);
      cursor += 8;
    } else if (wireType === WIRE_LENGTH_DELIMITED) {
      const length = readVarint(bytes, cursor);
      cursor += length.length;
      const size = Number(length.value);
      payload = bytes.slice(cursor, cursor + size);
      cursor += size;
    } else if (wireType === WIRE_FIXED32) {
      payload = bytes.slice(cursor, cursor + 4);
      cursor += 4;
    } else {
      throw new Error(`不支持的 wire type ${wireType}`);
    }

    fields.push({
      number,
      wireType,
      value: payload,
      raw: bytes.slice(start, cursor),
    });
  }

  return fields;
}

function hasVarintField(fields, number) {
  return fields.some((field) => field.number === number && field.wireType === WIRE_VARINT);
}

// ---------------------------------------------------------------------------
// 改写逻辑
// ---------------------------------------------------------------------------

const MAC_PATTERN = /^[0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}$/;
const MARKER_MAGIC = [0x00, 0x00, 0x00, 0x01, 0x00, 0x00];

/** 十进制度 → 定点整数（×1e8）。 */
function encodeCoordinate(degrees) {
  return BigInt(Math.round(degrees * 1e8));
}

/** 改写单条位置条目。 */
function patchLocationEntry(entry, target) {
  const fields = decodeFields(entry);
  if (!hasVarintField(fields, 1) || !hasVarintField(fields, 2)) {
    return { bytes: entry, changed: false, locations: 0 };
  }

  const lat = encodeCoordinate(target.latitude);
  const lon = encodeCoordinate(target.longitude);
  const accuracy = BigInt(target.accuracy);

  let out = [];
  let changed = false;

  for (const field of fields) {
    if (field.number === 1 && field.wireType === WIRE_VARINT) {
      const rewritten = writeVarintField(1, lat);
      if (!sameBytes(rewritten, field.raw)) changed = true;
      out = out.concat(rewritten);
    } else if (field.number === 2 && field.wireType === WIRE_VARINT) {
      const rewritten = writeVarintField(2, lon);
      if (!sameBytes(rewritten, field.raw)) changed = true;
      out = out.concat(rewritten);
    } else if (field.number === 3 && field.wireType === WIRE_VARINT) {
      const rewritten = writeVarintField(3, accuracy);
      if (!sameBytes(rewritten, field.raw)) changed = true;
      out = out.concat(rewritten);
    } else {
      out = out.concat(field.raw);
    }
  }

  return { bytes: out, changed, locations: changed ? 1 : 0 };
}

function sameBytes(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

/** 改写一个 WiFi 设备条目。 */
function patchWiFiDevice(device, target) {
  const fields = decodeFields(device);

  const isDevice = fields.some(
    (field) => field.number === 1
      && field.wireType === WIRE_LENGTH_DELIMITED
      && MAC_PATTERN.test(String.fromCharCode(...field.value))
  );
  if (!isDevice) return { bytes: device, changed: false, locations: 0 };

  let out = [];
  let changed = false;
  let locations = 0;

  for (const field of fields) {
    if (field.number === 2 && field.wireType === WIRE_LENGTH_DELIMITED) {
      const result = patchLocationEntry(field.value, target);
      if (result.changed) {
        changed = true;
        locations += result.locations;
      }
      out = out.concat(writeLengthDelimited(2, result.bytes));
    } else {
      out = out.concat(field.raw);
    }
  }

  return { bytes: out, changed, locations };
}

/** 改写一段蜂窝基站数据。 */
function patchCellSection(section, target) {
  const fields = decodeFields(section);
  let out = [];
  let changed = false;
  let locations = 0;

  for (const field of fields) {
    if (field.number === 5 && field.wireType === WIRE_LENGTH_DELIMITED) {
      const result = patchLocationEntry(field.value, target);
      if (result.changed) {
        changed = true;
        locations += result.locations;
      }
      out = out.concat(writeLengthDelimited(5, result.bytes));
    } else {
      out = out.concat(field.raw);
    }
  }

  return { bytes: out, changed, locations };
}

/** 改写 wloc 载荷本体。 */
function patchWlocPayload(payload, target) {
  const fields = decodeFields(payload);
  let out = [];
  let changed = false;
  let locations = 0;

  for (const field of fields) {
    if (field.number === 2 && field.wireType === WIRE_LENGTH_DELIMITED) {
      const result = patchWiFiDevice(field.value, target);
      if (result.changed) {
        changed = true;
        locations += result.locations;
      }
      out = out.concat(writeLengthDelimited(2, result.bytes));
    } else if ((field.number === 22 || field.number === 24)
               && field.wireType === WIRE_LENGTH_DELIMITED) {
      const result = patchCellSection(field.value, target);
      if (result.changed) {
        changed = true;
        locations += result.locations;
      }
      out = out.concat(writeLengthDelimited(field.number, result.bytes));
    } else {
      out = out.concat(field.raw);
    }
  }

  return { bytes: out, changed, locations };
}

/** 尝试按 marker 信封解析。
 *
 * marker 信封有两种常见布局，二者都以「uint16 大端长度 + 载荷」收尾：
 *   A. 8 字节前缀 + 长度 + 载荷   （wloccore 的 patchAtOffset 处理的是这种）
 *   B. 6 字节魔数 + 长度 + 载荷
 *
 * 因为 6 字节魔数 00 00 00 01 00 00 恰好是 8 字节前缀 00 01 00 00 00 01 00 00
 * 的后 6 字节，如果只按魔数搜索，会在偏移 2 处产生伪匹配并把载荷前两字节
 * 误读成长度（结果是 0x1201 这类超大值或 0，直接放弃改写）。
 * 因此这里显式先试 8 字节前缀，再回退到魔数搜索。
 */
function patchMarkerFrame(bytes, target) {
  // 变体 A：8 字节前缀 + uint16 长度 + 载荷。
  const prefixResult = patchAtOffset(bytes, 0, target);
  if (prefixResult) return prefixResult;

  // 变体 B：6 字节魔数 + uint16 长度 + 载荷。
  let searchFrom = 0;

  while (searchFrom <= bytes.length - MARKER_MAGIC.length) {
    let magicOffset = -1;
    outer: for (let i = searchFrom; i <= bytes.length - MARKER_MAGIC.length; i += 1) {
      for (let j = 0; j < MARKER_MAGIC.length; j += 1) {
        if (bytes[i + j] !== MARKER_MAGIC[j]) continue outer;
      }
      magicOffset = i;
      break;
    }
    if (magicOffset < 0) return null;

    const lengthOffset = magicOffset + MARKER_MAGIC.length;
    const payloadOffset = lengthOffset + 2;
    if (payloadOffset > bytes.length) return null;

    const length = (bytes[lengthOffset] << 8) | bytes[lengthOffset + 1];
    if (length <= 0 || payloadOffset + length > bytes.length) {
      searchFrom = magicOffset + 1;
      continue;
    }

    try {
      const result = patchWlocPayload(bytes.slice(payloadOffset, payloadOffset + length), target);
      if (result.changed) {
        const lengthBytes = [(result.bytes.length >> 8) & 0xff, result.bytes.length & 0xff];
        return {
          bytes: [...bytes.slice(0, lengthOffset), ...lengthBytes, ...result.bytes,
                  ...bytes.slice(payloadOffset + length)],
          locations: result.locations,
        };
      }
    } catch (error) {
      // 该候选位置不是真正的帧头，继续往后找。
    }

    searchFrom = magicOffset + 1;
  }

  return null;
}

/** 尝试按「8 字节前缀 + uint16 长度 + 载荷」解析。 */
function patchAtOffset(bytes, offset, target) {
  if (bytes.length < offset + 10) return null;

  const length = (bytes[offset + 8] << 8) | bytes[offset + 9];
  if (length <= 0 || offset + 10 + length > bytes.length) return null;

  const result = patchWlocPayload(bytes.slice(offset + 10, offset + 10 + length), target);
  if (!result.changed) return null;

  const lengthBytes = [(result.bytes.length >> 8) & 0xff, result.bytes.length & 0xff];
  return {
    bytes: [...bytes.slice(0, offset + 8), ...lengthBytes, ...result.bytes,
            ...bytes.slice(offset + 10 + length)],
    locations: result.locations,
  };
}

/** 主改写入口：依次尝试各种信封格式。 */
function patchWlocBody(bytes, target) {
  const marker = patchMarkerFrame(bytes, target);
  if (marker) return marker;

  const limit = Math.min(96, Math.max(0, bytes.length - 10));
  for (let offset = 0; offset <= limit; offset += 1) {
    const result = patchAtOffset(bytes, offset, target);
    if (result) return result;
  }

  const fallbackLimit = Math.min(256, bytes.length);
  for (let i = 0; i <= fallbackLimit; i += 1) {
    try {
      const result = patchWlocPayload(bytes.slice(i), target);
      if (result.changed) {
        return { bytes: [...bytes.slice(0, i), ...result.bytes], locations: result.locations };
      }
    } catch (error) {
      // 该偏移处解析失败是预期内的，继续尝试下一个。
    }
  }

  return null;
}

// ---------------------------------------------------------------------------
// 响应体处理
// ---------------------------------------------------------------------------

/** 判断数据是否为 gzip。 */
function isGzip(bytes) {
  return bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b;
}

/** 把响应体转成字节数组。
 *
 * 代理客户端给到的响应体是「二进制字符串」——每个字符就是一字节，
 * 取值范围 0x00-0xFF，不是 UTF-8 文本。因此这里绝不能做 UTF-8 重编码：
 * 一旦把 0x92 这类高位字符编码成两字节，protobuf 结构立刻被破坏。
 * 只在字符码确实超出单字节范围时才退化成分字节处理。
 */
function toBytes(input) {
  if (typeof input === 'string') {
    const out = [];
    for (let i = 0; i < input.length; i += 1) {
      out.push(input.charCodeAt(i) & 0xff);
    }
    return out;
  }
  return Array.from(input, (byte) => byte & 0xff);
}

/** 字节数组转二进制字符串，供各客户端 API 使用。 */
function toBinaryString(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i += 1) out += String.fromCharCode(bytes[i]);
  return out;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

/** 严格转数值：null / undefined / 空串 / 非数字一律返回 null。
 *
 * 不能直接用 Number()：Number(null) === 0、Number('') === 0，
 * 会把「配置里没有坐标」误判成「坐标是 0,0」，静默把定位改到几内亚湾。
 */
function toFiniteNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

// ---------------------------------------------------------------------------
// 运动状态模拟（原地抖动）
// ---------------------------------------------------------------------------

/** 抖动半径只认这几档，与 MapLocationState.MotionDriftOption 保持一致。 */
const DRIFT_STEPS = [0, 5, 10, 20];

/** 纬度方向 1 度对应的米数（地球平均半径估算）。 */
const METERS_PER_DEGREE_LATITUDE = 111320;

/**
 * 在同一位置附近的抖动半径内随机取一个偏移点。
 *
 * 开启后每次改写都会重新取点，系统看到的是「同一个位置附近的微小漂移」，
 * 这正是真实 GPS 的表现；死钉在一个坐标上反而容易被判定为伪造。
 * 关闭（半径 0）时原样返回。
 */
function driftTarget(target) {
  const radiusMeters = DRIFT_STEPS.includes(target.driftRadius) ? target.driftRadius : 0;
  if (radiusMeters <= 0) return target;

  // 半径按 sqrt(u) 取样，点在圆面积上才是均匀分布，否则会明显偏向圆心。
  const radius = Math.sqrt(Math.random()) * radiusMeters;
  const angle = Math.random() * 2 * Math.PI;

  const deltaLat = (radius * Math.cos(angle)) / METERS_PER_DEGREE_LATITUDE;
  const cosLat = Math.cos((target.latitude * Math.PI) / 180);

  // 极点附近 cos(lat) 趋近 0，经度差会发散，此时只抖纬度。
  if (Math.abs(cosLat) < 1e-6) {
    return { ...target, latitude: target.latitude + deltaLat };
  }

  const deltaLon = (radius * Math.sin(angle)) / (METERS_PER_DEGREE_LATITUDE * cosLat);
  return {
    ...target,
    latitude: target.latitude + deltaLat,
    longitude: target.longitude + deltaLon,
  };
}

function main() {
  const settings = readSettings();
  if (!settings || settings.enabled !== true) {
    log('未启用虚拟定位，放行原始响应');
    $done({});
    return;
  }

  const target = {
    latitude: toFiniteNumber(settings.latitude),
    longitude: toFiniteNumber(settings.longitude),
    accuracy: toFiniteNumber(settings.accuracy) || 25,
    driftRadius: toFiniteNumber(settings.driftRadius) || 0,
  };

  if (target.latitude === null || target.longitude === null) {
    log('配置中的坐标无效，放行原始响应');
    $done({});
    return;
  }

  const rawBody = typeof $response !== 'undefined' ? $response.body : undefined;
  if (!rawBody) {
    log('响应体为空，放行');
    $done({});
    return;
  }

  let bodyBytes = toBytes(rawBody);

  // 响应体可能是 gzip 压缩的。各客户端脚本引擎对 gzip 支持不一，
  // 这里只在能解压的情况下处理，否则原样放行并记一条日志。
  if (isGzip(bodyBytes)) {
    log('响应体为 gzip 压缩，当前客户端环境不支持解压，放行');
    $done({});
    return;
  }

  try {
    const result = patchWlocBody(bodyBytes, driftTarget(target));
    if (!result) {
      log('未找到可改写的位置数据，放行原始响应');
      $done({});
      return;
    }

    log(`改写成功，位置条目 ${result.locations} 个`);
    $done({ body: toBinaryString(result.bytes) });
  } catch (error) {
    log(`改写失败: ${error && error.message ? error.message : error}`);
    $done({});
  }
}

main();
