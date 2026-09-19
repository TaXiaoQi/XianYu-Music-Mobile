import 'dart:async';
import 'dart:convert';

import '../core/application_logger.dart';
import '../player/media_url.dart';
import '../rust/api.dart' as frb;
import '../i18n/i18n.dart';
import 'plugin_models.dart';
import 'plugin_host_fallback.dart';
import 'plugin_store.dart';
import 'baka_plugin_manager.dart';

class PluginEngine {
  final String dataDir;
  final PluginStore store;

  Future<Map<String, String>> Function(String pluginId)? userVarsProvider;

  final Set<String> _ready = {};

  final Map<String, Future<Map<String, dynamic>?>> _ensureLock = {};

  final Map<String, Map<String, dynamic>> _metadata = {};

  final Map<String, String> _aliases = {};

  static const Duration _lxUrlCacheTtl = Duration(minutes: 10);
  final Map<String, ({String url, String type, Map<String, String>? headers, DateTime expiresAt})>
      _lxUrlCache = {};

  final Map<String, Future<Map<String, dynamic>?>> _lxUrlInflight = {};

  static const int _requestTimeout = 30000;
  static const int _lyricTimeout = 8000;
  static const int _maxPluginSize = 2 * 1024 * 1024;

  PluginEngine(this.dataDir, this.store);

  late final BakaPluginManager bakaManager = BakaPluginManager(this);

  String _resolveId(String pluginId) => _aliases[pluginId] ?? pluginId;

  bool isReady(String pluginId) => _ready.contains(_resolveId(pluginId));

  Map<String, dynamic>? metadataOf(String pluginId) =>
      _metadata[_resolveId(pluginId)];

  void linkAlias(String aliasId, String targetId) {
    if (aliasId.isEmpty || targetId.isEmpty || aliasId == targetId) return;
    if (!_ready.contains(targetId)) return;
    _aliases[aliasId] = targetId;
  }

  // ==================== 脚本格式检测 / 头信息解析 ====================

  bool isLxPluginScript(String script) {
    final trimmed = script.trim();

    final hasMusicFreeExport = RegExp(r'\bmodule\.exports\s*[.=]').hasMatch(trimmed) ||
        RegExp(r'\bexports\s*\.\s*default\s*=').hasMatch(trimmed);
    final hasMusicFreePlatform = RegExp(r"""\bplatform\s*[=:]\s*['"]""").hasMatch(trimmed);
    final hasMusicFreeSearch = RegExp(r"""\bsearch\s*[=:]\s*function|\.search\s*=\s*(async\s+)?\(""")
        .hasMatch(trimmed);

    if (hasMusicFreeExport || (hasMusicFreePlatform && hasMusicFreeSearch)) {
      return false;
    }

    if (RegExp(r'\blx\s*\.\s*(on|send)\s*\(').hasMatch(trimmed)) return true;
    if (RegExp(r'EVENT_NAMES\s*\.\s*request').hasMatch(trimmed)) return true;
    if (RegExp(r"""globalThis\s*\[\s*['"]lx['"]\s*]""").hasMatch(trimmed)) return true;
    if (RegExp(r'globalThis\s*\.\s*lx\b').hasMatch(trimmed)) return true;
    if (RegExp(r'globalThis').hasMatch(trimmed) && RegExp(r'\bEVENT_NAMES\b').hasMatch(trimmed)) {
      return true;
    }
    if (RegExp(r'SERVER_SCRIPT_CONFIG').hasMatch(trimmed)) return true;
    if (RegExp(r'\\u0053\\u0043\\u0052\\u0049\\u0050\\u0054\\u005f\\u004d\\u0044\\u0035')
        .hasMatch(trimmed)) {
      return true;
    }
    if (RegExp(r'\\u006c\\u0078').hasMatch(trimmed) &&
        RegExp(r'\\u0067\\u006c\\u006f\\u0062\\u0061\\u006c\\u0054\\u0068\\u0069\\u0073')
            .hasMatch(trimmed)) {
      return true;
    }
    return false;
  }

