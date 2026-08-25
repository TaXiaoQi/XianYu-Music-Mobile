import 'dart:async';
import 'dart:convert';

import '../rust/api.dart' as frb;
import 'plugin_models.dart';
import 'plugin_store.dart';

/// 插件引擎编排层：负责插件加载/调用/生命周期，LX 请求封装。
///
/// 沙箱执行全部在 Rust 侧（rquickjs/QuickJS），本层仅做：
/// - 通过 FRB 把加载/调用路由到后端引擎
/// - 解析 LX 脚本头信息 / 格式检测
/// - LX request 协议封装（musicUrl / lyric / pic）
/// - 插件实例懒加载与并发初始化锁
class PluginEngine {
  final String dataDir;
  final PluginStore store;

  /// 用户变量值提供器：懒加载 MusicFree 插件时按插件 ID 取已保存的值。
  Future<Map<String, String>> Function(String pluginId)? userVarsProvider;

  /// 已就绪的插件 ID 集合（沙箱实例存在）。
  final Set<String> _ready = {};

  /// 并发初始化锁：同一插件的并发加载共享同一个 Future。
  final Map<String, Future<Map<String, dynamic>?>> _ensureLock = {};

  /// 已加载插件的元数据缓存。
  final Map<String, Map<String, dynamic>> _metadata = {};

  /// 插件 ID 别名（旧存储 ID → 实际 hash ID）。
  final Map<String, String> _aliases = {};

  static const int _requestTimeout = 30000;
  static const int _lyricTimeout = 8000;
  static const int _maxPluginSize = 2 * 1024 * 1024;

  PluginEngine(this.dataDir, this.store);

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

