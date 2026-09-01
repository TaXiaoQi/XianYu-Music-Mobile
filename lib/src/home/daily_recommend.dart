import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import '../core/settings.dart';
import '../player/player_provider.dart';
import '../plugin/plugin_catalog.dart';
import '../plugin/plugin_engine.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../rust/api.dart';
import '../i18n/i18n.dart';

// ─── 算法 DSL 模型（与服务端 recommend.rs 对齐） ─────────────────

/// 推荐策略：类型 + 权重 + 查询词 + 推荐理由，由服务器决策下发。
class DailyRecommendStrategy {
  final String id;
  final String type;
  final double weight;
  final List<String> queries;
  final String reason;
  const DailyRecommendStrategy({
    required this.id,
    required this.type,
    required this.weight,
    required this.queries,
    required this.reason,
  });
}

class DailyRecommendAlgorithm {
  final Map<String, dynamic> raw;
  final String date;
  final int dailySeed;
  final int targetCount;
  final List<DailyRecommendStrategy> strategies;
  final List<({String title, String artist})> exclusions;
  final List<String> topArtistNames;
  const DailyRecommendAlgorithm({
    required this.raw,
    required this.date,
    required this.dailySeed,
    required this.targetCount,
    required this.strategies,
    required this.exclusions,
    required this.topArtistNames,
  });

  factory DailyRecommendAlgorithm.fromJson(Map<String, dynamic> j) {
    final strategies = (j['strategies'] as List? ?? const [])
        .map((e) => e as Map<String, dynamic>)
        .map((e) => DailyRecommendStrategy(
              id: (e['id'] as String?) ?? '',
              type: (e['type'] as String?) ?? '',
              weight: (e['weight'] as num?)?.toDouble() ?? 0,
              queries: (e['queries'] as List? ?? const [])
                  .map((q) => q.toString().trim())
                  .where((q) => q.isNotEmpty)
                  .toList(),
              reason: (e['reason'] as String?) ?? '',
            ))
        .where((s) => s.queries.isNotEmpty && s.weight > 0)
        .toList();
    if (strategies.isEmpty) {
      throw   FormatException(tr('算法数据无效'));
    }
    final exclusions =
        (((j['exclusions'] as Map<String, dynamic>?)?['songs']) as List? ??
                const [])
            .map((e) => e as Map<String, dynamic>)
            .map((e) => (
                  title: (e['title'] as String?) ?? '',
                  artist: (e['artist'] as String?) ?? '',
                ))
            .toList();
    final profile = j['profile'] as Map<String, dynamic>?;
    final topArtists = (profile?['top_artists'] as List? ?? const [])
        .map((e) => e as Map<String, dynamic>)
        .map((e) => (e['name'] as String?) ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    return DailyRecommendAlgorithm(
      raw: j,
      date: (j['date'] as String?) ?? '',
      dailySeed: (j['daily_seed'] as num?)?.toInt() ?? 0,
      targetCount: (j['target_count'] as num?)?.toInt() ?? 30,
      strategies: strategies,
      exclusions: exclusions,
      topArtistNames: topArtists.take(3).toList(),
    );
  }
}

/// 单条推荐结果 + 命中策略。
///
/// - 有可用插件时：优先用已启用音源插件搜索并播放（对齐桌面端日推只走插件），
///   [song] 为 [PluginSearchResult.toJson]（camelCase，musicfree 含 rawData），
///   [pluginId]/[pluginFormat] 记录来源插件，播放走 `_resolvePluginUrl`，不依赖
///   LX 公共代理直链（该代理在移动端经常超时导致「直链解析失败/自动跳下一首」）。
/// - 无插件兜底：走 Rust 内置 `lxSearch`（LX 公共直链），[song] 为 snake_case。
class DailyRecommendItem {
  final Map<String, dynamic> song;
  final String reason;
  final String strategyId;
  /// 来源插件 id；null 表示走 LX 原生搜索（公共代理兜底）。
  final String? pluginId;
  /// 来源插件格式：'lx' / 'musicfree'（仅 [pluginId] 非空时有意义）。
  final String pluginFormat;

