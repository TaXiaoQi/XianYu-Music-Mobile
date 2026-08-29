/**
 * QuickJS 插件宿主胶水层
 *
 * 由 Rust 引擎在每个插件上下文中按顺序执行：
 *   1. 注册原生桥函数（__xyNative*）
 *   2. 本文件（host_shim.js）—— 环境 polyfill + require 体系 + 插件加载器
 *   3. packages_bundle.js —— esbuild 产物，挂载 globalThis.__xyPackages
 *   4. __xyPostSetup() —— axios 代理实例 / Buffer / CryptoJs 全局注入
 *
 * 语义与原前端 pluginSandbox.worker.ts 逐一对齐。
 */

(function () {
  'use strict';

  var G = globalThis;

  // ==================== 结果序列化（供 Rust 侧读取）====================

  function __xySafeStringify(v) {
    if (v === undefined) return 'null';
    try {
      var s = JSON.stringify(v);
      return s === undefined ? 'null' : s;
    } catch (e) {
      return 'null';
    }
  }

  G.__xyOk = function (r) {
    return '{"ok":true,"data":' + __xySafeStringify(r) + '}';
  };

  G.__xyErr = function (e) {
    var msg = e && e.message ? String(e.message) : String(e);
    return '{"ok":false,"error":' + JSON.stringify(msg) + '}';
  };

  // ==================== console ====================

  function joinArgs(args) {
    var parts = [];
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      try {
        if (typeof a === 'object' && a !== null) {
          parts.push(String(JSON.stringify(a)).substring(0, 200));
        } else {
          parts.push(String(a));
        }
      } catch (e) {
        parts.push('[object]');
      }
    }
    return parts.join(' ');
  }

  G.console = {
    log: function () { __xyNativeLog('log', joinArgs(arguments)); },
    warn: function () { __xyNativeLog('warn', joinArgs(arguments)); },
    error: function () { __xyNativeLog('error', joinArgs(arguments)); },
    info: function () { __xyNativeLog('log', joinArgs(arguments)); },
    debug: function () { __xyNativeLog('log', joinArgs(arguments)); },
    // [修复] 部分插件（如 ikun 音源）用 console.group/groupEnd 组织日志，
    // 宿主缺失这些方法时调用会抛 "not a function"，导致整个 musicUrl 解析失败。
    // 提供无害空实现以兜底所有依赖 console group API 的插件。
    group: function () {},
    groupCollapsed: function () {},
    groupEnd: function () {},
  };

  // ==================== timers ====================

  var timers = new Map();
  var timerSeq = 0;

  function runTimerCb(fn, args) {
    try { fn.apply(null, args); } catch (e) { G.console.error(e); }
  }

  G.setTimeout = function (fn, ms) {
    if (typeof fn !== 'function') return 0;
    var id = ++timerSeq;
    var args = Array.prototype.slice.call(arguments, 2);
    timers.set(id, true);
    Promise.resolve(__xyNativeDelay(Number(ms) || 0)).then(function () {
      if (!timers.has(id)) return;
      timers.delete(id);
      runTimerCb(fn, args);
    }, function () { timers.delete(id); });
    return id;
  };

  G.clearTimeout = function (id) { timers.delete(id); };

  G.setInterval = function (fn, ms) {
    if (typeof fn !== 'function') return 0;
    var id = ++timerSeq;
    var args = Array.prototype.slice.call(arguments, 2);
    var interval = Number(ms) || 0;
    timers.set(id, true);
    var tick = function () {
      if (!timers.has(id)) return;
      runTimerCb(fn, args);
      Promise.resolve(__xyNativeDelay(interval)).then(tick, function () { timers.delete(id); });
    };
    Promise.resolve(__xyNativeDelay(interval)).then(tick, function () { timers.delete(id); });
    return id;
  };

  G.clearInterval = function (id) { timers.delete(id); };

  if (typeof G.queueMicrotask !== 'function') {
    G.queueMicrotask = function (fn) { Promise.resolve().then(fn); };
  }

  // ==================== UTF-8 / TextEncoder / TextDecoder ====================

  function utf8Encode(str) {
    var s = String(str);
    var out = [];
    for (var i = 0; i < s.length; i++) {
      var code = s.codePointAt(i);
      if (code > 0xffff) i++;
      if (code < 0x80) {
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xc0 | (code >> 6), 0x80 | (code & 63));
      } else if (code < 0x10000) {
        out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      } else {
        out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      }
    }
    return new Uint8Array(out);
  }

  function utf8Decode(bytes) {
    var out = '';
    var i = 0;
    while (i < bytes.length) {
      var b = bytes[i];
      var code;
      if (b < 0x80) {
        code = b; i += 1;
      } else if (b < 0xe0) {
        code = ((b & 0x1f) << 6) | (bytes[i + 1] & 63); i += 2;
      } else if (b < 0xf0) {
        code = ((b & 0x0f) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63); i += 3;
      } else {
        code = ((b & 0x07) << 18) | ((bytes[i + 1] & 63) << 12) | ((bytes[i + 2] & 63) << 6) | (bytes[i + 3] & 63); i += 4;
      }
      out += String.fromCodePoint(code);
    }
    return out;
  }

  G.TextEncoder = function TextEncoder() {};
  G.TextEncoder.prototype.encode = function (s) { return utf8Encode(s); };

  // TextDecoder 必须尊重编码标签：酷我等平台的歌词接口返回 GB18030 编码，
  // 插件用 new TextDecoder("gb18030").decode() 解码。纯 JS 无法覆盖全部
  // WHATWG 编码标签，统一桥到原生 encoding_rs（无效序列按浏览器语义输出 U+FFFD）
  G.TextDecoder = function TextDecoder(label) {
    this.__xyEncoding = label == null ? 'utf-8' : String(label);
  };
  G.TextDecoder.prototype.decode = function (buf) {
    var u8 = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
    if (!u8.length) return '';
    var parts = [];
    var CHUNK = 8192;
    for (var i = 0; i < u8.length; i++) {
      parts.push(String.fromCharCode(u8[i]));
      if (parts.length >= CHUNK) {
        parts = [parts.join('')];
      }
    }
    return __xyNativeDecodeText(G.btoa(parts.join('')), this.__xyEncoding);
  };

  // ==================== packages 访问（packages_bundle.js 执行后可用）====================

  function getPackages() {
    return G.__xyPackages || {};
  }

  function getBuffer() {
    var pkgs = getPackages();
    return (pkgs.buffer && pkgs.buffer.Buffer) || null;
  }

  function getCryptoJs() {
    var pkgs = getPackages();
    return pkgs['crypto-js'] || null;
  }

  // ==================== atob / btoa ====================
  // 必须纯 JS 实现：entities（cheerio 依赖）在 packages_bundle 求值阶段
  // （__xyPackages 挂载前）就调用 atob 解码内置压缩表，此时 Buffer 不可用。

  var B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var B64_LOOKUP = (function () {
    var t = {};
    for (var i = 0; i < B64_ALPHABET.length; i++) t[B64_ALPHABET.charAt(i)] = i;
    return t;
  })();

  G.btoa = function (s) {
    var str = String(s);
    var out = [];
    for (var i = 0; i < str.length; i += 3) {
      var b1 = str.charCodeAt(i) & 0xff;
      var has2 = i + 1 < str.length;
      var has3 = i + 2 < str.length;
      var b2 = has2 ? str.charCodeAt(i + 1) & 0xff : 0;
      var b3 = has3 ? str.charCodeAt(i + 2) & 0xff : 0;
      out.push(
        B64_ALPHABET.charAt(b1 >> 2),
        B64_ALPHABET.charAt(((b1 & 3) << 4) | (b2 >> 4)),
        has2 ? B64_ALPHABET.charAt(((b2 & 15) << 2) | (b3 >> 6)) : '=',
        has3 ? B64_ALPHABET.charAt(b3 & 63) : '=',
      );
    }
    return out.join('');
  };

  G.atob = function (b64) {
    var s = String(b64).replace(/[\t\n\f\r ]/g, '');
    if (s.length % 4 === 1) throw new Error('atob: 长度非法');
    var codes = [];
    for (var i = 0; i < s.length; i += 4) {
      var c1 = B64_LOOKUP[s.charAt(i)];
      var c2 = B64_LOOKUP[s.charAt(i + 1)];
      if (c1 === undefined || c2 === undefined) throw new Error('atob: 非法字符');
      codes.push((c1 << 2) | (c2 >> 4));
      var c3 = B64_LOOKUP[s.charAt(i + 2)];
      var c4 = B64_LOOKUP[s.charAt(i + 3)];
      if (s.charAt(i + 2) !== '=' && c3 !== undefined) {
        codes.push(((c2 & 15) << 4) | (c3 >> 2));
        if (s.charAt(i + 3) !== '=' && c4 !== undefined) {
          codes.push(((c3 & 3) << 6) | c4);
        }
      }
    }
    var out = '';
    for (var j = 0; j < codes.length; j++) out += String.fromCharCode(codes[j]);
    return out;
  };

  // ==================== Blob / crypto / navigator / performance ====================

  G.Blob = function Blob(parts, options) {
    var chunks = [];
    var total = 0;
    var list = Array.isArray(parts) ? parts : (parts ? [parts] : []);
    for (var i = 0; i < list.length; i++) {
      var p = list[i];
      var u8;
      if (typeof p === 'string') u8 = utf8Encode(p);
      else if (p instanceof Uint8Array) u8 = p;
      else if (p && p.__xyIsBlob) u8 = p.__xyBytes;
      else u8 = utf8Encode(String(p));
      chunks.push(u8);
      total += u8.length;
    }
    this.size = total;
    this.type = (options && options.type) || '';
    this.__xyBytes = (function () {
      var merged = new Uint8Array(total);
      var off = 0;
      for (var i = 0; i < chunks.length; i++) { merged.set(chunks[i], off); off += chunks[i].length; }
      return merged;
    })();
    this.__xyIsBlob = true;
  };
  G.Blob.prototype.arrayBuffer = function () {
    var ab = new ArrayBuffer(this.__xyBytes.length);
    new Uint8Array(ab).set(this.__xyBytes);
    return Promise.resolve(ab);
  };
  G.Blob.prototype.text = function () {
    return Promise.resolve(utf8Decode(this.__xyBytes));
  };
  G.Blob.prototype.slice = function (start, end) {
    var b = new G.Blob([]);
    b.__xyBytes = this.__xyBytes.subarray(start || 0, end);
    b.size = b.__xyBytes.length;
    b.type = this.type;
    return b;
  };

  function randomBytesU8(n) {
    var B = getBuffer();
    var b64 = __xyNativeRandomBytes(Math.max(0, Math.floor(n)));
    if (!B) {
      // 兜底：Buffer 未就绪时不应发生（packages 先于插件加载）
      throw new Error('crypto: Buffer 未就绪');
    }
    return new Uint8Array(B.from(b64, 'base64'));
  }

  G.crypto = {
    getRandomValues: function (arr) {
      var bytes = randomBytesU8(arr.length);
      for (var i = 0; i < arr.length; i++) arr[i] = bytes[i];
      return arr;
    },
    randomUUID: function () {
      var bytes = randomBytesU8(16);
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      var hex = '';
      for (var i = 0; i < 16; i++) hex += ('0' + bytes[i].toString(16)).slice(-2);
      return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
    },
  };

  G.navigator = {
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    language: 'zh-CN',
    languages: ['zh-CN', 'zh'],
    platform: 'Win32',
  };

  G.performance = {
    now: function () { return Date.now(); },
  };

  // ==================== URLSearchParams / URL polyfill ====================

  function decodeFormComponent(s) {
    return decodeURIComponent(String(s).replace(/\+/g, ' '));
  }

  function URLSearchParams_init(entries, pairs) {
    if (entries === undefined || entries === null) return;
    if (typeof entries === 'string') {
      var q = entries.charAt(0) === '?' ? entries.slice(1) : entries;
      if (!q) return;
      var parts = q.split('&');
      for (var i = 0; i < parts.length; i++) {
        if (!parts[i]) continue;
        var eq = parts[i].indexOf('=');
        var k, v;
        if (eq < 0) { k = parts[i]; v = ''; }
        else { k = parts[i].slice(0, eq); v = parts[i].slice(eq + 1); }
        pairs.push([decodeFormComponent(k), decodeFormComponent(v)]);
      }
    } else if (typeof entries.forEach === 'function' && typeof entries.append === 'function') {
      // 另一个 URLSearchParams 实例
      entries.forEach(function (v, k) { pairs.push([k, v]); });
    } else if (typeof entries === 'object') {
      for (var key in entries) {
        if (Object.prototype.hasOwnProperty.call(entries, key)) pairs.push([key, String(entries[key])]);
      }
    } else if (Array.isArray(entries)) {
      for (var j = 0; j < entries.length; j++) {
        var pair = entries[j];
        if (pair && pair.length >= 2) pairs.push([String(pair[0]), String(pair[1])]);
      }
    }
  }

  function URLSearchParams(entries) {
    var pairs = [];
    URLSearchParams_init(entries, pairs);

    function indexOfKey(name) {
      for (var i = 0; i < pairs.length; i++) {
        if (pairs[i][0] === name) return i;
      }
      return -1;
    }

    this.append = function (name, value) { pairs.push([String(name), String(value)]); };
    this.delete = function (name) {
      for (var i = pairs.length - 1; i >= 0; i--) {
        if (pairs[i][0] === String(name)) pairs.splice(i, 1);
      }
    };
    this.get = function (name) {
      var i = indexOfKey(String(name));
      return i < 0 ? null : pairs[i][1];
    };
    this.getAll = function (name) {
      var out = [];
      for (var i = 0; i < pairs.length; i++) {
        if (pairs[i][0] === String(name)) out.push(pairs[i][1]);
      }
      return out;
    };
    this.has = function (name) { return indexOfKey(String(name)) >= 0; };
    this.set = function (name, value) {
      var i = indexOfKey(String(name));
      if (i >= 0) { pairs[i][1] = String(value); return; }
      this.append(name, value);
    };
    this.forEach = function (cb) {
      for (var i = 0; i < pairs.length; i++) cb(pairs[i][1], pairs[i][0], this);
    };
    this.keys = function () {
      var out = [];
      this.forEach(function (v, k) { out.push(k); });
      return out;
    };
    this.values = function () {
      var out = [];
      this.forEach(function (v) { out.push(v); });
      return out;
    };
    this.entries = function () {
      var out = [];
      this.forEach(function (v, k) { out.push([k, v]); });
      return out;
    };
    this.toString = function () {
      var parts = [];
      for (var i = 0; i < pairs.length; i++) {
        parts.push(encodeURIComponent(pairs[i][0]) + '=' + encodeURIComponent(pairs[i][1]));
      }
      return parts.join('&');
    };
  }
  G.URLSearchParams = URLSearchParams;

  var URL_PATTERN = /^([a-zA-Z][a-zA-Z0-9+.-]*:)?(?:\/\/(?:([^@/?#]*)@)?([^/?#]*))?([^?#]*)(\?[^#]*)?(#.*)?$/;

  function parseUrlParts(href) {
    var m = URL_PATTERN.exec(href);
    if (!m) return null;
    var protocol = m[1] || '';
    var hasAuthority = href.indexOf('//') === 0 || (protocol && href.slice(protocol.length).indexOf('//') === 0);
    var host = hasAuthority ? (m[3] || '') : '';
    var pathname = m[4] || (hasAuthority ? '/' : '');
    var search = m[5] || '';
    var hash = m[6] || '';
    var hostname = host;
    var port = '';
    var idx = host.lastIndexOf(':');
    if (idx >= 0) {
      var maybePort = host.slice(idx + 1);
      if (/^\d*$/.test(maybePort)) {
        hostname = host.slice(0, idx);
        port = maybePort;
      }
    }
    return {
      protocol: protocol,
      hostname: hostname,
      port: port,
      pathname: pathname.charAt(0) === '/' ? pathname : (hasAuthority && pathname ? '/' + pathname : pathname),
      search: search,
      hash: hash,
    };
  }

  function buildHref(p) {
    var out = '';
    if (p.protocol) out += p.protocol;
    if (p.hostname || p.port) out += '//' + p.hostname + (p.port ? ':' + p.port : '');
    out += p.pathname || (p.hostname ? '/' : '');
    out += p.search || '';
    out += p.hash || '';
    return out;
  }

  function Url(href, base) {
    var raw = String(href);
    if (base !== undefined && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(raw)) {
      var b = new Url(base);
      // 相对路径解析（覆盖插件常用场景：以 basePath 拼接）
      if (raw.charAt(0) === '/') {
        raw = b.protocol + '//' + b.host + raw;
      } else if (raw.charAt(0) === '#') {
        raw = b.protocol + '//' + b.host + b.pathname + b.search + raw;
      } else {
        var dir = b.pathname.slice(0, b.pathname.lastIndexOf('/') + 1);
        raw = b.protocol + '//' + b.host + dir + raw;
      }
    }
    var parts = parseUrlParts(raw);
    if (!parts || !parts.protocol) {
      throw new TypeError('Invalid URL: ' + href);
    }
    this.__parts = parts;
  }

  Object.defineProperties(Url.prototype, {
    href: {
      get: function () { return buildHref(this.__parts); },
      set: function (v) {
        var parts = parseUrlParts(String(v));
        if (!parts || !parts.protocol) throw new TypeError('Invalid URL: ' + v);
        this.__parts = parts;
      },
    },
    protocol: {
      get: function () { return this.__parts.protocol; },
      set: function (v) { this.__parts.protocol = String(v).charAt(0) === ':' ? v : v + ':'; },
    },
    host: {
      get: function () { return this.__parts.hostname + (this.__parts.port ? ':' + this.__parts.port : ''); },
      set: function (v) {
        var m = /^([^:]*)(?::(\d*))?$/.exec(String(v));
        this.__parts.hostname = m ? m[1] : String(v);
        this.__parts.port = m && m[2] ? m[2] : '';
      },
    },
    hostname: {
      get: function () { return this.__parts.hostname; },
      set: function (v) { this.__parts.hostname = String(v); },
    },
    port: {
      get: function () { return this.__parts.port; },
      set: function (v) { this.__parts.port = String(v); },
    },
    pathname: {
      get: function () { return this.__parts.pathname || '/'; },
      set: function (v) { this.__parts.pathname = String(v).charAt(0) === '/' ? v : '/' + v; },
    },
    search: {
      get: function () { return this.__parts.search; },
      set: function (v) {
        var s = String(v);
        this.__parts.search = s && s.charAt(0) === '?' ? s : (s ? '?' + s : '');
      },
    },
    hash: {
      get: function () { return this.__parts.hash; },
      set: function (v) {
        var h = String(v);
        this.__parts.hash = h && h.charAt(0) === '#' ? h : (h ? '#' + h : '');
      },
    },
    origin: {
      get: function () {
        return this.__parts.protocol + '//' + this.host;
      },
    },
  });

  Object.defineProperty(Url.prototype, 'searchParams', {
    get: function () {
      var self = this;
      var sp = new URLSearchParams(this.__parts.search);
      // 同步回写：searchParams 修改后反映到 search
      var origSet = sp.set.bind(sp);
      var origAppend = sp.append.bind(sp);
      var origDelete = sp.delete.bind(sp);
      sp.set = function (k, v) { origSet(k, v); self.__parts.search = sp.toString() ? '?' + sp.toString() : ''; };
      sp.append = function (k, v) { origAppend(k, v); self.__parts.search = '?' + sp.toString(); };
      sp.delete = function (k) { origDelete(k); self.__parts.search = sp.toString() ? '?' + sp.toString() : ''; };
      return sp;
    },
  });

  Url.prototype.toString = function () { return this.href; };
  Url.prototype.toJSON = function () { return this.href; };
  Url.canParse = function (url, base) {
    try { new Url(url, base); return true; } catch (e) { return false; }
  };

  G.URL = Url;

  // ==================== HTTP 请求（fetch / lx.request / axios adapter 共用）====================

  function nativeRequest(method, url, headers, body, timeoutMs, follow, wantBinary) {
    // timeoutMs: 0 = 引擎默认 30s；follow: null/undefined = 引擎默认 10 次重定向，0 = 不跟随
    var t = timeoutMs == null ? 0 : Math.max(0, Number(timeoutMs) || 0);
    var f = follow == null || follow === undefined ? -1 : Math.max(0, Number(follow) || 0);
    return Promise.resolve(__xyNativeHttpRequest(
      String(method || 'GET').toUpperCase(),
      String(url || ''),
      JSON.stringify(headers || {}),
      body == null ? '' : String(body),
      t,
      f,
      !!wantBinary,
    )).then(function (json) {
      var res = JSON.parse(json);
      if (!res || res.error) {
        var err = new Error(res && res.error ? res.error : 'HTTP 请求失败');
        err.__xyNoResponse = true;
        throw err;
      }
      return res;
    });
  }

  function makeHeadersProxy(headers) {
    var map = {};
    var keys = [];
    if (headers && typeof headers === 'object') {
      for (var k in headers) {
        if (Object.prototype.hasOwnProperty.call(headers, k)) {
          map[k.toLowerCase()] = String(headers[k]);
          keys.push(k.toLowerCase());
        }
      }
    }
    return {
      get: function (name) { return map[String(name).toLowerCase()] || null; },
      has: function (name) { return String(name).toLowerCase() in map; },
      forEach: function (cb) { for (var i = 0; i < keys.length; i++) cb(map[keys[i]], keys[i]); },
      keys: function () { return keys.slice(); },
    };
  }

  function makeResponse(res) {
    var status = res.status || 0;
    var response = {
      ok: status >= 200 && status < 300,
      status: status,
      statusText: status >= 200 && status < 300 ? 'OK' : 'Error',
      url: res.url || '',
      headers: makeHeadersProxy(res.headers),
      redirected: false,
      type: 'basic',
      __xyBodyText: res.body || '',
      __xyBodyBase64: res.bodyBase64 || '',
    };
    response.text = function () { return Promise.resolve(response.__xyBodyText); };
    response.json = function () {
      return Promise.resolve().then(function () { return JSON.parse(response.__xyBodyText); });
    };
    response.arrayBuffer = function () {
      return Promise.resolve().then(function () {
        var B = getBuffer();
        if (!response.__xyBodyBase64) return new ArrayBuffer(0);
        if (!B) throw new Error('arrayBuffer: Buffer 未就绪');
        var u8 = new Uint8Array(B.from(response.__xyBodyBase64, 'base64'));
        var ab = new ArrayBuffer(u8.length);
        new Uint8Array(ab).set(u8);
        return ab;
      });
    };
    response.blob = function () {
      return response.arrayBuffer().then(function (ab) { return new G.Blob([ab]); });
    };
    response.clone = function () { return makeResponse(res); };
    return response;
  }

  G.fetch = function (input, init) {
    return Promise.resolve().then(function () {
      init = init || {};
      var urlStr;
      if (typeof input === 'string') urlStr = input;
      else if (input && input instanceof Url) urlStr = input.href;
      else if (input && typeof input.url === 'string') urlStr = input.url;
      else urlStr = String(input);

      if (!/^https?:\/\//i.test(urlStr)) {
        throw new TypeError('Failed to parse URL from ' + urlStr);
      }

      // 对直接拼接在 URL 中的 Query 参数自动补全 type <-> quality
      if (urlStr.indexOf('type=') >= 0 && urlStr.indexOf('quality=') < 0) {
        var matchType = urlStr.match(/[?&]type=([^&]+)/);
        if (matchType && matchType[1]) {
          urlStr += '&quality=' + matchType[1];
        }
      } else if (urlStr.indexOf('quality=') >= 0 && urlStr.indexOf('type=') < 0) {
        var matchQual = urlStr.match(/[?&]quality=([^&]+)/);
        if (matchQual && matchQual[1]) {
          urlStr += '&type=' + matchQual[1];
        }
      }

      var method = String(init.method || (input && input.method) || 'GET').toUpperCase();
      var headers = {};
      var h = init.headers || (input && input.headers);
      if (h) {
        if (typeof h.forEach === 'function' && typeof h.get === 'function') {
          h.forEach(function (v, k) { headers[k] = String(v); });
        } else if (Array.isArray(h)) {
          for (var i = 0; i < h.length; i++) {
            if (h[i] && h[i].length >= 2) headers[String(h[i][0])] = String(h[i][1]);
          }
        } else if (typeof h === 'object') {
          for (var k in h) {
            if (Object.prototype.hasOwnProperty.call(h, k)) headers[k] = String(h[k]);
          }
        }
      }

      var body;
      if (init.body !== undefined && init.body !== null) {
        if (typeof init.body === 'string') body = init.body;
        else if (init.body instanceof Url) body = init.body.href;
        else body = String(init.body);
      }

      return nativeRequest(method, urlStr, headers, body, init.timeout || 0, undefined, false).then(makeResponse);
    });
  };

  // ==================== zlib / pako（原生 flate2 桥接）====================

  function toU8(data) {
    if (data instanceof Uint8Array) return data;
    var B = getBuffer();
    if (B && data && data._isBuffer) return new Uint8Array(data);
    if (B && typeof B.isBuffer === 'function' && B.isBuffer(data)) return new Uint8Array(data);
    return new Uint8Array(utf8Encode(String(data)));
  }

  function u8ToBase64(u8) {
    var B = getBuffer();
    if (!B) throw new Error('zlib: Buffer 未就绪');
    return B.from(u8).toString('base64');
  }

  function base64ToBytes(b64) {
    // 返回 Buffer 而非普通 Uint8Array：与原 worker 实现一致，
    // 保证 Buffer.isBuffer(zlib.inflateSync(...)) 为 true
    var B = getBuffer();
    if (!B) throw new Error('zlib: Buffer 未就绪');
    return B.from(String(b64), 'base64');
  }

  function nativeInflate(method, data) {
    return base64ToBytes(__xyNativeInflate(method, u8ToBase64(toU8(data))));
  }

  function nativeDeflate(method, data) {
    return base64ToBytes(__xyNativeDeflate(method, u8ToBase64(toU8(data))));
  }

  function maybeString(u8, options) {
    if (options && options.to === 'string') return utf8Decode(u8);
    return u8;
  }

  var zlibPkg = {
    inflate: function (data, options, callback) {
      if (typeof options === 'function') { callback = options; options = undefined; }
      var run = function () { return maybeString(nativeInflate('auto', data), options); };
      if (callback) {
        try { callback(null, run()); } catch (e) { callback(e); }
        return;
      }
      return run();
    },
    inflateSync: function (data, options) {
      return maybeString(nativeInflate('auto', data), options);
    },
    inflateRaw: function (data, options, callback) {
      if (typeof options === 'function') { callback = options; options = undefined; }
      var run = function () { return maybeString(nativeInflate('raw', data), options); };
      if (callback) {
        try { callback(null, run()); } catch (e) { callback(e); }
        return;
      }
      return run();
    },
    inflateRawSync: function (data, options) {
      return maybeString(nativeInflate('raw', data), options);
    },
    gunzip: function (data, options, callback) {
      if (typeof options === 'function') { callback = options; options = undefined; }
      var run = function () { return maybeString(nativeInflate('gzip', data), options); };
      if (callback) {
        try { callback(null, run()); } catch (e) { callback(e); }
        return;
      }
      return run();
    },
    gunzipSync: function (data, options) {
      return maybeString(nativeInflate('gzip', data), options);
    },
    deflate: function (data, options, callback) {
      if (typeof options === 'function') { callback = options; options = undefined; }
      var run = function () { return nativeDeflate('zlib', data); };
      if (callback) {
        try { callback(null, run()); } catch (e) { callback(e); }
        return;
      }
      return run();
    },
    deflateSync: function (data, options) {
      return nativeDeflate('zlib', data);
    },
    deflateRaw: function (data, options, callback) {
      if (typeof options === 'function') { callback = options; options = undefined; }
      var run = function () { return nativeDeflate('raw', data); };
      if (callback) {
        try { callback(null, run()); } catch (e) { callback(e); }
        return;
      }
      return run();
    },
    deflateRawSync: function (data, options) {
      return nativeDeflate('raw', data);
    },
    gzip: function (data, options, callback) {
      if (typeof options === 'function') { callback = options; options = undefined; }
      var run = function () { return nativeDeflate('gzip', data); };
      if (callback) {
        try { callback(null, run()); } catch (e) { callback(e); }
        return;
      }
      return run();
    },
    gzipSync: function (data, options) {
      return nativeDeflate('gzip', data);
    },
    constants: {
      Z_NO_FLUSH: 0, Z_PARTIAL_FLUSH: 1, Z_SYNC_FLUSH: 2, Z_FULL_FLUSH: 3,
      Z_FINISH: 4, Z_BLOCK: 5, Z_TREES: 6,
      Z_OK: 0, Z_STREAM_END: 1, Z_NEED_DICT: 2,
      Z_ERRNO: -1, Z_STREAM_ERROR: -2, Z_DATA_ERROR: -3, Z_BUF_ERROR: -5,
    },
  };

  var pakoPkg = {
    inflate: function (data, options) { return maybeString(nativeInflate('auto', data), options); },
    inflateRaw: function (data, options) { return maybeString(nativeInflate('raw', data), options); },
    ungzip: function (data, options) { return maybeString(nativeInflate('gzip', data), options); },
    gzip: function (data, options) { return maybeString(nativeDeflate('gzip', data), options); },
    deflate: function (data, options) { return maybeString(nativeDeflate('zlib', data), options); },
    deflateRaw: function (data, options) { return maybeString(nativeDeflate('raw', data), options); },
  };

  // ==================== Cookie / Storage 代理包 ====================

  var proxyCookiesPkg = {
    set: function (url, cookie) {
      return Promise.resolve(__xyNativeCookieSet(String(url), JSON.stringify(cookie))).then(function (json) {
        var r = JSON.parse(json);
        if (!r || !r.ok) throw new Error((r && r.error) || 'cookie set failed');
        return !!r.data;
      });
    },
    get: function (url) {
      return Promise.resolve(__xyNativeCookieGet(String(url))).then(function (json) {
        var r = JSON.parse(json);
        if (!r || !r.ok) throw new Error((r && r.error) || 'cookie get failed');
        return r.data || {};
      });
    },
    flush: function () {
      return Promise.resolve(__xyNativeCookieFlush()).then(function () { return undefined; });
    },
  };

  var storagePkg = {
    setItem: function (key, value) {
      var raw = typeof value === 'string' ? value : JSON.stringify(value);
      return Promise.resolve(__xyNativeStorageSet(String(key), raw)).then(function (json) {
        var r = JSON.parse(json);
        if (!r || !r.ok) throw new Error((r && r.error) || 'storage set failed');
        return undefined;
      });
    },
    getItem: function (key) {
      return Promise.resolve(__xyNativeStorageGet(String(key))).then(function (json) {
        var r = JSON.parse(json);
        if (!r || !r.ok) throw new Error((r && r.error) || 'storage get failed');
        return r.data === undefined ? null : r.data;
      });
    },
    removeItem: function (key) {
      return Promise.resolve(__xyNativeStorageRemove(String(key))).then(function (json) {
        var r = JSON.parse(json);
        if (!r || !r.ok) throw new Error((r && r.error) || 'storage remove failed');
        return undefined;
      });
    },
  };

  // ==================== Node 全局模拟（混淆 LX 插件依赖）====================
  //
  // 重度混淆的 LX 插件用自定义 VM 解释器运行，会以自由变量或 globalThis
  // 方式访问 Node.js 全局对象。这里提供安全模拟，绝不真正执行系统命令。

  var childProcessStub = {
    exec: function (_cmd, options, callback) {
      if (typeof options === 'function') callback = options;
      if (typeof callback === 'function') {
        try { callback(null, '', ''); } catch (e) { /* ignore */ }
      }
      return { stdout: '', stderr: '', pid: 0, exitCode: 0, on: function () {}, once: function () {}, kill: function () {} };
    },
    execFile: function (_file) {
      var rest = Array.prototype.slice.call(arguments, 1);
      var callback = null;
      for (var i = 0; i < rest.length; i++) {
        if (typeof rest[i] === 'function') { callback = rest[i]; break; }
      }
      if (callback) { try { callback(null, '', ''); } catch (e) { /* ignore */ } }
      return { stdout: '', stderr: '', pid: 0, exitCode: 0, on: function () {}, once: function () {}, kill: function () {} };
    },
    spawn: function () {
      return { stdout: '', stderr: '', pid: 0, exitCode: 0, on: function () {}, once: function () {}, kill: function () {} };
    },
    fork: function () {
      return { stdout: '', stderr: '', pid: 0, exitCode: 0, on: function () {}, once: function () {}, kill: function () {} };
    },
    execSync: function () { return new Uint8Array(0); },
    execFileSync: function () { return new Uint8Array(0); },
    spawnSync: function () { return { stdout: new Uint8Array(0), stderr: new Uint8Array(0), status: 0, pid: 0 }; },
  };

  var cryptoShim = {
    createHash: function (algo) {
      var CryptoJs = getCryptoJs();
      var normalized = String(algo).toLowerCase().replace(/-/g, '');
      var hash = normalized === 'md5' ? CryptoJs.MD5
        : normalized === 'sha1' ? CryptoJs.SHA1
        : normalized === 'sha256' ? CryptoJs.SHA256
        : normalized === 'sha512' ? CryptoJs.SHA512
        : null;
      if (!hash) throw new Error('crypto: 不支持的哈希算法 ' + algo);
      var data = '';
      var B = getBuffer();
      return {
        update: function (input) { data = input; return this; },
        digest: function (encoding) {
          var result = hash(data || '').toString();
          if (encoding === 'hex' || encoding === undefined) return result;
          return B.from(result, 'hex');
        },
      };
    },
    createHmac: function (algo, key) {
      var CryptoJs = getCryptoJs();
      var normalized = String(algo).toLowerCase().replace(/-/g, '');
      var hmac = normalized === 'md5' ? CryptoJs.HmacMD5
        : normalized === 'sha1' ? CryptoJs.HmacSHA1
        : normalized === 'sha256' ? CryptoJs.HmacSHA256
        : null;
      if (!hmac) throw new Error('crypto: 不支持的 HMAC 算法 ' + algo);
      var data = '';
      var B = getBuffer();
      return {
        update: function (input) { data = input; return this; },
        digest: function (encoding) {
          var result = hmac(data || '', key).toString();
          if (encoding === 'hex' || encoding === undefined) return result;
          return B.from(result, 'hex');
        },
      };
    },
    randomBytes: function (size) { return randomBytesU8(size); },
    randomUUID: function () { return G.crypto.randomUUID(); },
    timingSafeEqual: function (a, b) {
      var ba = toU8(a), bb = toU8(b);
      if (ba.length !== bb.length) return false;
      var diff = 0;
      for (var i = 0; i < ba.length; i++) diff |= ba[i] ^ bb[i];
      return diff === 0;
    },
  };

  var lxProcess = {
    platform: 'win32',
    arch: 'x64',
    version: 'v20.0.0',
    versions: { node: '20.0.0', v8: '11.3.244.8', uv: '1.44.2', zlib: '1.2.13', openssl: '3.0.8' },
    env: {},
    pid: 12345,
    kill: function () { return true; },
    nextTick: function (fn) {
      var args = Array.prototype.slice.call(arguments, 1);
      Promise.resolve().then(function () { fn.apply(null, args); });
    },
    cwd: function () { return '/'; },
    browser: false,
  };

  // ==================== require 体系 ====================

  var requireCache = {};

  function __xyRequire(packageName) {
    if (packageName in requireCache) return requireCache[packageName];
    var pkgs = getPackages();
    var pkg;
    switch (packageName) {
      case 'child_process': pkg = childProcessStub; break;
      case 'crypto': pkg = cryptoShim; break;
      case 'zlib': pkg = zlibPkg; break;
      case 'pako': pkg = pakoPkg; break;
      case 'buffer': pkg = { Buffer: getBuffer() }; break;
      case '@react-native-cookies/cookies': pkg = proxyCookiesPkg; break;
      case 'musicfree/storage': pkg = storagePkg; break;
      default:
        pkg = pkgs[packageName] || null;
        break;
    }
    if (!pkg) return null;
    try { pkg.default = pkg; } catch (e) { /* frozen 对象忽略 */ }
    requireCache[packageName] = pkg;
    return pkg;
  }

  G.__xyRequire = __xyRequire;

  function lxRequire(name) {
    var pkg = __xyRequire(name);
    if (pkg) return pkg;
    switch (name) {
      case 'crypto-js': return getCryptoJs();
      default:
        throw new Error("Cannot find module '" + name + "'");
    }
  }

  // ==================== axios 代理适配器（对齐 worker tauriAdapter）====================

  // 部分插件（如汽水音乐）用 axios.post(url, Buffer, { transformRequest: [d => d] })
  // 发送签名请求体（UTF-8 编码的 JSON 字节）。若直接 JSON.stringify,Buffer 会被序列化成
  // {"type":"Buffer","data":[...]} 而损坏,导致服务端验签失败。这里按 UTF-8 还原成字符串,
  // Rust 侧再以 UTF-8 重编码,字节保持一致。普通对象/数组仍走 JSON.stringify。
  function toBodyUtf8String(data) {
    if (typeof data === 'string') return data;
    var u8 = data;
    if (data instanceof ArrayBuffer) {
      u8 = new Uint8Array(data);
    } else if (typeof ArrayBuffer.isView === 'function' && ArrayBuffer.isView(data)) {
      u8 = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    }
    if (!u8 || typeof u8.length !== 'number') {
      try { return JSON.stringify(data); } catch (e) { return String(data); }
    }
    if (typeof TextDecoder !== 'undefined') {
      try { return new TextDecoder('utf-8').decode(u8); } catch (e) { /* fallthrough */ }
    }
    // TextDecoder 不可用时的手动 UTF-8 解码
    var out = '', i = 0;
    while (i < u8.length) {
      var c0 = u8[i++];
      var cp;
      if (c0 < 0x80) { out += String.fromCharCode(c0); continue; }
      if (c0 >= 0xF0 && i + 3 <= u8.length) {
        cp = ((c0 & 0x07) << 18) | ((u8[i++] & 0x3F) << 12) | ((u8[i++] & 0x3F) << 6) | (u8[i++] & 0x3F);
        if (cp > 0xFFFF) {
          cp -= 0x10000;
          out += String.fromCharCode((cp >> 10) + 0xD800, (cp & 0x3FF) + 0xDC00);
        } else { out += String.fromCharCode(cp); }
      } else if (c0 >= 0xE0 && i + 2 <= u8.length) {
        cp = ((c0 & 0x0F) << 12) | ((u8[i++] & 0x3F) << 6) | (u8[i++] & 0x3F);
        out += String.fromCharCode(cp);
      } else if (c0 >= 0xC0 && i + 1 <= u8.length) {
        cp = ((c0 & 0x1F) << 6) | (u8[i++] & 0x3F);
        out += String.fromCharCode(cp);
      } else {
        out += String.fromCharCode(c0);
      }
    }
    return out;
  }

  function xyAxiosAdapter(config) {
    return Promise.resolve().then(function () {
      var method = (config.method || 'GET').toUpperCase();
      var url = config.url || '';
      if (config.baseURL && !/^https?:\/\//.test(url)) {
        url = config.baseURL + url;
      }

      var pkgs = getPackages();
      if (config.params) {
        var cleanParams = {};
        for (var key in config.params) {
          if (!Object.prototype.hasOwnProperty.call(config.params, key)) continue;
          var value = config.params[key];
          // 数组值取第一个元素，模拟 axios 默认 paramsSerializer 对单值行为
          cleanParams[key] = Array.isArray(value) ? value[0] : value;
        }
        // 兼容音源服务端 v1：自动对齐 type 与 quality 字段
        if (cleanParams.type && !cleanParams.quality) {
          cleanParams.quality = cleanParams.type;
        } else if (cleanParams.quality && !cleanParams.type) {
          cleanParams.type = cleanParams.quality;
        }
        var paramStr = pkgs.qs.stringify(cleanParams);
        url += (url.indexOf('?') >= 0 ? '&' : '?') + paramStr;
      }

      // 对直接拼接在 URL 中的 Query 参数同样自动补全 type <-> quality
      if (url.indexOf('type=') >= 0 && url.indexOf('quality=') < 0) {
        var matchType = url.match(/[?&]type=([^&]+)/);
        if (matchType && matchType[1]) {
          url += '&quality=' + matchType[1];
        }
      } else if (url.indexOf('quality=') >= 0 && url.indexOf('type=') < 0) {
        var matchQual = url.match(/[?&]quality=([^&]+)/);
        if (matchQual && matchQual[1]) {
          url += '&type=' + matchQual[1];
        }
      }

      var headers = {};
      if (config.headers) {
        var headerObj = config.headers;
        // axios AxiosHeaders 实例支持 forEach
        if (typeof headerObj.forEach === 'function') {
          headerObj.forEach(function (v, k) {
            if (typeof v === 'string' && !['Accept-Encoding', 'Connection'].includes(k)) headers[k] = v;
          });
        } else {
          for (var hk in headerObj) {
            if (!Object.prototype.hasOwnProperty.call(headerObj, hk)) continue;
            var hv = headerObj[hk];
            if (typeof hv === 'string' && !['Accept-Encoding', 'Connection'].includes(hk)) headers[hk] = hv;
          }
        }
      }

      var body;
      if (config.data !== undefined && config.data !== null) {
        var reqData = config.data;
        // 自动适配对齐音源服务端：若数据为对象，同时填充 type 与 quality，兼容仅认 quality 的 v1 接口
        if (typeof reqData === 'object' && reqData !== null) {
          try {
            if (reqData.type && !reqData.quality) {
              reqData.quality = reqData.type;
            } else if (reqData.quality && !reqData.type) {
              reqData.type = reqData.quality;
            }
          } catch (e) { /* ignore */ }
        } else if (typeof reqData === 'string' && reqData.indexOf('{') >= 0) {
          try {
            var parsed = JSON.parse(reqData);
            if (parsed && typeof parsed === 'object') {
              if (parsed.type && !parsed.quality) parsed.quality = parsed.type;
              else if (parsed.quality && !parsed.type) parsed.type = parsed.quality;
              reqData = JSON.stringify(parsed);
            }
          } catch (e) { /* ignore */ }
        }
        body = toBodyUtf8String(reqData);
        if (body && body.length > 256 * 1024) {
          body = body.substring(0, 256 * 1024);
        }
        if (!headers['Content-Type'] && !headers['content-type']) {
          headers['Content-Type'] = 'application/json';
        }
      }

      if (!url || !/^https?:\/\//.test(url)) {
        throw new Error('Invalid URL: ' + (url || '(empty)'));
      }

      var responseType = String(config.responseType || '').toLowerCase();
      var wantsBinary = responseType === 'arraybuffer' || responseType === 'blob';
      // Cookie 注入与 Set-Cookie 捕获由原生 HTTP 桥统一处理

      return nativeRequest(method, url, headers, body, config.timeout || 0, undefined, wantsBinary).then(function (res) {
        var responseData;
        if (wantsBinary) {
          var B = getBuffer();
          if (!B) throw new Error('axios: Buffer 未就绪');
          var u8 = new Uint8Array(B.from(res.bodyBase64 || '', 'base64'));
          if (responseType === 'blob') {
            responseData = new G.Blob([u8]);
          } else {
            var ab = new ArrayBuffer(u8.length);
            new Uint8Array(ab).set(u8);
            responseData = ab;
          }
        } else {
          try {
            responseData = JSON.parse(res.body);
          } catch (e) {
            responseData = res.body;
          }
        }

        var axiosResponse = {
          data: responseData,
          status: res.status,
          statusText: res.status >= 200 && res.status < 300 ? 'OK' : 'Error',
          headers: res.headers,
          config: config,
        };

        var validateStatus = config.validateStatus || (function (s) { return s >= 200 && s < 300; });
        if (!validateStatus(res.status)) {
          var error = new Error('Request failed with status code ' + res.status);
          error.response = axiosResponse;
          throw error;
        }

        return axiosResponse;
      }, function (e) {
        if (e && e.response) throw e;
        var errMsg = e && e.message ? e.message : (typeof e === 'string' ? e : 'Request failed');
        var err = new Error(errMsg);
        err.config = config;
        throw err;
      });
    });
  }

  function makeProxyAxios(axios) {
    if (!axios || typeof axios.create !== 'function') return axios;
    var inst = axios.create({ adapter: xyAxiosAdapter });
    inst.defaults.timeout = 15000;
    var originalCreate = inst.create.bind(inst);
    inst.create = function (config) {
      var nested = originalCreate(config);
      nested.defaults.adapter = xyAxiosAdapter;
      nested.defaults.timeout = 15000;
      nested.create = inst.create;
      return nested;
    };
    return inst;
  }

  G.__xyPostSetup = function () {
    var pkgs = getPackages();
    if (pkgs.buffer && pkgs.buffer.Buffer) {
      G.Buffer = pkgs.buffer.Buffer;
    }
    if (pkgs['crypto-js']) {
      G.CryptoJs = pkgs['crypto-js'];
      G.CryptoJS = pkgs['crypto-js'];
    }
    if (pkgs.axios) {
      pkgs.axios = makeProxyAxios(pkgs.axios);
    }
  };

  // ==================== MusicFree 插件加载器 ====================

  var mfUserVars = {};
  var mfInstance = null;

  function makeEnvProxy(pluginId) {
    var envBase = {
      getUserVariables: function () { return mfUserVars; },
      os: 'win32',
      appVersion: '1.0.0',
      lang: 'zh-CN',
    };
    return new Proxy(envBase, {
      get: function (target, prop, receiver) {
        if (prop in target) return Reflect.get(target, prop, receiver);
        if (prop === 'userVariables') return mfUserVars;
        if (typeof prop === 'string' && prop in mfUserVars) return mfUserVars[prop];
        return undefined;
      },
      has: function (target, prop) {
        if (prop in target) return true;
        if (prop === 'userVariables') return true;
        return prop in mfUserVars;
      },
      ownKeys: function (target) {
        return Reflect.ownKeys(target).concat(['userVariables'], Object.keys(mfUserVars));
      },
      getOwnPropertyDescriptor: function (target, prop) {
        if (prop in target) return Reflect.getOwnPropertyDescriptor(target, prop);
        if (typeof prop === 'string' && prop in mfUserVars) {
          return { configurable: true, enumerable: true, value: mfUserVars[prop], writable: false };
        }
        return undefined;
      },
    });
  }

  var MF_ALL_METHOD_NAMES = [
    'search', 'getMediaSource', 'getMvSource', 'getMusicInfo', 'getLyric',
    'getAlbumInfo', 'getArtistWorks', 'getTopLists', 'getTopListDetail',
    'importMusicSheet', 'importMusicItem', 'getMusicSheetInfo',
    'getRecommendSheetTags', 'getRecommendSheetsByTag',
    'getArtistInfo', 'getMusicComments', 'getMusicDetailPageUrl',
  ];

  G.__xyLoadMusicFree = function (script, userVarsJson) {
    try {
      mfUserVars = JSON.parse(userVarsJson || '{}') || {};
    } catch (e) {
      mfUserVars = {};
    }

    var _module = { exports: {} };
    var env = makeEnvProxy();
    var _process = {
      platform: 'win32',
      version: '1.0.0',
      env: env,
      ensurePluginInitialized: Promise.resolve(),
    };

    var pluginFn;
    try {
      pluginFn = new Function(
        'module', 'exports', 'require', '__musicfree_require', 'console', 'env', 'process', 'fetch', 'URL',
        '"use strict";\n' + script,
      );
    } catch (e) {
      return G.__xyErr(e);
    }

    try {
      pluginFn.call(
        _module.exports,
        _module,
        _module.exports,
        __xyRequire,
        __xyRequire,
        G.console,
        env,
        _process,
        G.fetch,
        G.URL,
      );
    } catch (e) {
      return G.__xyErr(e);
    }

    var instance = _module.exports && _module.exports.default ? _module.exports.default : _module.exports;
    mfInstance = instance;

    var availableMethods = [];
    for (var i = 0; i < MF_ALL_METHOD_NAMES.length; i++) {
      var m = MF_ALL_METHOD_NAMES[i];
      if (typeof instance[m] === 'function') availableMethods.push(m);
    }

    return JSON.stringify({
      ok: true,
      metadata: {
        platform: instance.platform,
        version: instance.version,
        appVersion: instance.appVersion,
        author: instance.author,
        description: instance.description,
        srcUrl: instance.srcUrl,
        primaryKey: instance.primaryKey,
        cacheControl: instance.cacheControl,
        supportedSearchType: instance.supportedSearchType,
        defaultSearchType: instance.defaultSearchType,
        userVariables: instance.userVariables,
        hints: instance.hints,
        supportedQualities: instance.supportedQualities,
        _availableMethods: availableMethods,
      },
    });
  };

  G.__xySetUserVars = function (userVarsJson) {
    try {
      mfUserVars = JSON.parse(userVarsJson || '{}') || {};
    } catch (e) {
      mfUserVars = {};
    }
  };

  G.__xyCallMusicFree = function (method, argsJson) {
    var args;
    try {
      args = JSON.parse(argsJson || '[]') || [];
    } catch (e) {
      args = [];
    }
    if (!mfInstance) {
      return Promise.reject(new Error('插件实例不存在'));
    }
    var fn = mfInstance[method];
    if (typeof fn !== 'function') {
      return Promise.reject(new Error('方法不存在: ' + method));
    }
    return Promise.resolve().then(function () {
      return fn.apply(mfInstance, args);
    });
  };

  // ==================== LX 插件支持 ====================

  var LX_SOURCE_KEYS = ['kw', 'kg', 'tx', 'wy', 'mg', 'xm', 'local'];
  var LX_MUSIC_ACTIONS = ['musicUrl', 'lyric', 'pic'];
  var LX_STANDARD_QUALITIES = [
    '96k', '128k', '192k', '320k', 'flac', 'flac24bit', 'hires',
    'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
  ];
  var LX_SUPPORT_QUALITIES = {
    kw: LX_STANDARD_QUALITIES,
    kg: LX_STANDARD_QUALITIES,
    tx: LX_STANDARD_QUALITIES,
    wy: LX_STANDARD_QUALITIES,
    mg: LX_STANDARD_QUALITIES,
    xm: LX_STANDARD_QUALITIES,
    local: [],
  };
  var LX_QUALITY_ALIASES = {
    '96k': 'mgg',
    mgg: 'mgg',
    '128': '128k',
    '128k': '128k',
    '192': '192k',
    '192k': '192k',
    '320': '320k',
    '320k': '320k',
    flac: 'flac',
    sq: 'flac',
    super: 'flac',
    lossless: 'flac',
    flac24: 'flac24bit',
    '24bit': 'flac24bit',
    '24bits': 'flac24bit',
    '24_bit': 'flac24bit',
    flac24bit: 'flac24bit',
    hires: 'hires',
    'hi-res': 'hires',
    hi_res: 'hires',
    hr: 'hires',
    vinyl: 'vinyl',
    dolby: 'dolby',
    atmos: 'atmos',
    atmosplus: 'atmos_plus',
    atmos_plus: 'atmos_plus',
    'atmos+': 'atmos_plus',
    master: 'master',
  };

  function normalizeLxQualityKey(raw) {
    if (typeof raw !== 'string') return null;
    var normalized = raw.trim().toLowerCase().replace(/\s+/g, '').replace(/-/g, '_');
    if (!normalized) return null;
    return LX_QUALITY_ALIASES[normalized] !== undefined ? LX_QUALITY_ALIASES[normalized] : null;
  }

  function qualityKeyToBakaPluginQuality(qualityKey) {
    return qualityKey === 'mgg' ? '96k' : qualityKey;
  }

  function normalizeLxQualitys(raw, allowed) {
    var allowedSet = allowed && allowed.length > 0 ? allowed.slice() : null;
    var result = [];
    var seen = {};
    for (var i = 0; i < raw.length; i++) {
      var item = raw[i];
      var qualityKey = normalizeLxQualityKey(item);
      var quality = qualityKey ? qualityKeyToBakaPluginQuality(qualityKey) : (typeof item === 'string' ? item.trim() : '');
      if (!quality) continue;
      if (allowedSet && allowedSet.indexOf(quality) < 0) continue;
      if (seen[quality]) continue;
      seen[quality] = true;
      result.push(quality);
    }
    return result;
  }

  function normalizeLxSourceInfo(info) {
    var sourceInfo = { sources: {} };
    if (!info || !info.sources || typeof info.sources !== 'object') return sourceInfo;

    for (var i = 0; i < LX_SOURCE_KEYS.length; i++) {
      var source = LX_SOURCE_KEYS[i];
      var userSource = info.sources[source];
      if (!userSource || userSource.type !== 'music') continue;
      sourceInfo.sources[source] = {
        name: typeof userSource.name === 'string' ? userSource.name : undefined,
        type: 'music',
        actions: LX_MUSIC_ACTIONS.filter(function (action) {
          return (Array.isArray(userSource.actions) ? userSource.actions : []).indexOf(action) >= 0;
        }),
        qualitys: normalizeLxQualitys(
          Array.isArray(userSource.qualitys) ? userSource.qualitys : [],
          LX_SUPPORT_QUALITIES[source] || [],
        ),
      };
    }

    for (var key in info.sources) {
      if (!Object.prototype.hasOwnProperty.call(info.sources, key)) continue;
      if (sourceInfo.sources[key]) continue;
      var val = info.sources[key];
      if (!val || val.type !== 'music') continue;
      sourceInfo.sources[key] = {
        name: typeof val.name === 'string' ? val.name : undefined,
        type: 'music',
        actions: LX_MUSIC_ACTIONS.filter(function (action) {
          return (Array.isArray(val.actions) ? val.actions : []).indexOf(action) >= 0;
        }),
        qualitys: normalizeLxQualitys(Array.isArray(val.qualitys) ? val.qualitys : []),
      };
    }

    return sourceInfo;
  }

  var lxRequestHandler = null;

  G.__xySetupLx = function (scriptInfoJson, script) {
    var scriptInfo = {};
    try {
      scriptInfo = JSON.parse(scriptInfoJson || '{}') || {};
    } catch (e) { /* ignore */ }

    var initResolve, initReject;
    var initPromise = new Promise(function (resolve, reject) {
      initResolve = resolve;
      initReject = reject;
    });

    var isInitedApi = false;
    var EVENT_NAMES = { request: 'request', inited: 'inited', updateAlert: 'updateAlert' };
    var eventNames = ['request', 'inited', 'updateAlert'];

    function handleInit(info) {
      if (!info) {
        initReject(new Error('Missing required parameter init info'));
        return;
      }
      try {
        var sourceInfo = normalizeLxSourceInfo(info);
        G.console.log('插件初始化成功, sources: ' + Object.keys(sourceInfo.sources).join(','));
        initResolve(sourceInfo);
      } catch (error) {
        initReject(new Error(error.message));
      }
    }

    function lxNativeRequest(method, url, headers, body, timeout, follow) {
      return nativeRequest(method, url, headers, body, timeout, follow, false).then(function (res) {
        return {
          statusCode: res.status,
          statusMessage: res.status >= 200 && res.status < 300 ? 'OK' : 'Error',
          headers: res.headers,
          body: res.body,
        };
      });
    }

    var lxApi = {
      EVENT_NAMES: EVENT_NAMES,
      request: function (url, options, callback) {
        var method = ((options && options.method) || 'get').toLowerCase();
        G.console.log('HTTP 请求: ' + method + ' ' + url);

        var bodyStr = '';
        var reqHeaders = {};
        var optHeaders = (options && options.headers) || {};
        for (var hk in optHeaders) {
          if (Object.prototype.hasOwnProperty.call(optHeaders, hk)) reqHeaders[hk] = optHeaders[hk];
        }

        if (options && options.body != null) {
          if (typeof options.body === 'string') {
            bodyStr = options.body;
          } else if (typeof options.body === 'object') {
            bodyStr = JSON.stringify(options.body);
            if (!reqHeaders['Content-Type'] && !reqHeaders['content-type']) reqHeaders['Content-Type'] = 'application/json';
          }
        } else if (options && options.form != null) {
          if (typeof options.form === 'string') {
            bodyStr = options.form;
          } else if (typeof options.form === 'object') {
            var formParts = [];
            for (var fk in options.form) {
              if (!Object.prototype.hasOwnProperty.call(options.form, fk)) continue;
              var fv = options.form[fk];
              if (fv == null) continue;
              formParts.push(encodeURIComponent(fk) + '=' + encodeURIComponent(String(fv)));
            }
            bodyStr = formParts.join('&');
          }
          if (!reqHeaders['Content-Type'] && !reqHeaders['content-type']) reqHeaders['Content-Type'] = 'application/x-www-form-urlencoded';
        } else if (options && options.formData != null) {
          if (typeof options.formData === 'string') {
            bodyStr = options.formData;
          } else if (typeof options.formData === 'object') {
            var formDataParts = [];
            for (var fdk in options.formData) {
              if (!Object.prototype.hasOwnProperty.call(options.formData, fdk)) continue;
              var fdv = options.formData[fdk];
              if (fdv == null) continue;
              formDataParts.push(encodeURIComponent(fdk) + '=' + encodeURIComponent(String(fdv)));
            }
            bodyStr = formDataParts.join('&');
          }
          if (!reqHeaders['Content-Type'] && !reqHeaders['content-type']) reqHeaders['Content-Type'] = 'application/x-www-form-urlencoded';
        }

        lxNativeRequest(method, url, reqHeaders, bodyStr, options && options.timeout, options && options.follow).then(function (response) {
          try {
            var body = response.body;
            try { body = JSON.parse(response.body); } catch (e) { /* 保持原始字符串 */ }
            var ct = '';
            try { ct = (response.headers && (response.headers['content-type'] || response.headers['Content-Type'])) || ''; } catch (e) {}
            G.console.log('HTTP 响应: ' + response.statusCode + ' ' + ct + ' ' + String(response.body).substring(0, 240));
            callback(null, {
              statusCode: response.statusCode,
              statusMessage: response.statusMessage,
              headers: response.headers,
              bytes: response.body.length,
              raw: response.body,
              body: body,
            }, body);
          } catch (err) {
            if (!isInitedApi) {
              G.console.error('request 回调异常: ' + (err && err.message));
              initReject(new Error((err && err.message) || 'request callback error'));
            }
          }
        }, function (err) {
          try { G.console.error('HTTP 请求失败: ' + ((err && err.message) || String(err))); } catch (e2) { /* ignore */ }
          try { callback(err, null, null); } catch (e) { /* ignore */ }
        });
        return function () { /* cancel noop */ };
      },
      send: function (eventName, data) {
        return new Promise(function (resolve, reject) {
          if (eventNames.indexOf(eventName) < 0) {
            reject(new Error('The event is not supported: ' + eventName));
            return;
          }
          if (eventName === EVENT_NAMES.inited) {
            if (isInitedApi) {
              reject(new Error('Script is inited'));
              return;
            }
            isInitedApi = true;
            handleInit(data);
            resolve(undefined);
          } else if (eventName === EVENT_NAMES.updateAlert) {
            // 参考 BakaMusic：LX 插件可自报更新（updateAlert），载荷通常是
            // { updateUrl, log }。当前更新检查以"重取插件脚本 filePath + 订阅清单版本"
            // 为准，这里不再静默丢弃，而是记录通告信息便于排查。
            try {
              G.console.log('[updateAlert] ' + (String(data && data.log || '').substring(0, 200)));
              if (data && data.updateUrl) {
                G.console.log('[updateAlert] updateUrl: ' + String(data.updateUrl).substring(0, 512));
              }
            } catch (e) { /* ignore */ }
            resolve(undefined);
          } else {
            reject(new Error('Unknown event name: ' + eventName));
          }
        });
      },
      on: function (eventName, handler) {
        if (eventNames.indexOf(eventName) < 0) {
          return Promise.reject(new Error('The event is not supported: ' + eventName));
        }
        if (eventName === EVENT_NAMES.request) {
          lxRequestHandler = handler;
        }
        return Promise.resolve();
      },
      utils: {
        crypto: {
          aesEncrypt: function (buffer, mode, key, iv) {
            var CryptoJs = getCryptoJs();
            var B = getBuffer();
            var encrypted = CryptoJs.AES.encrypt(buffer, key, { iv: iv, mode: CryptoJs[mode] });
            return B.from(encrypted.toString(), 'base64');
          },
          rsaEncrypt: function (buffer) {
            return buffer;
          },
          randomBytes: function (size) {
            return randomBytesU8(size);
          },
          md5: function (str) {
            var CryptoJs = getCryptoJs();
            return CryptoJs.MD5(str).toString();
          },
        },
        buffer: {
          from: function () {
            var B = getBuffer();
            return B.from.apply(B, arguments);
          },
          bufToString: function (buf, format) {
            var B = getBuffer();
            return B.from(buf, 'binary').toString(format);
          },
        },
        zlib: {
          inflate: function (buf) {
            return Promise.resolve().then(function () {
              try {
                return nativeInflate('auto', buf);
              } catch (e) {
                G.console.warn('zlib.inflate 解压失败: ' + e);
                return buf;
              }
            });
          },
          inflateSync: function (buf) {
            try {
              return nativeInflate('auto', buf);
            } catch (e) {
              G.console.warn('zlib.inflateSync 解压失败: ' + e);
              return buf;
            }
          },
          deflate: function (data) {
            return Promise.resolve().then(function () {
              try {
                return nativeDeflate('zlib', data);
              } catch (e) {
                G.console.warn('zlib.deflate 压缩失败: ' + e);
                return data;
              }
            });
          },
        },
      },
      currentScriptInfo: {
        name: scriptInfo.name,
        description: scriptInfo.description,
        version: scriptInfo.version,
        author: scriptInfo.author,
        homepage: scriptInfo.homepage,
        rawScript: script,
      },
      version: '2.0.0',
      env: 'desktop',
    };

    // 设置 globalThis.lx 与 Node 全局模拟
    G.lx = lxApi;
    G.process = lxProcess;
    G.require = lxRequire;
    if (!G.Buffer) G.Buffer = getBuffer();
    if (!G.CryptoJs) G.CryptoJs = getCryptoJs();
    if (!G.CryptoJS) G.CryptoJS = getCryptoJs();
    G.SCRIPT_MD5 = getCryptoJs().MD5(script).toString();

    // 初始化结果 promise：Rust 侧 await globalThis.__xyLxInitPromise
    G.__xyLxInitPromise = initPromise.then(function (info) {
      return JSON.stringify({ ok: true, initInfo: info });
    }, function (e) {
      throw JSON.stringify({ ok: false, error: (e && e.message) ? String(e.message) : String(e) });
    });

    try {
      var pluginFn = new Function(
        'lx', 'Buffer', 'CryptoJs', 'CryptoJS', 'window', 'self', 'global', 'process', 'require',
        '"use strict";\n' + script,
      );
      pluginFn(G.lx, G.Buffer, G.CryptoJs, G.CryptoJS, G, G, G, G.process, G.require);
      G.console.log('脚本模块加载完成(无同步异常)');
      return null;
    } catch (e) {
      G.console.error('脚本模块加载异常: ' + (e && e.message));
      if (!isInitedApi) {
        return JSON.stringify({ ok: false, error: (e && e.message) || 'module import error' });
      }
      return null;
    }
  };

  G.__xyLxRequest = function (requestDataJson) {
    var data;
    try {
      data = JSON.parse(requestDataJson || '{}') || {};
    } catch (e) {
      data = {};
    }
    if (!lxRequestHandler) {
      return Promise.reject(new Error('LX 插件未注册 request 处理器'));
    }
    return Promise.resolve().then(function () {
      return lxRequestHandler(data);
    }).then(function (result) {
      var preview = typeof result === 'string'
        ? result.substring(0, 100)
        : (result === null ? 'null' : String(JSON.stringify(result)).substring(0, 100));
      G.console.log('LX request(action=' + (data && data.action) + ') 返回: type=' + typeof result +
        ' len=' + (typeof result === 'string' ? result.length : 'n/a') + ' preview=' + preview);
      return result;
    }, function (e) {
      // 诊断：输出堆栈（含插件脚本行号），定位插件内部 "not a function" 等错误
      try {
        G.console.error('LX request(action=' + (data && data.action) + ') 堆栈: ' +
          ((e && e.stack) ? String(e.stack) : String((e && e.message) || e)));
      } catch (e2) { /* ignore */ }
      throw e;
    });
  };
})();