  Map<String, String> parseLxScriptInfo(String script) {
    final match = RegExp(r'^/\*[\S|\s]+?\*/').firstMatch(script);
    final result = <String, String>{};
    if (match == null) return result;
    final header = match.group(0)!;
    final rxp = RegExp(r'^\s?\*\s?@(\w+)\s(.+)$');
    for (final line in header.split(RegExp(r'\r?\n'))) {
      final m = rxp.firstMatch(line);
      if (m == null) continue;
      result[m.group(1)!] = m.group(2)!.trim();
    }
    return result;
  }

  // ==================== 加载 ====================

  Future<Map<String, dynamic>?> loadLx(
    String pluginId,
    String script, {
    Map<String, String>? scriptInfo,
  }) async {
    final bytes = utf8.encode(script);
    if (bytes.length > _maxPluginSize) {
      throw PluginEngineException(tr('插件大小超过 2MB'));
    }
    if (script.trim().isEmpty) {
      throw PluginEngineException(tr('插件内容为空'));
    }

    final result = EngineLoadResult.fromJsonString(await frb.pluginEngineLoadLx(
      dataDir: dataDir,
      pluginId: pluginId,
      script: script,
      scriptInfoJson: jsonEncode(scriptInfo ?? {}),
    ));
    _emitLogs(result.logs);
    if (!result.ok) {
      _ready.remove(pluginId);
      throw PluginEngineException(result.error ?? tr('LX 插件初始化失败'));
    }
    _ready.add(pluginId);
    _metadata[pluginId] = result.metadata ?? {};
    return result.metadata;
  }

  Future<Map<String, dynamic>?> loadMusicFree(
    String pluginId,
    String script, {
    Map<String, String>? userVars,
  }) async {
    final bytes = utf8.encode(script);
    if (bytes.length > _maxPluginSize) {
      throw PluginEngineException(tr('插件大小超过 2MB'));
    }
    if (script.trim().isEmpty) {
      throw PluginEngineException(tr('插件内容为空'));
    }

    final result = EngineLoadResult.fromJsonString(
        await frb.pluginEngineLoadMusicfree(
      dataDir: dataDir,
      pluginId: pluginId,
      script: script,
      userVarsJson: jsonEncode(userVars ?? {}),
    ));
    _emitLogs(result.logs);
    if (!result.ok) {
      _ready.remove(pluginId);
      throw PluginEngineException(result.error ?? tr('插件加载失败'));
    }
    _ready.add(pluginId);
    _metadata[pluginId] = result.metadata ?? {};
    return result.metadata;
  }

  Future<dynamic> call(
    String pluginId,
    String method,
    List<dynamic> args, {
    int timeoutMs = _requestTimeout,
    Map<String, String>? userVars,
  }) async {
    final sandboxId = _resolveId(pluginId);
    if (!_ready.contains(sandboxId)) {
      throw PluginEngineException(
          tr('插件实例不存在: {pluginId}', {'pluginId': pluginId}));
    }
    if (method == 'request' && isAuthBanned(sandboxId)) {
      throw PluginEngineException(
          tr('音源鉴权失效已临时熔断（5 分钟后自动重试）: {pluginId}',
              {'pluginId': sandboxId}));
    }
    final result = EngineCallResult.fromJsonString(await frb.pluginEngineCall(
      dataDir: dataDir,
      pluginId: sandboxId,
      method: method,
      argsJson: jsonEncode(_toCloneableArgs(args)),
      userVarsJson: userVars == null ? null : jsonEncode(userVars),
      timeoutMs: BigInt.from(timeoutMs),
    ));
    _emitLogs(result.logs);
    if (!result.ok) {
      final err = result.error ?? tr('方法调用失败');
      if (method == 'request' && _isAuthError(err)) {
        _markAuthFailure(sandboxId, err);
      }
      throw PluginEngineException(err);
    }
    if (method == 'request') _authFailStreak[sandboxId] = 0;
    return result.data;
  }

  Future<Map<String, dynamic>?> ensureLoaded(PluginSource source) async {
    if (!source.enabled) return null;
    final id = _resolveId(source.id);
    if (_ready.contains(id)) return _metadata[id];

    final existing = _ensureLock[source.id];
    if (existing != null) return existing;

    final future = _doEnsureLoaded(source);
    _ensureLock[source.id] = future;
    try {
      return await future;
    } finally {
      _ensureLock.remove(source.id);
    }
  }