  const DailyRecommendItem({
    required this.song,
    required this.reason,
    required this.strategyId,
    this.pluginId,
    this.pluginFormat = 'lx',
  });

  bool get isPlugin => pluginId != null && pluginId!.isNotEmpty;

  String get title => (song['name'] as String?) ?? '';
  String get artist => (song['singer'] as String?) ?? '';
  String get album =>
      (song[isPlugin ? 'albumName' : 'album_name'] as String?) ?? '';
  String? get coverUrl => song['img'] as String?;

  int get durationMs => _intervalToMs((song['interval'] as String?) ?? '');

  /// 归一化去重键：标题|第一歌手（空则不可参与去重）。
  String? get dedupKey {
    final normTitle = _normalizeText(title);
    final normArtist = _normalizeText(_firstArtist(artist));
    if (normTitle.isEmpty || normArtist.isEmpty) return null;
    return '$normTitle|$normArtist';
  }

  /// 构造在线播放队列项。
  ///
  /// 插件来源：生成带 pluginId 的 onlineSongJson，播放走插件直链（可靠）；
  /// LX 原生兜底：lx:// 伪路径，播放时按需解析公共直链。
  QueueItem toQueueItem(String quality) {
    if (isPlugin) {
      final isMf = pluginFormat == 'musicfree';
      final src = (song['source'] as String?) ?? '';
      final mid = (song['songmid'] as String?) ?? '';
      return QueueItem(
        path: isMf ? 'plugin://$pluginId/$mid' : 'lx://$src/$mid',
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        coverUrl: coverUrl,
        onlineSongJson: jsonEncode({
          'pluginId': pluginId,
          'format': pluginFormat,
          if (!isMf) 'source': src,
          'musicInfo': song,
        }),
        onlineQuality: quality,
        // LX 插件歌词兜底：走 Rust 内置各源直连歌词（与 PluginSearchService 一致）；
        // musicfree 插件不附加，避免被当成 LX 在线歌词走 LoL 逻辑。
        source: isMf ? null : src,
        onlineInfoJson: isMf ? null : jsonEncode(song),
      );
    }
    return QueueItem(
      path: 'lx://${song['source']}/${song['songmid']}',
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
      coverUrl: coverUrl,
      onlineSongJson: jsonEncode(_toUrlSongInfo(song)),
      onlineQuality: quality,
    );
  }
}

class DailyRecommendState {
  final bool loggedIn;
  final List<DailyRecommendItem> items;
  final DailyRecommendAlgorithm? algorithm;
  final int batch;
  const DailyRecommendState({
    this.loggedIn = true,
    this.items = const [],
    this.algorithm,
    this.batch = 0,
  });
}

// ─── 常量 ────────────────────────────────────────────────────────

/// 参与搜索的 LX 音源（与 Rust 端解析优先级一致）
const _searchSources = ['kw', 'tx', 'wy'];
/// 每个查询词取的搜索结果数
const _searchLimit = 20;
/// 并发搜索数上限
const _searchConcurrency = 4;
/// 候选池上限（换一批从中重新洗牌取样）
const _maxCandidates = 90;
/// 低于该时长（毫秒）的结果视为试听/铃声，过滤
const _minDurationMs = 45000;
/// 本地缓存键（换账号/跨天自动失效；v2 引入插件来源）
const _cacheKey = 'daily_recommend_v2';

// ─── 工具函数（与桌面端 dailyRecommend.ts 对齐） ─────────────────

/// 32 位有符号乘法（对齐 JS Math.imul 语义）
int _imul(int a, int b) => ((a * b) & 0xFFFFFFFF).toSigned(32);

/// mulberry32 确定性伪随机：同一种子同一次序，保证同一天/同批次结果一致
double Function() _mulberry32(int seed) {
  var a = seed.toUnsigned(32);
  return () {
    a = (a + 0x6D2B79F5) & 0xFFFFFFFF;
    var t = a.toSigned(32);
    t = _imul(t ^ (t >>> 15), t | 1);
    t = (t + _imul(t ^ (t >>> 7), t | 61)) ^ t;
    return ((t ^ (t >>> 14)) & 0xFFFFFFFF) / 4294967296;
  };
}

/// 归一化标题/歌手：去空白、括号后缀、分隔符，用于排除与去重匹配
String _normalizeText(String input) {
  var s = input.toLowerCase();
  s = s.replaceAll(RegExp(r'[（(【\[][^）)】\]]*[）)】\]]'), '');
  s = s.replaceAll(RegExp(r"[\s'’`·・~～!！?？.。,，、]"), '');
  return s.trim();
}

/// 取第一位歌手（多歌手合唱场景）
String _firstArtist(String artist) {
  final parts = artist.split(RegExp(r'[/、,&]'));
  return parts.isEmpty ? '' : parts.first.trim();
}

/// "MM:SS" → 毫秒；无法解析返回 0（未知时长保留，播放时再取）
int _intervalToMs(String interval) {
  final m = RegExp(r'^(\d+):(\d+)$').firstMatch(interval.trim());
  if (m == null) return 0;
  return (int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!)) * 1000;
}

