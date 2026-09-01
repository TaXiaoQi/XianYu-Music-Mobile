import 'dart:convert';
import 'dart:typed_data';

import '../rust/api.dart';

/// 在线封面代理。
///
/// 各平台封面 CDN 普遍有防盗链，直连会 403 或超时；
/// 经 Rust 的 [proxyImage] 服务端拉取（自动按域名补 Referer）后返回 data URL。
///
/// 对应桌面端 `src/utils/coverProxy.ts` 的职责，行为保持一致：
/// 需要代理的域名统一走后端，其余原样直连。
class CoverProxy {
  CoverProxy._();

  /// 需要走后端代理的封面域名（与桌面端 PROXY_COVER_DOMAINS 对齐）。
  static const _proxyDomains = <String>[
    'hdslb.com',
    'bilivideo.com',
    'y.gtimg.cn',
    'qpic.cn',
    // 酷我封面 CDN，防盗链需 Referer / 证书异常，直连会 403；
    // 归一化目标 img3.kuwo.cn 必须代理取回，img4/kwimgN/imgN.kwcdn 为插件返回的原始域名兜底
    'sycdn.kuwo.cn',
    'img3.kuwo.cn',
    'img4.kuwo.cn',
    'kwimg',
    'kwcdn.kuwo.cn',
    // 网易云 CDN 对非白名单来源会拒绝，必须带 Referer 走后端
    'music.126.net',
    '163.com',
    // 咪咕封面为 http 明文且有防盗链
    'musicapp.migu.cn',
    'migu.cn',
  ];

  /// 图片字节缓存（原始 URL → 字节），LinkedHashMap 实现按插入序的 LRU。
  ///
  /// 封面单张几十 KB 到 1MB 不等，无上限缓存在长会话下会无限增长，
  /// 故限制条数与总字节数，超出按最久未使用淘汰。
  static const _maxEntries = 48;
  static const _maxTotalBytes = 24 * 1024 * 1024;
  static final Map<String, Uint8List> _cache = {};
  static int _totalBytes = 0;

  /// 已尝试且失败的 URL，避免反复请求。
  static final Set<String> _failed = {};

  /// 判断该 URL 是否需要经后端代理。
  static bool needsProxy(String url) {
    if (url.isEmpty) return false;
    if (url.startsWith('data:')) return false;
    // http 明文在部分 Android 版本会被拦，一律走代理更稳。
    if (url.startsWith('http://')) return true;
    return _proxyDomains.any(url.contains);
  }

  /// 读取缓存的图片字节；未缓存返回 null。命中会刷新 LRU 位置。
  static Uint8List? cached(String url) {
    final hit = _cache.remove(url);
    if (hit == null) return null;
    _cache[url] = hit;
    return hit;
  }

  /// 该 URL 是否已确认失败。
  static bool hasFailed(String url) => _failed.contains(url);

  /// 经后端代理获取图片字节。
  ///
  /// 成功后写入缓存；失败记录到 [_failed] 并返回 null。
  static Future<Uint8List?> fetch(String url) async {
    if (url.isEmpty) return null;
    final hit = cached(url);
    if (hit != null) return hit;
    if (_failed.contains(url)) return null;

    try {
      final dataUrl = await proxyImage(url: url);
      final bytes = _decodeDataUrl(dataUrl);
      if (bytes == null) {
        _failed.add(url);
        return null;
      }
      final old = _cache.remove(url);
      if (old != null) _totalBytes -= old.length;
      _cache[url] = bytes;
      _totalBytes += bytes.length;
      _evict();
      return bytes;
    } catch (_) {
      _failed.add(url);
      return null;
    }
  }

  /// 淘汰最久未使用的条目，直到满足条数与字节上限。
  static void _evict() {
    while (_cache.isNotEmpty &&
        (_cache.length > _maxEntries || _totalBytes > _maxTotalBytes)) {
      final oldest = _cache.keys.first;
      _totalBytes -= _cache.remove(oldest)!.length;
    }
  }

  /// 解析 `data:{mime};base64,{payload}` 形式的字符串。
  static Uint8List? _decodeDataUrl(String dataUrl) {
    final idx = dataUrl.indexOf(',');
    if (idx < 0 || !dataUrl.startsWith('data:')) return null;
    try {
      return base64Decode(dataUrl.substring(idx + 1));
    } catch (_) {
      return null;
    }
  }

  /// 清空缓存与失败记录。
  static void clear() {
    _cache.clear();
    _totalBytes = 0;
    _failed.clear();
  }
}
