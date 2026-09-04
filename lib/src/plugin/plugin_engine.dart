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

  /// Baka/Toskysun 系列插件独立管理器（对齐桌面 bakaPluginManager 架构拆分）：
  /// 识别锚点、声明档读取与原生键媒体解析收拢于此，MF 主路径保持纯净。
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

  /// 加载 MusicFree 插件，返回元数据；失败返回 null。
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
      throw PluginEngineException(
          tr('插件实例不存在: {pluginId}', {'pluginId': pluginId}));
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
      throw PluginEngineException(result.error ?? tr('方法调用失败'));
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
        // 重新加载得到的 hash 与存储 ID 不一致时注册别名
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

  /// 判断插件是否具备可播能力，供日推等聚合场景在收录歌曲前过滤，
  /// 避免把「能搜到但无法播放」的插件歌曲混入列表（对齐桌面端日推只走可播放插件）。
  /// - MusicFree：需实现 `getMediaSource`（元数据 `_availableMethods` 含该键）。
  /// - LX：需声明至少一个 `music` 音源且在 `actions` 中含 `musicUrl`。
  /// 加载失败或无对应方法一律视为不可播。
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

  // ==================== LX 请求协议 ====================

  /// 内部音质键 → LX 插件音质串（对齐桌面端 qualityKeyToLxQuality）：
  /// LX 体系没有 96k/mgg 概念，mgg 取最低标准档 128k；其余档位同名直传。
  static String lxQualityKeyFor(String q) => q == 'mgg' ? '128k' : q;

  /// 向 LX 插件发送请求（source/action/info 协议）。
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

  /// 归一化插件音质声明到统一 12 档键（对齐桌面 normalizeQualityKey）。
  static String? normalizeQualityKey(dynamic raw) => _normalizeQualityKey(raw);

  /// 内部键 → Baka 插件原生音质串（mgg 在插件侧为 96k）。
  static String _qualityKeyToPluginString(String q) => q == 'mgg' ? '96k' : q;

  /// 12 档音质阶梯（低 → 高）公开只读（供 Baka 管理器/探测层复用）。
  static const List<String> qualityLadder = _qualityLadder;

  /// 内部键 → Baka 插件原生音质串（mgg 在插件侧为 96k）公开包装。
  static String qualityKeyToPluginString(String q) =>
      _qualityKeyToPluginString(q);

  static bool _isLossless(String q) =>
      _qualityLadder.indexOf(q) >= _qualityLadder.indexOf('flac');

  /// 内部键 → MusicFree 四级键（对齐桌面 qualityKeyToMfQuality）。
  ///
  /// 原版 MusicFree 插件 getMediaSource 的入参是四级键 low/standard/high/super
  /// （约相当于 128k / 320k / FLAC / 超高），插件内部 QUALITY_MAPPING 只认这 4 个键。
  /// 映射规则：mgg/128k/192k → low；320k → standard；flac → high；其余无损 → super。
  /// 注意 _qualityLadder 为 0 基索引（320k 在 index 3），对应桌面 rank 需 +1。
  static String _qualityKeyToMfQuality(String q) {
    final rank = _qualityLadder.indexOf(q);
    if (rank < 0) return 'standard';
    if (rank >= 5) return 'super';
    if (rank >= 4) return 'high';
    if (rank >= 3) return 'standard';
    return 'low';
  }

  /// 内部键 → MusicFree 四级键公开包装（供探测层按四级键分组代表档）。
  static String qualityKeyToMfQuality(String q) => _qualityKeyToMfQuality(q);

  /// MusicFree 四级键顺序（低 → 高），对齐桌面 MF_QUALITY_ORDER。
  static const List<String> _mfQualityOrder = ['low', 'standard', 'high', 'super'];

  /// 构建 MusicFree 音质候选（对齐桌面 runPluginGetMusicInfo 的 MF 四级键主路径）。
  ///
  /// 原版 MusicFree 插件 getMediaSource 的入参是四级键 low/standard/high/super，
  /// 插件内部 QUALITY_MAPPING 只认这 4 个键（supportedQualities 声明仅用于展示）。
  /// 若按声明值直传原生键，128k/flac 等在插件 QUALITY_MAPPING 里查不到映射，
  /// 会全部回退到默认档（如 320k），导致音质列表塌缩成只有一档。
  ///
  /// 主路径统一用 _qualityKeyToMfQuality 映射到四级键，按官方 asc 顺序
  /// （首选 → 更高 → 更低）逐级尝试；pause 时仅尝试首选档。
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

  /// 构建 MusicFree 原生键候选（对齐桌面 buildNativePluginQualityPairs）。
  ///
  /// 仅当四级键全部报「不支持音质」时作为兜底补试；部分 QQ/MusicFree 插件
  /// 实际接收 flac/320k/128k/super 等原生键。按降级方向生成候选，无损档
  /// 额外补充 'super'（部分插件把无损档称作 super）。
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
      // 候选为插件串（mgg→96k），需先归一化再与声明键比对。
      final filtered = candidates.where((c) {
        final norm = _normalizeQualityKey(c);
        return norm != null && declaredKeys.contains(norm);
      }).toList();
      if (filtered.isNotEmpty) return filtered;
    }
    // 声明键无一匹配时退回候选链首档，避免完全空候选。
    return candidates.take(1).toList();
  }

  /// 是否 Baka 系列插件：委托独立管理器（锚点顺序与缓存语义见
  /// [BakaPluginManager.isBakaPlugin]，对齐桌面 BakaPluginManager.isBakaPlugin）。
  bool isBakaPlugin(String pluginId) => bakaManager.isBakaPlugin(pluginId);

  /// 解析 MusicFree 插件播放直链。
  ///
  /// 与桌面端 pluginGetMusicInfo 对齐：主路径传 MF 四级键（low/standard/high/super），
  /// 四级键全部报「不支持音质」时兜底补试原生键；参考包内同时带 url/headers。
  /// Baka 系列插件在入口转交独立管理器（对齐桌面 pluginEngineMedia 分发：
  /// BakaMusic API 向下兼容 MF，但播放音质应优先使用 Baka 原生键）。
  /// musicItem 会补齐 platform=插件名（对齐 resetMediaItem）。
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

    // Baka 系列插件转交独立管理器：12 档原生键主路径 + legacy 逐档回退 +
    // 在途去重/结果缓存（对齐桌面 pluginEngineMedia 分发 + bakaPluginManagerMedia）。
    if (bakaManager.isBakaPlugin(source.id)) {
      return bakaManager.getMediaSource(
        source,
        musicItem,
        preferred: preferred,
        fallback: fallback,
        declaredKeys: declaredKeys,
      );
    }

    // 主路径：MF 四级键按 asc 顺序尝试；记录是否出现「不支持音质」错误。
    // 单档 = 1 次调用（降级由调用方候选链逐档负责），失败延迟重试 1 次
    // （对齐桌面 pluginEngineMedia 每档重试语义，吸收插件网络抖动）。
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
        // 单档失败继续下一档
      }
    }

    // 兜底：四级键全部报「不支持音质」时补试原生键，避免可播放歌曲被误判。
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
          // 单档失败继续下一档
        }
      }
    }
    return null;
  }

  /// 单档 getMediaSource 调用 + 失败延迟重试 1 次（对齐桌面每档重试）。
  /// 「不支持音质」属确定性失败，直接抛出不重试；空结果由调用方按下一档处理。
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

  /// 从插件 getMediaSource 返回中提取可播放直链（公开：Baka 管理器复用）。
  static ResolvedMediaUrl? extractMfPlayableUrl(
    dynamic response, {
    String? requestedKey,
  }) {
    if (response == null) return null;
    // QQ 60 秒试听链（RS02 前缀）不是可用播放源：走免费公共中转的 QQ 插件游客
    // 模板恒返试听且各音质档同一文件。若照常返回用户只能听到 60 秒还误以为歌
    // 就这「那么短」。拒收并继续下一音质档，全档失败由起播失败行为透出（对齐桌面
    // bakaPluginManagerMedia 的 shouldAcceptMediaResult）。
    bool notQqTrial(String url) => !isQqTrialMediaUrl(url);
    // 采用插件实际返回的档位（quality/type/actualQuality），对齐桌面端
    // `actualQuality = normalizeQualityKey(result.quality) ?? inferActualQualityFromMediaUrl`。
    // 插件把 flac 请求降级为 320k 时会如实报告，丢掉它会导致音质菜单/体积探测虚高，
    // 出现「假音质」。归一化失败则回落到请求档，由下游无损扩展名校验兜底。
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
        return ResolvedMediaUrl(
          url: url,
          headers: h is Map ? h.cast<String, String>() : null,
          quality: reported ?? requestedNorm,
        );
      }
    }
    return null;
  }

  /// 解析歌曲播放直链。
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

    // 兼容对象返回 { url, type, headers, ... } 与纯字符串
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
  ///
  /// 与桌面端一致：LX 插件不实现 search（仅 musicUrl/lyric/pic），歌曲搜索
  /// 全部由宿主落雪签名接口（lxSearch）代取，按插件声明的音源 key 分发到
  /// kw/kg/tx/wy/mg 对应平台；播放仍走插件自身 musicUrl。宿主失败返回空数组。
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
      // 引擎侧 JS console 日志统一接入应用日志系统（错误/警告常驻可导出，
      // 调试级进入 200 条环形缓冲），同时经 AppLog 双写控制台。
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

/// 检测错误消息是否为「不支持音质」类错误（对齐桌面 isUnsupportedQualityError）。
///
/// 部分插件只认原生音质键，收到 MF 四级键（low/standard/high/super）时报此错；
/// 检测到后由 getMusicFreeUrl 兜底补试原生键。
bool isUnsupportedQualityError(String message) {
  return RegExp(
    r'不支持.*音质|音质.*不支持|quality.*not\s+support|not\s+support.*quality',
    caseSensitive: false,
  ).hasMatch(message);
}