/// LxSearchItem(snake_case) → LxUrlSongInfo(camelCase)，供直链解析
Map<String, dynamic> _toUrlSongInfo(Map<String, dynamic> song) => {
      'songmid': song['songmid'] ?? '',
      'source': song['source'] ?? '',
      'hash': song['hash'],
      'name': song['name'],
      'singer': song['singer'],
      'albumName': song['album_name'],
      'albumId': song['album_id'],
      'albumMid': song['album_mid'],
      'copyrightId': song['copyright_id'],
      'strMediaMid': song['str_media_mid'],
      'songId': song['song_id'],
      '_types': song['lx_types'],
    };

String _localDateKey() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

// ─── 算法执行 ────────────────────────────────────────────────────

class _SearchTask {
  final DailyRecommendStrategy strategy;
  final String query;
  final String source;
  const _SearchTask(this.strategy, this.query, this.source);
}

/// 插件搜索任务：策略查询词在已启用插件间轮询分配（对齐桌面端 buildSearchTasks）。
class _PluginSearchTask {
  final DailyRecommendStrategy strategy;
  final String query;
  final PluginSource plugin;
  const _PluginSearchTask(this.strategy, this.query, this.plugin);
}

/// 已收集但尚未去重的中间结果。
typedef _Collected = ({DailyRecommendItem item, double score});

/// 执行推荐算法：搜索(插件优先，无插件退回 LX) → 排除/过滤 → 打分去重 →
/// 每日种子洗牌 → 候选池。单个搜索失败静默跳过，整体无结果时返回空列表。
Future<List<DailyRecommendItem>> _executeAlgorithm(
    DailyRecommendAlgorithm algorithm,
    PluginEngine engine,
    List<PluginSource> pluginSources) async {
  final exclusionSet = <String>{};
  for (final e in algorithm.exclusions) {
    if (e.title.isEmpty) continue;
    exclusionSet.add('${_normalizeText(e.title)}|${_normalizeText(_firstArtist(e.artist))}');
  }

  final enabledPlugins = pluginSources.where((s) => s.enabled).toList();
  final collected = <_Collected>[];
  if (enabledPlugins.isNotEmpty) {
    await _searchAll(engine, algorithm, enabledPlugins, exclusionSet, collected);
  } else {
    await _searchLx(algorithm, exclusionSet, collected);
  }

  // 打分去重：score = 策略权重 + 搜索排名，同曲多源保留最高分
  final best = <String, _Collected>{};
  for (final c in collected) {
    final key = c.item.dedupKey;
    if (key == null) continue;
    final prev = best[key];
    if (prev == null || c.score > prev.score) best[key] = c;
  }

  // 每日种子洗牌（候选池按种子确定次序）
  final candidates = best.values.map((v) => v.item).toList();
  final rand = _mulberry32(algorithm.dailySeed);
  for (var i = candidates.length - 1; i > 0; i--) {
    final j = (rand() * (i + 1)).floor();
    final tmp = candidates[i];
    candidates[i] = candidates[j];
    candidates[j] = tmp;
  }
  return candidates.length > _maxCandidates
      ? candidates.sublist(0, _maxCandidates)
      : candidates;
}