  /// 检测脚本是否为 LX 格式（与桌面端 isLxPluginScript 对齐）。
  bool isLxPluginScript(String script) {
    final trimmed = script.trim();

    // MusicFree 格式特征（优先级最高）
    final hasMusicFreeExport = RegExp(r'\bmodule\.exports\s*[.=]').hasMatch(trimmed) ||
        RegExp(r'\bexports\s*\.\s*default\s*=').hasMatch(trimmed);
    final hasMusicFreePlatform = RegExp(r"""\bplatform\s*[=:]\s*['"]""").hasMatch(trimmed);
    final hasMusicFreeSearch = RegExp(r"""\bsearch\s*[=:]\s*function|\.search\s*=\s*(async\s+)?\(""")
        .hasMatch(trimmed);

    if (hasMusicFreeExport || (hasMusicFreePlatform && hasMusicFreeSearch)) {
      return false;
    }

    // LX 格式特征
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

  /// 解析 LX 脚本头注释（@name/@version/@author/@description/@homepage）。
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

  /// 加载 LX 插件，返回 initInfo（sources 等）；失败返回 null。
  Future<Map<String, dynamic>?> loadLx(
    String pluginId,
    String script, {
    Map<String, String>? scriptInfo,
  }) async {
    final bytes = utf8.encode(script);
    if (bytes.length > _maxPluginSize) {
      throw PluginEngineException('插件大小超过 2MB');
    }
    if (script.trim().isEmpty) {
      throw PluginEngineException('插件内容为空');
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
      throw PluginEngineException(result.error ?? 'LX 插件初始化失败');
    }
    _ready.add(pluginId);
    _metadata[pluginId] = result.metadata ?? {};
    return result.metadata;
  }

  /// 加载 MusicFree 插件，返回元数据；失败返回 null。
  Future<Map<String, dynamic>?> loadMusicFree(
    String pluginId,
    String script, {
    Map<String, String>? userVars,
  }) async {
    final bytes = utf8.encode(script);
    if (bytes.length > _maxPluginSize) {
      throw PluginEngineException('插件大小超过 2MB');
    }
    if (script.trim().isEmpty) {
      throw PluginEngineException('插件内容为空');
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
      throw PluginEngineException(result.error ?? '插件加载失败');
    }
    _ready.add(pluginId);
    _metadata[pluginId] = result.metadata ?? {};
    return result.metadata;
  }

  /// 调用插件方法（MusicFree 用 method 名；LX 固定 method='request'）。
  Future<dynamic> call(
    String pluginId,
    String method,
    List<dynamic> args, {
    int timeoutMs = _requestTimeout,
    Map<String, String>? userVars,
  }) async {
    final sandboxId = _resolveId(pluginId);
    if (!_ready.contains(sandboxId)) {
      throw PluginEngineException('插件实例不存在: $pluginId');
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
      throw PluginEngineException(result.error ?? '方法调用失败');
    }
    return result.data;
  }

  /// 确保插件实例已加载（懒加载：从 store 读取脚本并加载）。
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
      if (script == null || script.isEmpty) return null;
      final isLx = source.format == PluginFormat.lx;
      final info = isLx
          ? await loadLx(source.id, script, scriptInfo: parseLxScriptInfo(script))
          : await loadMusicFree(
              source.id,
              script,
              userVars: await userVarsProvider?.call(source.id),
            );
      if (info != null && info['id'] != null && info['id'] != source.id) {
        // 重新加载得到的 hash 与存储 ID 不一致时注册别名
        final newId = info['id'].toString();
        if (_ready.contains(newId)) {
          linkAlias(source.id, newId);
        }
      }
      return info;
    } catch (_) {
      return null;
    }
  }

  // ==================== LX 请求协议 ====================

  /// 向 LX 插件发送请求（source/action/info 协议）。
  Future<dynamic> lxRequest(
    PluginSource source,
    String action,
    Map<String, dynamic> data, {
    int timeoutMs = _requestTimeout,
  }) async {
    if (!source.enabled) return null;
    final info = await ensureLoaded(source);
    if (info == null) return null;

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
      return response;
    } catch (e) {
      final msg = e is PluginEngineException ? e.message : e.toString();
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

  /// 音质阶梯（低 → 高，对应 12 档 rank）。第 5 档（flac）起为无损。
  static const List<String> _qualityLadder = [
    'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
    'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
  ];

  /// 常见插件音质别名 → 统一 12 档键（对齐桌面 normalizeQualityKey）。
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

  /// 内部键 → Baka 插件原生音质串（mgg 在插件侧为 96k）。
  static String _qualityKeyToPluginString(String q) => q == 'mgg' ? '96k' : q;

  static bool _isLossless(String q) =>
      _qualityLadder.indexOf(q) >= _qualityLadder.indexOf('flac');

  /// 内部键 → 旧式 MF 三档音质（对齐桌面 qualityKeyToMfQuality）。
  static String _qualityKeyToMfQuality(String q) {
    final rank = _qualityLadder.indexOf(q);
    if (rank < 0) return 'standard';
    if (rank >= 4) return 'lossless'; // 320k 及以上 → lossless 档
    if (rank >= 3) return 'high'; // 320k → high
    return 'standard';
  }

  /// 构建 MusicFree 音质候选（对齐桌面 buildNativePluginQualityPairs + 三档映射）。
  ///
  /// [declaredKeys] 为插件 supportedQualities 归一化后的原生键集合（可能为空）。
  /// 原生键插件按 12 档降级（lower/higher/pause）依次尝试；旧三档插件走 standard/high/lossless。
  static List<String> _musicFreeQualityCandidates(
    String preferred,
    String fallback,
    Set<String> declaredKeys,
  ) {
    final ladderDesc = _qualityLadder.reversed.toList();
    final base = ladderDesc;

    if (declaredKeys.isNotEmpty && _qualityLadder.contains(preferred)) {
      // 原生键插件：按降级方向生成候选（含无损档补充 'super'），仅保留声明过的键。
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
        for (var i = start; i < _qualityLadder.length; i++) {
          add(_qualityLadder[i]);
        }
      } else {
        final start = base.indexOf(preferred);
        final end = start == -1 ? base.length : start + 1;
        for (var i = 0; i < end; i++) {
          add(base[i]);
        }
      }
      final filtered = candidates.where(declaredKeys.contains).toList();
      if (filtered.isNotEmpty) return filtered;
      // 声明键无一匹配时退回候选链首档，避免完全空候选。
      return candidates.take(1).toList();
    }

    // 旧三档插件：首选映射 + 向下降级链。
    final mf = _qualityKeyToMfQuality(preferred);
    switch (fallback) {
      case 'higher':
        if (mf == 'standard') return ['standard', 'high', 'lossless'];
        if (mf == 'high') return ['high', 'lossless'];
        return ['lossless'];
      case 'pause':
        return [mf];
      default: // lower
        if (mf == 'lossless') return ['lossless', 'high', 'standard'];
        if (mf == 'high') return ['high', 'standard'];
        return ['standard'];
    }
  }

  /// 解析 MusicFree 插件播放直链。
  ///
  /// 与桌面端 pluginGetMusicInfo 对齐：优先传原生音质键，其次 standard/high/lossless；
  /// 参考包内同时带 url/headers。musicItem 会补齐 platform=插件名（对齐 resetMediaItem）。
  Future<String?> getMusicFreeUrl(
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

    // 优先透传搜索返回的原始条目（对齐桌面 getMediaSource(item.rawData, pluginName)），
    // 仅补充 platform 与常见字段别名，避免丢 title/artist/id 导致解析失败。
    final raw = songInfo['rawData'];
    final musicItem = raw is Map<String, dynamic>
        ? Map<String, dynamic>.from(raw)
        : Map<String, dynamic>.from(songInfo);
    if (musicItem['platform'] == null) {
      musicItem['platform'] = source.name;
    }
    // 字段别名兜底：插件常读 title/artist/id，归一化字段可能在 raw 之外。
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

    final tryQs = _musicFreeQualityCandidates(preferred, fallback, declaredKeys);
    for (final q in tryQs) {
      try {
        final response = await call(
          source.id,
          'getMediaSource',
          [musicItem, q],
        );
        final url = _extractMfPlayableUrl(response);
        if (url != null) return url;
      } catch (_) {
        // 单档失败继续下一档
      }
    }
    return null;
  }

  static String? _extractMfPlayableUrl(dynamic response) {
    if (response == null) return null;
    if (response is String) {
      return response.isNotEmpty &&
              response.length <= 2048 &&
              RegExp(r'^https?:').hasMatch(response)
          ? response
          : null;
    }
    if (response is Map) {
      final obj = response.cast<String, dynamic>();
      final url = (obj['url'] ?? obj['link'] ?? obj['playUrl']) as String?;
      if (url != null && url.isNotEmpty && url.length <= 2048 && RegExp(r'^https?:').hasMatch(url)) {
        return url;
      }
    }
    return null;
  }

  /// 解析歌曲播放直链。
  Future<Map<String, String>?> getMusicUrl(
    PluginSource source,
    String sourceKey,
    Map<String, dynamic> songInfo,
    String quality,
  ) async {
    final response = await lxRequest(source, 'musicUrl', {
      'source': sourceKey,
      'type': quality,
      'musicInfo': songInfo,
    });
    if (response == null) return null;

    // 兼容对象返回 { url, type, ... } 与纯字符串
    String? url;
    String type = quality;
    if (response is String) {
      url = response;
    } else if (response is Map) {
      final obj = response.cast<String, dynamic>();
      url = (obj['url'] ?? obj['link'] ?? obj['playUrl']) as String?;
      if (obj['type'] != null) type = obj['type'].toString();
    }
    if (url == null ||
        url.isEmpty ||
        url.length > 2048 ||
        !RegExp(r'^https?:').hasMatch(url)) {
      throw PluginEngineException('Invalid musicUrl response');
    }
    return {'type': type, 'url': url};
  }

  /// 获取歌词（返回原始字段，由调用方解析）。
  ///
  /// 按插件格式分发：LX 插件走 request/lyric 协议；MusicFree 插件调用它
  /// 自身的 getLyric(musicInfo) 方法（对齐桌面端 pluginGetLyric 对 MF 的取词路径）。
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

  /// 获取 MusicFree 插件歌词：调用插件的 getLyric(musicInfo) 方法。
  ///
  /// 与 getMediaSource 同构：优先透传搜索返回的原始条目 rawData，仅补充
  /// platform 与常见字段别名，避免丢 title/artist/id 导致解析失败。
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

  /// 统一把插件 lyric 返回归一化为歌词字段（缺失为 null；纯文本视为逐行歌词）。
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

  /// 获取封面 URL。
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

  /// 在单个 LX 插件中搜索（source 为插件内音源 key，如 'kw'）。
  Future<List<PluginSearchResult>> searchInPlugin(
    PluginSource source,
    String sourceKey,
    String keyword, {
    int limit = 30,
  }) async {
    final response = await lxRequest(source, 'search', {
      'source': sourceKey,
      'type': 'song',
      'musicInfo': {'keyword': keyword, 'page': 1, 'limit': limit},
    });
    if (response == null) return const [];
    final list = _extractResultList(response);
    return list
        .map((e) => PluginSearchResult.fromJson(e))
        .where((r) => r.name.isNotEmpty)
        .toList();
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
      // 忽略销毁失败
    }
  }

  Future<void> destroyAll() async {
    _ready.clear();
    _metadata.clear();
    _aliases.clear();
    try {
      await frb.pluginEngineDestroyAll(dataDir: dataDir);
    } catch (_) {
      // 忽略
    }
  }

  // ==================== 工具 ====================

  void _emitLogs(List<EngineLog> logs) {
    for (final entry in logs) {
      // 日志回放：错误级别输出到控制台
      if (entry.level == 'error') {
        // ignore: avoid_print
        print('[plugin] ${entry.message}');
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

  List<Map<String, dynamic>> _extractResultList(dynamic response) {
    if (response is List) {
      return response
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    if (response is Map) {
      final obj = response.cast<String, dynamic>();
      // 兼容 { data: [...] } / { result: [...] } / { songs: [...] } 结构
      for (final key in ['data', 'result', 'songs', 'list']) {
        final v = obj[key];
        if (v is List) {
          return v
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
        }
      }
    }
    return const [];
  }
}

/// 插件引擎异常。
class PluginEngineException implements Exception {
  final String message;
  PluginEngineException(this.message);

  @override
  String toString() => message;
}

/// 歌曲级错误：歌曲本身不可用（不存在/版权/VIP），换音质无法解决。
class LxSongLevelError extends PluginEngineException {
  LxSongLevelError(super.message);
}

/// 检测错误消息是否为歌曲级错误。
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
