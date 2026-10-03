// 兜底模块宿主 shim：把 native 桥包装成 ctx（与前端 createFallbackHostCtx 语义一致），
// 提供 __xyFbLoad / __xyFbCall 入口。模块代码是「函数体」，最后 return 实现对象。
"use strict";
(function () {
  // ---- utils（照抄前端 hostCtx.ts / types/index.ts 语义）----
  function parseIntervalToSeconds(interval) {
    if (!interval) return 0;
    var parts = String(interval).trim().split(':').map(function (p) { return parseInt(p, 10); });
    if (parts.length === 0 || parts.some(function (n) { return isNaN(n); })) return 0;
    return parts.reduce(function (acc, n) { return acc * 60 + n; }, 0);
  }

  function stripHtmlTags(str) {
    if (!str || typeof str !== 'string') return '';
    return str.replace(/<[^>]*>/g, '');
  }

  // normalizeQualityKey：QUALITY_META 键表 + 别名表（与 src/types/index.ts 同步维护）
  var QUALITY_KEYS = [
    'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
    'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
  ];
  var QUALITY_KEY_ALIASES = {
    '96k': 'mgg', ogg96: 'mgg', mgg: 'mgg',
    '128': '128k', '128k': '128k',
    '192': '192k', '192k': '192k', ogg192: '192k',
    '320': '320k', '320k': '320k', ogg320: '320k', exhigh: '320k',
    flac: 'flac', sq: 'flac', super: 'flac', lossless: 'flac',
    flac24: 'flac24bit', '24bit': 'flac24bit', '24bits': 'flac24bit', '24_bit': 'flac24bit', flac24bit: 'flac24bit',
    hires: 'hires', 'hi-res': 'hires', hi_res: 'hires', hr: 'hires',
    vinyl: 'vinyl', dolby: 'dolby', atmos: 'atmos', galaxy: 'atmos',
    atmosplus: 'atmos_plus', atmos_plus: 'atmos_plus', 'atmos+': 'atmos_plus', galaxy51: 'atmos_plus',
    master: 'master',
  };

  function normalizeQualityKey(raw) {
    if (typeof raw !== 'string') return null;
    var normalized = raw.trim().toLowerCase().replace(/\s+/g, '').replace(/-/g, '_');
    if (!normalized) return null;
    if (QUALITY_KEYS.indexOf(normalized) !== -1) return normalized;
    return QUALITY_KEY_ALIASES[normalized] != null ? QUALITY_KEY_ALIASES[normalized] : null;
  }

  // ---- 值归一化：Map → Object.fromEntries（R1），其余交给 JSON.stringify ----
  function normalizeValue(v) {
    if (v instanceof Map) {
      var o = {};
      v.forEach(function (val, key) { o[key] = normalizeValue(val); });
      return o;
    }
    if (Array.isArray(v)) return v.map(normalizeValue);
    if (v && typeof v === 'object') {
      var out = {};
      for (var k in v) out[k] = normalizeValue(v[k]);
      return out;
    }
    return v;
  }

  function stringify(v) {
    var s = JSON.stringify(normalizeValue(v));
    return s === undefined ? 'null' : s;
  }

  // ---- http ----
  function httpReq(method, url, body, opts) {
    opts = opts || {};
    var headers = opts.headers || {};
    var bodyStr = '';
    if (method === 'POST' && body !== undefined && body !== null) {
      if (typeof body === 'string') {
        bodyStr = body;
      } else {
        bodyStr = JSON.stringify(body);
        var hasCt = false;
        for (var k in headers) {
          if (k.toLowerCase() === 'content-type') { hasCt = true; break; }
        }
        if (!hasCt) headers['Content-Type'] = 'application/json';
      }
    }
    var timeoutMs = typeof opts.timeoutMs === 'number' && opts.timeoutMs > 0 ? opts.timeoutMs : 0;
    return globalThis.__xyFbHttpRequest(method, String(url), JSON.stringify(headers), bodyStr, timeoutMs, 10, false)
      .then(function (json) {
        var resp = JSON.parse(json);
        if (resp && resp.error) throw new Error(resp.error);
        return { status: resp.status || 0, headers: resp.headers || {}, body: resp.body || '' };
      });
  }

  // ---- log（data 附加进 message，前端统一打 [FallbackModule] 前缀）----
  function logWithLevel(level, msg, data) {
    var line = String(msg);
    if (data !== undefined && data !== null) line += ' ' + stringify(data);
    globalThis.__xyFbLog(level, line);
  }

  var ctx = {
    appVersion: globalThis.__xyFbAppVersion || '',
    http: {
      get: function (url, opts) { return httpReq('GET', url, undefined, opts); },
      post: function (url, body, opts) { return httpReq('POST', url, body, opts); },
    },
    cache: {
      get: function (key) {
        var raw = globalThis.__xyFbCacheGet(String(key));
        if (raw == null || raw === 'null') return null;
        try { return JSON.parse(raw); } catch (e) { return null; }
      },
      set: function (key, value, ttlSeconds) {
        var ttl = typeof ttlSeconds === 'number' && ttlSeconds > 0 ? ttlSeconds : 0;
        globalThis.__xyFbCacheSet(String(key), stringify(value), ttl);
      },
      del: function (key) { globalThis.__xyFbCacheDel(String(key)); },
    },
    log: {
      info: function (msg, data) { logWithLevel('info', msg, data); },
      warn: function (msg, data) { logWithLevel('warn', msg, data); },
      error: function (msg, data) { logWithLevel('error', msg, data); },
    },
    config: {
      get: function (key) {
        var raw = globalThis.__xyFbConfigGet(String(key));
        if (raw == null || raw === 'null') return null;
        try { return JSON.parse(raw); } catch (e) { return null; }
      },
    },
    utils: {
      parseIntervalToSeconds: parseIntervalToSeconds,
      normalizeQualityKey: normalizeQualityKey,
      stripHtmlTags: stripHtmlTags,
    },
  };

  var __module = null;

  function errText(e) {
    return e && e.message ? String(e.message) : String(e);
  }

  // 返回 {ok, methods?, version?, error?} JSON；"四条硬校验"中的 1/2/3 在此完成，
  // 第 4 条（约定方法覆盖）由宿主对 methods 求交集判断。
  globalThis.__xyFbLoad = function (code) {
    try {
      var factory = new Function('ctx', '"use strict";\n' + code);
      var impl = factory(ctx);
      if (!impl || typeof impl !== 'object') {
        return JSON.stringify({ ok: false, error: '模块工厂未返回对象' });
      }
      if (typeof impl.version !== 'number' || !isFinite(impl.version) || impl.version < 1) {
        return JSON.stringify({ ok: false, error: '模块 version 必须是 ≥1 的有限数字' });
      }
      var methods = [];
      for (var k in impl) {
        if (Object.prototype.hasOwnProperty.call(impl, k) && typeof impl[k] === 'function') {
          methods.push(k);
        }
      }
      __module = impl;
      return JSON.stringify({ ok: true, version: impl.version, methods: methods });
    } catch (e) {
      return JSON.stringify({ ok: false, error: errText(e) });
    }
  };

  // argsJson 为单个参数对象的 JSON（与前端 dispatch 传单个 args 对象一致）。
  // 同步返回值与 Promise 均兼容（v2 全异步调度，前端统一 await）。
  globalThis.__xyFbCall = function (method, argsJson) {
    if (!__module) return Promise.resolve('{"ok":false,"error":"模块未加载"}');
    var fn = __module[method];
    if (typeof fn !== 'function') {
      return Promise.resolve('{"ok":false,"error":"方法不存在: ' + method + '"}');
    }
    var args;
    try {
      args = JSON.parse(argsJson);
    } catch (e) {
      return Promise.resolve('{"ok":false,"error":"参数解析失败: ' + errText(e) + '"}');
    }
    var result;
    try {
      result = fn.call(__module, args);
    } catch (e) {
      return Promise.resolve(JSON.stringify({ ok: false, error: errText(e) }));
    }
    return Promise.resolve(result).then(
      function (v) { return JSON.stringify({ ok: true, data: normalizeValue(v) }); },
      function (e) { return JSON.stringify({ ok: false, error: errText(e) }); },
    );
  };
})();