/// 用已启用音源插件搜索并收集候选（每个查询词轮询分配一个插件，限制并发）。
Future<void> _searchAll(
  PluginEngine engine,
  DailyRecommendAlgorithm algorithm,
  List<PluginSource> plugins,
  Set<String> exclusionSet,
  List<_Collected> collected,
) async {
  final tasks = <_PluginSearchTask>[];
  var slot = 0;
  for (final strategy in algorithm.strategies) {
    for (final q in strategy.queries) {
      tasks.add(_PluginSearchTask(
        strategy,
        q,
        plugins[(slot++) % plugins.length],
      ));
    }
  }

  var cursor = 0;
  Future<void> worker() async {
    while (cursor < tasks.length) {
      final task = tasks[cursor++];
      try {
        final results = await _searchPlugin(engine, task.plugin, task.query);
        for (var rank = 0; rank < results.length; rank++) {
          final r = results[rank];
          final item = _fromPluginResult(task.plugin, r, task.strategy);
          if (!_accept(item, durationMs: item.durationMs,
              exclusionSet: exclusionSet)) continue;
          collected.add((
            item: item,
            score: task.strategy.weight * 0.6 + (1 - rank / _searchLimit) * 0.4,
          ));
        }
      } catch (_) {
        /* 单个插件搜索失败静默 */
      }
    }
  }

  final workerCount = math.min(_searchConcurrency, tasks.length);
  await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
}

/// LX 原生搜索兜底（字典分 source，alias 为原 _buildTasks）。无插件时退化公共代理。
Future<void> _searchLx(
  DailyRecommendAlgorithm algorithm,
  Set<String> exclusionSet,
  List<_Collected> collected,
) async {
  final tasks = <_SearchTask>[];
  {
    var slot = 0;
    for (final strategy in algorithm.strategies) {
      for (var qi = 0; qi < strategy.queries.length; qi++) {
        final source = _searchSources[(slot + qi) % _searchSources.length];
        tasks.add(_SearchTask(strategy, strategy.queries[qi], source));
      }
      slot += strategy.queries.length;
    }
  }

  final results = <_SearchTask, List<Map<String, dynamic>>>{};
  var cursor = 0;
  Future<void> worker() async {
    while (cursor < tasks.length) {
      final task = tasks[cursor++];
      try {
        final json = await lxSearch(
          source: task.source,
          keyword: task.query,
          limit: _searchLimit,
        );
        results[task] = (jsonDecode(json) as List)
            .map((e) => e as Map<String, dynamic>)
            .toList();
      } catch (_) {
        /* 单个音源搜索失败静默 */
      }
    }
  }

  final workerCount = math.min(_searchConcurrency, tasks.length);
  await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);

  for (final task in tasks) {
    final songs = results[task];
    if (songs == null) continue;
    for (var rank = 0; rank < songs.length; rank++) {
      final song = songs[rank];
      final item = DailyRecommendItem(
        song: song,
        reason: task.strategy.reason,
        strategyId: task.strategy.id,
      );
      if (!_accept(item, durationMs: item.durationMs,
          exclusionSet: exclusionSet)) continue;
      collected.add((
        item: item,
        score: task.strategy.weight * 0.6 + (1 - rank / _searchLimit) * 0.4,
      ));
    }
  }
}

