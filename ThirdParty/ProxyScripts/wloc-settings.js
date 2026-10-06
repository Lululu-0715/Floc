/**
 * WLOC 配置接口脚本
 *
 * 职责：拦截 https://gs-loc.apple.com/wloc-settings/save，响应本应用的
 * 查询 / 保存 / 清除请求，并把坐标持久化到客户端存储。
 *
 * 请求约定：
 *   ?action=query                查询当前保存的坐标
 *   ?action=clear                清除已保存的坐标
 *   ?lon=<WGS-84 经度>&lat=<WGS-84 纬度>&acc=<精度>&drift=<抖动半径>    保存坐标
 *
 * 响应约定（HTTP 200 + JSON）：
 *   { "success": true, "longitude": 113.0, "latitude": 22.0, "accuracy": 25, "driftRadius": 10 }
 *   { "success": false, "error": "错误说明" }
 *
 * 这个脚本必须与 wloc.js 使用同一个持久化键名，两者才能读到同一份配置。
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

const TAG = '[WLOC-SETTINGS]';
const SETTINGS_KEY = 'wloc_settings';

// ---------------------------------------------------------------------------
// 存储读写
// ---------------------------------------------------------------------------

// 与 wloc.js 保持同样的策略：按 API 能力探测而不是按客户端名字分派，
// 这样未列出的客户端也能正常读写同一份配置。
function readRaw() {
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

function writeRaw(value) {
  try {
    if (typeof $prefs !== 'undefined' && typeof $prefs.setValueForKey === 'function') {
      $prefs.setValueForKey(value, SETTINGS_KEY);
      return true;
    }
  } catch (error) {
    log(`$prefs 写入失败: ${error}`);
  }

  try {
    if (typeof $persistentStore !== 'undefined'
        && typeof $persistentStore.write === 'function') {
      $persistentStore.write(value, SETTINGS_KEY);
      return true;
    }
  } catch (error) {
    log(`$persistentStore 写入失败: ${error}`);
  }

  try {
    if (typeof $rocket !== 'undefined' && $rocket.settings
        && typeof $rocket.settings.write === 'function') {
      $rocket.settings.write(SETTINGS_KEY, value);
      return true;
    }
  } catch (error) {
    log(`$rocket.settings 写入失败: ${error}`);
  }

  return false;
}

function readSettings() {
  const raw = readRaw();
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch (error) {
    log('配置解析失败');
    return null;
  }
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

function log(message) {
  console.log(`${TAG} ${message}`);
}

/** 解析 URL 查询参数。 */
function parseQuery(url) {
  const result = {};
  const index = url.indexOf('?');
  if (index < 0) return result;

  const search = url.slice(index + 1).split('#')[0];
  for (const pair of search.split('&')) {
    if (!pair) continue;
    const [key, value = ''] = pair.split('=');
    result[decodeURIComponent(key)] = decodeURIComponent(value);
  }
  return result;
}

/** 统一的 JSON 响应。 */
function respond(payload) {
  const body = JSON.stringify(payload);
  $done({
    response: {
      status: 200,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store',
      },
      body,
    },
  });
}

// ---------------------------------------------------------------------------
// 动作处理
// ---------------------------------------------------------------------------

/** 抖动半径只认这几档，与 MapLocationState.MotionDriftOption 保持一致。 */
const DRIFT_STEPS = [0, 5, 10, 20];

function normalizeDrift(value) {
  const parsed = toFiniteNumber(value);
  if (parsed === null) return 0;
  return DRIFT_STEPS.includes(parsed) ? parsed : 0;
}

function handleQuery() {
  const settings = readSettings();
  if (!settings || settings.enabled !== true) {
    // 用 success:false 表示「模块在，但虚拟定位没开」，
    // 应用侧据此区分「模块未生效」和「模块已连接但未开启」。
    respond({ success: false, error: '无已保存的坐标' });
    return;
  }

  respond({
    success: true,
    longitude: Number(settings.longitude),
    latitude: Number(settings.latitude),
    accuracy: Number(settings.accuracy) || 25,
    driftRadius: normalizeDrift(settings.driftRadius),
  });
}

function handleClear() {
  const settings = readSettings();
  if (settings) {
    settings.enabled = false;
    writeRaw(JSON.stringify(settings));
  }
  log('已清除坐标');
  respond({ success: true });
}

/** 严格转数值：空串一律拒绝，避免 Number('') === 0 把缺参当成 0 度。 */
function toFiniteNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function handleSave(query) {
  const longitude = toFiniteNumber(query.lon);
  const latitude = toFiniteNumber(query.lat);
  const accuracy = toFiniteNumber(query.acc) || 25;
  const driftRadius = normalizeDrift(query.drift);

  if (longitude === null || latitude === null) {
    respond({ success: false, error: '经纬度参数无效' });
    return;
  }
  if (longitude < -180 || longitude > 180 || latitude < -90 || latitude > 90) {
    respond({ success: false, error: '经纬度超出有效范围' });
    return;
  }

  const payload = {
    enabled: true,
    longitude,
    latitude,
    accuracy,
    driftRadius,
    updatedAt: Date.now(),
  };

  if (!writeRaw(JSON.stringify(payload))) {
    respond({ success: false, error: '无法写入客户端存储' });
    return;
  }

  log(`已保存坐标 ${latitude},${longitude}，抖动半径 ${driftRadius} 米`);
  // 契约要求：保存成功时回读的坐标必须与请求一致。
  respond({
    success: true,
    longitude,
    latitude,
    accuracy,
    driftRadius,
  });
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

function main() {
  const url = typeof $request !== 'undefined' && $request.url ? $request.url : '';
  const query = parseQuery(url);
  const action = query.action;

  if (action === 'query') {
    handleQuery();
  } else if (action === 'clear') {
    handleClear();
  } else if (query.lon !== undefined && query.lat !== undefined) {
    handleSave(query);
  } else {
    respond({ success: false, error: '缺少必要参数' });
  }
}

main();