  Future<Map<String, dynamic>?> _doEnsureLoaded(PluginSource source) async {
    try {
      final script = await store.readScript(source.id);
      if (script == null || script.isEmpty) {
        AppLog.warn('plugin', '${source.name}(${source.id}) 脚本为空或不存在');
        return null;
      }
      final isLx = source.format == PluginFormat.lx;
      final info = isLx
          ? await loadLx(source.id, script, scriptInfo: parseLxScriptInfo(script))
          : await loadMusicFree(
              source.id,
              script,
              userVars: await userVarsProvider?.call(source.id),
            );
      if (info != null) {
        AppLog.info('plugin',
            '${source.name}(${source.id}) 加载成功 (${isLx ? 'lx' : 'musicfree'})');
      }
      if (info != null && info['id'] != null && info['id'] != source.id) {
        final newId = info['id'].toString();
        if (_ready.contains(newId)) {
          linkAlias(source.id, newId);
        }
      }
      return info;
    } catch (e) {
      AppLog.error('plugin', '${source.name}(${source.id}) 加载失败: $e');
      return null;
    }
  }

  // ==================== 可播放能力 ====================

  Future<bool> canPlayMusic(PluginSource source) async {
    if (!source.enabled) return false;
    try {
      final meta = await ensureLoaded(source);
      if (meta == null) return false;
      if (source.format == PluginFormat.musicfree) {
        final methods = meta['_availableMethods'];
        return methods is List && methods.contains('getMediaSource');
      }
      final sources = meta['sources'];
      if (sources is! Map) return false;
      for (final v in sources.values) {
        if (v is! Map) continue;
        if (v['type'] is String && v['type'] != 'music') continue;
        final actions = v['actions'];
        if (actions is List && actions.contains('musicUrl')) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ==================== 鉴权失效熔断 ====================
  static final Map<String, DateTime> _authBannedUntil = {};
  static final Map<String, int> _authFailStreak = {};
  static const Duration _authBanTtl = Duration(minutes: 5);
  static const int _authBanThreshold = 2;

  static bool _isAuthError(String msg) =>
      RegExp(r'API密钥|API\s*key|api[_\s-]?secret|401', caseSensitive: false)
          .hasMatch(msg);

  static bool isAuthBanned(String pluginId) {
    final until = _authBannedUntil[pluginId];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _authBannedUntil.remove(pluginId);
      _authFailStreak[pluginId] = 0;
      return false;
    }
    return true;
  }

  static void _markAuthFailure(String pluginId, String msg) {
    final streak = (_authFailStreak[pluginId] ?? 0) + 1;
    _authFailStreak[pluginId] = streak;
    if (streak >= _authBanThreshold) {
      _authBannedUntil[pluginId] = DateTime.now().add(_authBanTtl);
      AppLog.warn('plugin', '[$pluginId] 鉴权连续失败 $streak 次，熔断 5 分钟: $msg');
    }
  }

  // ==================== LX 请求协议 ====================

  static String lxQualityKeyFor(String q) => q == 'mgg' ? '128k' : q;

  Future<dynamic> lxRequest(
    PluginSource source,
    String action,
    Map<String, dynamic> data, {
    int timeoutMs = _requestTimeout,
  }) async {
    if (!source.enabled) return null;
    final info = await ensureLoaded(source);
    if (info == null) {
      AppLog.warn('plugin',
          '[lxRequest] ${source.name}/$action 跳过：插件未加载或未启用');
      return null;
    }

    try {
      final response = await call(
        source.id,
        'request',
        [
          {
            'source': data['source'],
            'action': action,
            'info': {
              'type': data['type'],
              'quality': data['type'],
              'musicInfo': data['musicInfo'],
            },
          }
        ],
        timeoutMs: timeoutMs,
      );
      AppLog.debug('plugin',
          '[lxRequest] ${source.name}/$action source=${data['source']} type=${data['type']} 完成');
      return response;
    } catch (e) {
      final msg = e is PluginEngineException ? e.message : e.toString();
      AppLog.warn('plugin', '[lxRequest] ${source.name}/$action 失败: $msg');
      if (action == 'lyric' &&
          RegExp(r'action\s+not\s+support|not\s+support', caseSensitive: false)
              .hasMatch(msg)) {
        return null;
      }
      if (action == 'musicUrl' && isSongLevelError(msg)) {
        throw LxSongLevelError(msg);
      }
      return null;
    }
  }

  // ==================== MusicFree 播放直链 ====================

  static const List<String> _qualityLadder = [
    'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
    'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
  ];

  static const Map<String, String> _qualityAliases = {
    '96k': 'mgg', 'ogg96': 'mgg', 'mgg': 'mgg',
    '128': '128k', '128k': '128k',
    '192': '192k', '192k': '192k', 'ogg192': '192k',
    '320': '320k', '320k': '320k', 'ogg320': '320k', 'exhigh': '320k',
    'flac': 'flac', 'sq': 'flac', 'super': 'flac', 'lossless': 'flac',
    'flac24': 'flac24bit', '24bit': 'flac24bit', '24bits': 'flac24bit',
    '24_bit': 'flac24bit', 'flac24bit': 'flac24bit',
    'hires': 'hires', 'hi-res': 'hires', 'hi_res': 'hires', 'hr': 'hires',
    'vinyl': 'vinyl', 'dolby': 'dolby', 'atmos': 'atmos',
    'galaxy': 'atmos', 'atmosplus': 'atmos_plus', 'atmos_plus': 'atmos_plus',
    'atmos+': 'atmos_plus', 'galaxy51': 'atmos_plus', 'master': 'master',
  };

  static String? _normalizeQualityKey(dynamic raw) {
    if (raw is! String) return null;
    final normalized =
        raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '').replaceAll('-', '_');
    if (normalized.isEmpty) return null;
    return _qualityLadder.contains(normalized) ? normalized : _qualityAliases[normalized];
  }

  static String? normalizeQualityKey(dynamic raw) => _normalizeQualityKey(raw);

  static String _qualityKeyToPluginString(String q) => q == 'mgg' ? '96k' : q;

  static const List<String> qualityLadder = _qualityLadder;

  static String qualityKeyToPluginString(String q) =>
      _qualityKeyToPluginString(q);

  static bool _isLossless(String q) =>
      _qualityLadder.indexOf(q) >= _qualityLadder.indexOf('flac');

  static String _qualityKeyToMfQuality(String q) {
    final rank = _qualityLadder.indexOf(q);
    if (rank < 0) return 'standard';
    if (rank >= 5) return 'super';
    if (rank >= 4) return 'high';
    if (rank >= 3) return 'standard';
    return 'low';
  }

  static String qualityKeyToMfQuality(String q) => _qualityKeyToMfQuality(q);

  static const List<String> _mfQualityOrder = ['low', 'standard', 'high', 'super'];

  static List<String> _musicFreeQualityCandidates(
    String preferred,
    String fallback,
    Set<String> declaredKeys,
  ) {
    final baseMf = _qualityKeyToMfQuality(preferred);
    if (fallback == 'pause') return [baseMf];
    final baseIdx = _mfQualityOrder.indexOf(baseMf);
    final order = <String>[baseMf];
    for (var i = baseIdx + 1; i < _mfQualityOrder.length; i++) {
      order.add(_mfQualityOrder[i]);
    }
    for (var i = baseIdx - 1; i >= 0; i--) {
      order.add(_mfQualityOrder[i]);
    }
    return order;
  }

  static List<String> _musicFreeNativeCandidates(
    String preferred,
    String fallback,
    Set<String> declaredKeys,
  ) {
    final ladderDesc = _qualityLadder.reversed.toList();
    final candidates = <String>[];
    final seen = <String>{};
    void add(String qk) {
      final pluginQ = _qualityKeyToPluginString(qk);
      if (seen.add(pluginQ)) candidates.add(pluginQ);
      if (_isLossless(qk) && seen.add('super')) candidates.add('super');
    }

    if (fallback == 'pause') {
      add(preferred);
    } else if (fallback == 'higher') {
      final start = _qualityLadder.indexOf(preferred);
      if (start >= 0) {
        for (var i = start; i < _qualityLadder.length; i++) {
          add(_qualityLadder[i]);
        }
      } else {
        add(preferred);
      }
    } else {
      final start = ladderDesc.indexOf(preferred);
      if (start >= 0) {
        for (var i = start; i < ladderDesc.length; i++) {
          add(ladderDesc[i]);
        }
      } else {
        add(preferred);
      }
    }

    if (declaredKeys.isNotEmpty) {
      final filtered = candidates.where((c) {
        final norm = _normalizeQualityKey(c);
        return norm != null && declaredKeys.contains(norm);
      }).toList();
      if (filtered.isNotEmpty) return filtered;
    }
    return candidates.take(1).toList();
  }

  bool isBakaPlugin(String pluginId) => bakaManager.isBakaPlugin(pluginId);

  Future<ResolvedMediaUrl?> getMusicFreeUrl(
    PluginSource source,
    Map<String, dynamic> songInfo, {
    String preferred = '320k',
    String fallback = 'lower',
  }) async {
    await ensureLoaded(source);
    final meta = metadataOf(source.id);
    final declaredRaw = meta?['supportedQualities'];
    final declaredKeys = <String>{};
    if (declaredRaw is List) {
      for (final dq in declaredRaw) {
        final norm = _normalizeQualityKey(dq);
        if (norm != null) declaredKeys.add(norm);
      }
    }

    final raw = songInfo['rawData'];
    final musicItem = raw is Map<String, dynamic>
        ? Map<String, dynamic>.from(raw)
        : Map<String, dynamic>.from(songInfo);
    if (musicItem['platform'] == null) {
      musicItem['platform'] = source.name;
    }
    if (!musicItem.containsKey('title') && songInfo.containsKey('name')) {
      musicItem['title'] = songInfo['name'];
    }
    if (!musicItem.containsKey('artist') && songInfo.containsKey('singer')) {
      musicItem['artist'] = songInfo['singer'];
    }
    if (!musicItem.containsKey('id') &&
        (((musicItem['id'] as dynamic)?.toString() ?? '').isEmpty) &&
        songInfo.containsKey('songmid')) {
      musicItem['id'] = songInfo['songmid'];
    }
    if (!musicItem.containsKey('songmid') && songInfo.containsKey('songmid')) {
      musicItem['songmid'] = songInfo['songmid'];
    }

    if (bakaManager.isBakaPlugin(source.id)) {
      return bakaManager.getMediaSource(
        source,
        musicItem,
        preferred: preferred,
        fallback: fallback,
        declaredKeys: declaredKeys,
      );
    }

    final tryQs = _musicFreeQualityCandidates(preferred, fallback, declaredKeys);
    var unsupportedQuality = false;
    for (final q in tryQs) {
      try {
        final response = await _callGetMediaSourceWithRetry(source.id, musicItem, q);
        final url = extractMfPlayableUrl(response, requestedKey: q);
        if (url != null) return url;
      } catch (e) {
        final msg = e is PluginEngineException ? e.message : e.toString();
        if (isUnsupportedQualityError(msg)) unsupportedQuality = true;
      }
    }

    if (unsupportedQuality) {
      final tried = tryQs.toSet();
      for (final q in _musicFreeNativeCandidates(preferred, fallback, declaredKeys)) {
        if (tried.contains(q)) continue;
        try {
          final response =
              await _callGetMediaSourceWithRetry(source.id, musicItem, q);
          final url = extractMfPlayableUrl(response, requestedKey: q);
          if (url != null) return url;
        } catch (_) {
        }
      }
    }
    return null;
  }

  Future<dynamic> _callGetMediaSourceWithRetry(
      String pluginId, Map<String, dynamic> musicItem, String q) async {
    try {
      return await call(pluginId, 'getMediaSource', [musicItem, q]);
    } catch (e) {
      final msg = e is PluginEngineException ? e.message : e.toString();
      if (isUnsupportedQualityError(msg)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return call(pluginId, 'getMediaSource', [musicItem, q]);
    }
  }

  static ResolvedMediaUrl? extractMfPlayableUrl(
    dynamic response, {
    String? requestedKey,
  }) {
    if (response == null) return null;
    bool notQqTrial(String url) => !isQqTrialMediaUrl(url);
    final requestedNorm =
        requestedKey == null ? null : _normalizeQualityKey(requestedKey);
    if (response is String) {
      return response.isNotEmpty &&
              response.length <= 2048 &&
              RegExp(r'^https?:').hasMatch(response) &&
              notQqTrial(response)
          ? ResolvedMediaUrl(url: response, quality: requestedNorm)
          : null;
    }
    if (response is Map) {
      final obj = response.cast<String, dynamic>();
      final url = (obj['url'] ?? obj['link'] ?? obj['playUrl']) as String?;
      if (url != null &&
          url.isNotEmpty &&
          url.length <= 2048 &&
          RegExp(r'^https?:').hasMatch(url) &&
          notQqTrial(url)) {
        String? reported;
        final qField =
            obj['quality'] ?? obj['type'] ?? obj['actualQuality'];
        if (qField is String && qField.isNotEmpty) {
          reported = _normalizeQualityKey(qField);
        }
        final h = obj['headers'];
        final ekey = (obj['ekey'] ?? obj['cek']) as String?;
        return ResolvedMediaUrl(
          url: url,
          headers: h is Map ? h.cast<String, String>() : null,
          quality: reported ?? requestedNorm,
          ekey: (ekey != null && ekey.isNotEmpty) ? ekey : null,
        );
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> getMusicUrl(
    PluginSource source,
    String sourceKey,
    Map<String, dynamic> songInfo,
    String quality,
  ) async {
    final response = await lxRequest(source, 'musicUrl', {
      'source': sourceKey,
      'type': lxQualityKeyFor(quality),
      'musicInfo': songInfo,
    });
    if (response == null) return null;

    String? url;
    String type = quality;
    Map<String, String>? headers;
    if (response is String) {
      url = response;
    } else if (response is Map) {
      final obj = response.cast<String, dynamic>();
      url = (obj['url'] ?? obj['link'] ?? obj['playUrl']) as String?;
      if (obj['type'] != null) type = obj['type'].toString();
      final h = obj['headers'];
      if (h is Map) headers = h.cast<String, String>();
    }
    if (url == null ||
        url.isEmpty ||
        url.length > 2048 ||
        !RegExp(r'^https?:').hasMatch(url)) {
      AppLog.error('plugin',
          '[musicUrl] ${source.name}/$sourceKey $quality 返回非法直链');
      throw PluginEngineException('Invalid musicUrl response');
    }
    AppLog.info('plugin',
        '[musicUrl] ${source.name}/$sourceKey $quality -> ${type == quality ? type : '$type(declared $quality)'}');
    return {
      'type': type,
      'url': url,
      'headers': ?headers,
    };
  }

  // ==================== LX 直链解析编排 ====================

  String _lxCacheSongId(Map<String, dynamic> songInfo, String quality) {
    final songmid = songInfo['songmid']?.toString() ?? '';
    switch (songInfo['source']?.toString() ?? '') {
      case 'kg':
        final types = songInfo['_types'];
        if (types is Map) {
          final entry = types[lxQualityKeyFor(quality)];
          final hash = entry is Map ? entry['hash'] : null;
          if (hash is String && hash.isNotEmpty) return hash;
        }
        final hash = songInfo['hash'];
        return hash is String && hash.isNotEmpty ? hash : songmid;
      case 'mg':
        final cid = songInfo['copyrightId'];
        return cid is String && cid.isNotEmpty ? cid : songmid;
      default:
        return songmid;
    }
  }

  Future<Map<String, dynamic>?> resolveLxUrl(
    Map<String, dynamic> songInfo,
    String quality,
  ) async {
    final source = songInfo['source']?.toString() ?? '';
    final songId = _lxCacheSongId(songInfo, quality);
    if (source.isEmpty || songId.isEmpty) return null;
    final cacheKey = '$source/$songId/$quality';

    final cached = _lxUrlCache[cacheKey];
    if (cached != null) {
      if (cached.expiresAt.isAfter(DateTime.now())) {
        return {'type': cached.type, 'url': cached.url, 'headers': cached.headers};
      }
      _lxUrlCache.remove(cacheKey);
    }

    final inflight = _lxUrlInflight[cacheKey];
    if (inflight != null) return inflight;

    final task = _resolveLxUrlInner(songInfo, source, quality, cacheKey);
    _lxUrlInflight[cacheKey] = task;
    try {
      return await task;
    } finally {
      if (identical(_lxUrlInflight[cacheKey], task)) {
        _lxUrlInflight.remove(cacheKey);
      }
    }
  }

  Future<Map<String, dynamic>?> _resolveLxUrlInner(
    Map<String, dynamic> songInfo,
    String source,
    String quality,
    String cacheKey,
  ) async {
    final sources = await store.loadSources();
    final lxPlugins = sources
        .where((p) => p.enabled && p.format == PluginFormat.lx)
        .toList();
    if (lxPlugins.isEmpty) return null;
    final plugin = lxPlugins.firstWhere(
      (p) => p.sources.contains(source),
      orElse: () => lxPlugins.first,
    );
    final result = await getMusicUrl(plugin, source, songInfo, quality);
    final url = result?['url'] as String?;
    if (result == null || url == null || url.isEmpty) return null;
    if (_lxUrlCache.length >= 500) {
      final now = DateTime.now();
      _lxUrlCache.removeWhere((_, e) => e.expiresAt.isBefore(now));
      while (_lxUrlCache.length >= 500) {
        _lxUrlCache.remove(_lxUrlCache.keys.first);
      }
    }
    _lxUrlCache[cacheKey] = (
      url: url,
      type: (result['type'] as String?) ?? quality,
      headers: result['headers'] as Map<String, String>?,
      expiresAt: DateTime.now().add(_lxUrlCacheTtl),
    );
    return result;
  }

  Future<Map<String, dynamic>?> getLyric(
    PluginSource source,
    String sourceKey,
    Map<String, dynamic> songInfo,
  ) async {
    if (source.format == PluginFormat.musicfree) {
      return getMusicFreeLyric(source, songInfo);
    }
    final response = await lxRequest(
      source,
      'lyric',
      {'source': sourceKey, 'musicInfo': songInfo},
      timeoutMs: _lyricTimeout,
    );
    return _normalizeLyricResponse(response);
  }

  Future<Map<String, dynamic>?> getMusicFreeLyric(
    PluginSource source,
    Map<String, dynamic> songInfo,
  ) async {
    await ensureLoaded(source);
    if (songInfo.isEmpty) return null;
    final raw = songInfo['rawData'];
    final musicItem = raw is Map<String, dynamic>
        ? Map<String, dynamic>.from(raw)
        : Map<String, dynamic>.from(songInfo);
    if (musicItem['platform'] == null) {
      musicItem['platform'] = source.name;
    }
    if (!musicItem.containsKey('title') && songInfo.containsKey('name')) {
      musicItem['title'] = songInfo['name'];
    }
    if (!musicItem.containsKey('artist') && songInfo.containsKey('singer')) {
      musicItem['artist'] = songInfo['singer'];
    }
    if (!musicItem.containsKey('id') &&
        ((musicItem['id'] as dynamic)?.toString() ?? '').isEmpty &&
        songInfo.containsKey('songmid')) {
      musicItem['id'] = songInfo['songmid'];
    }
    try {
      final response = await call(
        source.id,
        'getLyric',
        [musicItem],
        timeoutMs: _lyricTimeout,
      );
      return _normalizeLyricResponse(response);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _normalizeLyricResponse(dynamic response) {
    if (response == null) return null;
    if (response is String) {
      final text = response.trim();
      return text.isEmpty
          ? null
          : {
              'lyric': text,
              'tlyric': null,
              'rlyric': null,
              'lxlyric': null,
              'yrc': null,
              'qrc': null,
              'eslrc': null,
            };
    }
    if (response is! Map) return null;
    final obj = response.cast<String, dynamic>();
    final lyric = _pickString([obj['lyric'], obj['rawLrc'], obj['lrc']]);
    final tlyric = _pickString([obj['tlyric'], obj['translation'], obj['translateLyric']]);
    final rlyric = _pickString([obj['rlyric'], obj['romanization']]);
    final lxlyric = _pickString([obj['lxlyric']]);
    final yrc = _pickString([obj['yrc']]);
    final qrc = _pickString([obj['qrc']]);
    final eslrc = _pickString([obj['eslrc'], obj['enhancedLrc'], obj['enh_lrc']]);
    if (lyric.isEmpty &&
        lxlyric.isEmpty &&
        yrc.isEmpty &&
        qrc.isEmpty &&
        eslrc.isEmpty) {
      return null;
    }
    return {
      'lyric': lyric,
      'tlyric': tlyric.isEmpty ? null : tlyric,
      'rlyric': rlyric.isEmpty ? null : rlyric,
      'lxlyric': lxlyric.isEmpty ? null : lxlyric,
      'yrc': yrc.isEmpty ? null : yrc,
      'qrc': qrc.isEmpty ? null : qrc,
      'eslrc': eslrc.isEmpty ? null : eslrc,
    };
  }

  Future<String?> getPic(
    PluginSource source,
    String sourceKey,
    Map<String, dynamic> songInfo,
  ) async {
    final response = await lxRequest(source, 'pic', {
      'source': sourceKey,
      'musicInfo': songInfo,
    });
    if (response is! String ||
        response.isEmpty ||
        response.length > 2048 ||
        !RegExp(r'^https?:').hasMatch(response)) {
      return null;
    }
    return response;
  }

  // ==================== 搜索 ====================

  Future<List<PluginSearchResult>> searchInPlugin(
    PluginSource source,
    String sourceKey,
    String keyword, {
    int limit = 30,
  }) async {
    return lxHostSearchFallback(source, sourceKey, keyword, limit: limit);
  }

  // ==================== 生命周期 ====================

  Future<void> destroy(String pluginId) async {
    final id = _resolveId(pluginId);
    _ready.remove(id);
    _metadata.remove(id);
    _aliases.removeWhere((k, v) => k == pluginId || v == id);
    try {
      await frb.pluginEngineDestroy(dataDir: dataDir, pluginId: id);
    } catch (_) {
    }
  }

  Future<void> destroyAll() async {
    _ready.clear();
    _metadata.clear();
    _aliases.clear();
    try {
      await frb.pluginEngineDestroyAll(dataDir: dataDir);
    } catch (_) {
    }
  }

  // ==================== 工具 ====================

  void _emitLogs(List<EngineLog> logs) {
    for (final entry in logs) {
      switch (entry.level) {
        case 'error':
          AppLog.error('plugin', '[plugin:js] ${entry.message}');
        case 'warn':
          AppLog.warn('plugin', '[plugin:js] ${entry.message}');
        default:
          AppLog.debug('plugin', '[plugin:js] ${entry.message}');
      }
    }
  }

  List<dynamic> _toCloneableArgs(List<dynamic> args) {
    return args.map((arg) {
      if (arg == null) return arg;
      if (arg is String || arg is num || arg is bool) return arg;
      try {
        return jsonDecode(jsonEncode(arg));
      } catch (_) {
        return null;
      }
    }).toList();
  }

  String _pickString(List<dynamic> values) {
    for (final v in values) {
      if (v is String && v.isNotEmpty) return v;
    }
    return '';
  }
}

class PluginEngineException implements Exception {
  final String message;
  PluginEngineException(this.message);

  @override
  String toString() => message;
}

class LxSongLevelError extends PluginEngineException {
  LxSongLevelError(super.message);
}

bool isSongLevelError(String message) {
  const patterns = [
    r'歌曲不存在',
    r'歌曲已下架',
    r'已?下架',
    r'版权.{0,4}(限制|保护|原因)',
    r'需要?登录',
    r'地区限制',
    r'需要?\s*(VIP|会员|付费)',
    r'VIP歌曲',
    r'会员歌曲',
    r'付费歌曲',
    r'无版权',
    r'暂无版权',
  ];
  for (final pattern in patterns) {
    if (RegExp(pattern, caseSensitive: false).hasMatch(message)) return true;
  }
  return false;
}

bool isUnsupportedQualityError(String message) {
  return RegExp(
    r'不支持.*音质|音质.*不支持|quality.*not\s+support|not\s+support.*quality',
    caseSensitive: false,
  ).hasMatch(message);
}