/// 单个插件按关键字搜索（MusicFree 走 search music，LX 逐声明音源搜索）。
Future<List<PluginSearchResult>> _searchPlugin(
    PluginEngine engine, PluginSource plugin, String keyword) async {
  if (plugin.format == PluginFormat.musicfree) {
    return PluginCatalogService(engine, [plugin])
        .searchMusic(plugin, keyword, limit: _searchLimit);
  }
  final sourceKeys =
      plugin.sources.isEmpty ? <String>['default'] : plugin.sources;
  final merged = <PluginSearchResult>[];
  for (final key in sourceKeys) {
    try {
      merged.addAll(
          await engine.searchInPlugin(plugin, key, keyword, limit: _searchLimit));
    } catch (_) {
      /* 单音源失败不影响 */
    }
  }
  return merged;
}

/// 插件搜索结果 → 日推条目。
DailyRecommendItem _fromPluginResult(
    PluginSource plugin, PluginSearchResult r, DailyRecommendStrategy strategy) {
  return DailyRecommendItem(
    song: r.toJson(),
    reason: strategy.reason,
    strategyId: strategy.id,
    pluginId: plugin.id,
    pluginFormat: plugin.format.value,
  );
}

/// 通用准入过滤：标题/歌手非空、时长过短过滤、命中排除名单则丢弃。
bool _accept(DailyRecommendItem item,
    {required int durationMs, required Set<String> exclusionSet}) {
  if (item.title.isEmpty || item.artist.isEmpty) return false;
  if (durationMs > 0 && durationMs < _minDurationMs) return false;
  final key = item.dedupKey;
  if (key == null) return false;
  if (exclusionSet.contains(key)) return false;
  return true;
}

/// 从候选池按批次种子洗牌并截取目标数量
List<DailyRecommendItem> _pickBatch(List<DailyRecommendItem> candidates,
    DailyRecommendAlgorithm algorithm, int batch) {
  final seed = algorithm.dailySeed + batch * 7919;
  final rand = _mulberry32(seed);
  final pool = List<DailyRecommendItem>.from(candidates);
  for (var i = pool.length - 1; i > 0; i--) {
    final j = (rand() * (i + 1)).floor();
    final tmp = pool[i];
    pool[i] = pool[j];
    pool[j] = tmp;
  }
  return pool.sublist(0, math.min(math.max(1, algorithm.targetCount), pool.length));
}

// ─── 当日缓存 ────────────────────────────────────────────────────

class _DailyCache {
  final String ciyuanxiId;
  final String date;
  final int batch;
  final DailyRecommendAlgorithm algorithm;
  final List<DailyRecommendItem> candidates;
  const _DailyCache({
    required this.ciyuanxiId,
    required this.date,
    required this.batch,
    required this.algorithm,
    required this.candidates,
  });

  Map<String, dynamic> toJson() => {
        'ciyuanxiId': ciyuanxiId,
        'date': date,
        'batch': batch,
        'algorithm': algorithm.raw,
        'candidates': [
          for (final c in candidates)
            {
              'song': c.song,
              'reason': c.reason,
              'strategyId': c.strategyId,
              'pluginId': c.pluginId,
              'pluginFormat': c.pluginFormat,
            },
        ],
      };

  static _DailyCache? fromJson(Map<String, dynamic> j) {
    final algoRaw = j['algorithm'];
    if (algoRaw is! Map<String, dynamic>) return null;
    final DailyRecommendAlgorithm algorithm;
    try {
      algorithm = DailyRecommendAlgorithm.fromJson(algoRaw);
    } catch (_) {
      return null;
    }
    final candidates = (j['candidates'] as List? ?? const [])
        .map((e) => e as Map<String, dynamic>)
        .map((e) => DailyRecommendItem(
              song: (e['song'] as Map?)?.cast<String, dynamic>() ?? const {},
              reason: (e['reason'] as String?) ?? '',
              strategyId: (e['strategyId'] as String?) ?? '',
              pluginId: e['pluginId'] as String?,
              pluginFormat: e['pluginFormat'] as String? ?? 'lx',
            ))
        .where((c) => c.song.isNotEmpty)
        .toList();
    if (candidates.isEmpty) return null;
    return _DailyCache(
      ciyuanxiId: (j['ciyuanxiId'] as String?) ?? '',
      date: (j['date'] as String?) ?? '',
      batch: (j['batch'] as num?)?.toInt() ?? 0,
      algorithm: algorithm,
      candidates: candidates,
    );
  }
}

Future<_DailyCache?> _loadCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return null;
    return _DailyCache.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

Future<void> _saveCache(_DailyCache cache) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, jsonEncode(cache.toJson()));
  } catch (_) {
    /* 存储异常静默 */
  }
}

Future<void> clearDailyRecommendCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
  } catch (_) {}
}

// ─── Provider ────────────────────────────────────────────────────

final dailyRecommendProvider =
    AsyncNotifierProvider<DailyRecommendNotifier, DailyRecommendState>(
        DailyRecommendNotifier.new);

class DailyRecommendNotifier extends AsyncNotifier<DailyRecommendState> {
  @override
  Future<DailyRecommendState> build() async {
    final auth = ref.watch(authProvider);
    final ciyuanxiId = auth.user?.ciyuanxiId?.trim() ?? '';
    if (ciyuanxiId.isEmpty) {
      await clearDailyRecommendCache();
      return const DailyRecommendState(loggedIn: false);
    }

    final today = _localDateKey();
    final cached = await _loadCache();
    if (cached != null &&
        cached.ciyuanxiId == ciyuanxiId &&
        cached.date == today) {
      return DailyRecommendState(
        items: _pickBatch(cached.candidates, cached.algorithm, cached.batch),
        algorithm: cached.algorithm,
        batch: cached.batch,
      );
    }

    // 算法本体由服务器下发，本机执行（插件优先，无插件退回 LX → 过滤打分 → 种子洗牌）
    final data = await ref
        .read(authProvider.notifier)
        .requestAction('get_daily_recommend', {'ciyuanxi_id': ciyuanxiId});
    final algorithm = DailyRecommendAlgorithm.fromJson(data);
    final engine = await ref.read(pluginEngineProvider.future);
    final pluginSources = await engine.store.loadSources();
    final candidates = await _executeAlgorithm(algorithm, engine, pluginSources);
    await _saveCache(_DailyCache(
      ciyuanxiId: ciyuanxiId,
      date: today,
      batch: 0,
      algorithm: algorithm,
      candidates: candidates,
    ));
    return DailyRecommendState(
      items: _pickBatch(candidates, algorithm, 0),
      algorithm: algorithm,
      batch: 0,
    );
  }

  /// 换一批：候选池当日复用，批次 +1 按批次种子重新洗牌取样。
  Future<void> refresh() async {
    final ciyuanxiId = ref.read(authProvider).user?.ciyuanxiId?.trim() ?? '';
    if (ciyuanxiId.isEmpty) return;
    final today = _localDateKey();
    final cached = await _loadCache();
    if (cached == null || cached.ciyuanxiId != ciyuanxiId || cached.date != today) {
      state = const AsyncLoading();
      state = await AsyncValue.guard(build);
      return;
    }
    final nextBatch = cached.batch + 1;
    await _saveCache(_DailyCache(
      ciyuanxiId: ciyuanxiId,
      date: today,
      batch: nextBatch,
      algorithm: cached.algorithm,
      candidates: cached.candidates,
    ));
    state = AsyncData(DailyRecommendState(
      items: _pickBatch(cached.candidates, cached.algorithm, nextBatch),
      algorithm: cached.algorithm,
      batch: nextBatch,
    ));
  }

  /// 播放推荐歌曲：整批入队（在线直链播放时按需解析），失败自动跳下一首。
  Future<void> play(int index) async {
    final st = state.valueOrNull;
    if (st == null || index < 0 || index >= st.items.length) return;
    final quality =
        ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ?? '320k';
    final queue =
        st.items.map((it) => it.toQueueItem(quality)).toList();
    await ref
        .read(playerProvider.notifier)
        .playQueue(queue, startIndex: index);
  }
}
