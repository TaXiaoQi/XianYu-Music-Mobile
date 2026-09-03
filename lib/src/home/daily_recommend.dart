import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
/// 只走已启用音源插件搜索并播放（对齐桌面端日推；无可用插件时日推为空），
/// [song] 为 [PluginSearchResult.toJson]（camelCase，musicfree 含 rawData），
/// [pluginId]/[pluginFormat] 记录来源插件，播放走插件直链。
class DailyRecommendItem {
  final Map<String, dynamic> song;
  final String reason;
  final String strategyId;
  /// 来源插件 id。
  final String pluginId;
  /// 来源插件格式：'lx' / 'musicfree'。
  final String pluginFormat;

  const DailyRecommendItem({
    required this.song,
    required this.reason,
    required this.strategyId,
    required this.pluginId,
    this.pluginFormat = 'musicfree',
  });

  String get title => (song['name'] as String?) ?? '';
  String get artist => (song['singer'] as String?) ?? '';
  String get album => (song['albumName'] as String?) ?? '';
  /// 可显示封面：完整复用桌面端提取逻辑（酷我域名归一化 / 短路径 / 网易云
  /// picId 兜底），失败再回退插件原始 img 字段。
  String? get coverUrl {
    final resolved = resolveSongCoverUrl(song);
    if (resolved != null && resolved.isNotEmpty) return resolved;
    return song['img'] as String?;
  }

  int get durationMs => _intervalToMs((song['interval'] as String?) ?? '');

  /// 归一化去重键：标题|第一歌手（空则不可参与去重）。
  String? get dedupKey {
    final normTitle = _normalizeText(title);
    final normArtist = _normalizeText(_firstArtist(artist));
    if (normTitle.isEmpty || normArtist.isEmpty) return null;
    return '$normTitle|$normArtist';
  }

  /// 构造在线播放队列项：生成带 pluginId 的 onlineSongJson，播放走插件直链。
  QueueItem toQueueItem(String quality) {
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

/// 每个查询词取的搜索结果数
const _searchLimit = 20;
/// 并发搜索数上限
const _searchConcurrency = 4;
/// 候选池上限（换一批从中重新洗牌取样）
const _maxCandidates = 90;
/// 低于该时长（毫秒）的结果视为试听/铃声，过滤
const _minDurationMs = 45000;
/// 本地缓存键（换账号/跨天自动失效；v3 移除 LX 原生兜底来源）
const _cacheKey = 'daily_recommend_v3';

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

String _localDateKey() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

// ─── 算法执行 ────────────────────────────────────────────────────

/// 插件搜索任务：策略查询词在已启用插件间轮询分配（对齐桌面端 buildSearchTasks）。
class _PluginSearchTask {
  final DailyRecommendStrategy strategy;
  final String query;
  final PluginSource plugin;
  const _PluginSearchTask(this.strategy, this.query, this.plugin);
}

/// 已收集但尚未去重的中间结果。
typedef _Collected = ({DailyRecommendItem item, double score});

/// 执行推荐算法：插件搜索 → 排除/过滤 → 打分去重 → 每日种子洗牌 → 候选池。
/// 单个搜索失败静默跳过，无可用插件或整体无结果时返回空列表。
Future<List<DailyRecommendItem>> _executeAlgorithm(
    DailyRecommendAlgorithm algorithm,
    PluginEngine engine,
    List<PluginSource> pluginSources) async {
  final exclusionSet = <String>{};
  for (final e in algorithm.exclusions) {
    if (e.title.isEmpty) continue;
    exclusionSet.add('${_normalizeText(e.title)}|${_normalizeText(_firstArtist(e.artist))}');
  }

  // 只保留「可播放」的插件（MusicFree 需实现 getMediaSource、LX 需声明 musicUrl），
  // 对齐桌面端日推只走可播放插件；无可用插件时日推为空（页面展示空态）。
  final enabledPlugins = pluginSources.where((s) => s.enabled).toList();
  final playable = <PluginSource>[];
  for (final p in enabledPlugins) {
    if (await engine.canPlayMusic(p)) playable.add(p);
  }
  final collected = <_Collected>[];
  if (playable.isEmpty) return const [];
  await _searchAll(engine, algorithm, playable, exclusionSet, collected);

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
          if (!_accept(item,
              durationMs: item.durationMs,
              exclusionSet: exclusionSet)) {
            continue;
          }
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
              pluginId: (e['pluginId'] as String?) ?? '',
              pluginFormat: e['pluginFormat'] as String? ?? 'musicfree',
            ))
        .where((c) => c.song.isNotEmpty && c.pluginId.isNotEmpty)
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

// ─── 网易云缺省元数据补齐（对齐桌面 fetchWyTrackMetaByIds） ─────────
//
// 部分第三方网易云 MusicFree 插件（如时迁酱）在 search 结果里既不返回可用
// artwork（weapi/search 的 album 只有 picId 无 picUrl），也就解析不出封面。
// 这里用官方 weapi song/detail 按 ID 批量补全封面/时长，绕过插件实现差异。

/// 从日推条目 song map 中取网易云纯数字 ID（musicfree 插件的 songmid 即歌曲 ID）。
String? _wySongId(Map<String, dynamic> song) {
  final id = (song['songmid'] ?? song['songId'] ?? song['id'] ?? '').toString().trim();
  if (RegExp(r'^\d+$').hasMatch(id) && id != '0') return id;
  return null;
}

/// 网易云单曲补齐结果（封面 + 时长 ms）。
typedef _WyTrackPatch = ({String coverUrl, int durationMs});

/// weapi song/detail 批量补齐 → Map<歌曲ID, patch>；失败返回空 Map。
Future<Map<String, _WyTrackPatch>> _fetchWyTrackMeta(List<String> ids) async {
  final result = <String, _WyTrackPatch>{};
  final all = ids.where((id) => RegExp(r'^\d+$').hasMatch(id)).toList();
  if (all.isEmpty) return result;

  HttpClient? client;
  try {
    final payload = jsonEncode({
      'c': '[${all.map((id) => '{"id":$id}').join(',')}]',
      'ids': '[${all.join(',')}]',
    });
    final encRaw = await hostWeapiEncrypt(payload: payload);
    final enc = jsonDecode(encRaw) as Map<String, dynamic>;
    final params = enc['params']?.toString() ?? '';
    final encSecKey = enc['encSecKey']?.toString() ?? '';
    if (params.isEmpty || encSecKey.isEmpty) return result;

    final body =
        'params=${Uri.encodeComponent(params)}&encSecKey=${Uri.encodeComponent(encSecKey)}';

    client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    final req = await client.postUrl(
        Uri.parse('https://music.163.com/weapi/v3/song/detail'));
    req.headers
      ..set('Content-Type', 'application/x-www-form-urlencoded')
      ..set('User-Agent',
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36')
      ..set('Origin', 'https://music.163.com')
      ..set('Referer', 'https://music.163.com/');
    req.write(body);
    final resp = await req.close().timeout(const Duration(seconds: 15));
    if (resp.statusCode < 200 || resp.statusCode >= 400) return result;
    final text = await resp.transform(utf8.decoder).join();
    final data = jsonDecode(text);
    if (data is! Map || data['code'] != 200) return result;
    final songs = data['songs'];
    if (songs is! List) return result;
    for (final s in songs) {
      if (s is! Map) continue;
      final id = (s['id'] ?? '').toString();
      if (!RegExp(r'^\d+$').hasMatch(id)) continue;
      final al = s['al'] is Map ? (s['al'] as Map).cast<String, dynamic>() : null;
      final album =
          s['album'] is Map ? (s['album'] as Map).cast<String, dynamic>() : null;
      final img = (al?['picUrl'] as String?) ?? (album?['picUrl'] as String?) ?? '';
      if (img.isEmpty) continue;
      final dtRaw = s['dt'] ?? s['duration'];
      final dur = dtRaw is num && dtRaw > 0 ? dtRaw.toInt() : 0;
      result[id] = (coverUrl: img, durationMs: dur);
    }
  } catch (_) {
    // 网络/解析失败静默，保持原样
  } finally {
    client?.close();
  }
  return result;
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
      final items = _pickBatch(cached.candidates, cached.algorithm, cached.batch);
      unawaited(_backfillWyCovers(items));
      return DailyRecommendState(
        items: items,
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
    final items = _pickBatch(candidates, algorithm, 0);
    unawaited(_backfillWyCovers(items));
    return DailyRecommendState(
      items: items,
      algorithm: algorithm,
      batch: 0,
    );
  }

  /// 网易云缺省封面的歌曲补齐（异步，不阻塞列表渲染，完成后再刷新）。
  ///
  /// 部分网易云 MusicFree 插件的搜索结果既无 picUrl 也无 duration，导致日推里
  /// 网易云歌曲无封面。这里只挑「缺封面 + 纯数字 ID + 来自网易云 musicfree 插件」
  /// 的条目，经官方 weapi song/detail 批量取回封面/时长，写入 `song['coverUrl']`
  ///（`resolveSongCoverUrl` 会读取它）后重新 emit，封面对齐桌面端。
  Future<void> _backfillWyCovers(List<DailyRecommendItem> items) async {
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final pluginSources = await engine.store.loadSources();
      final wyIds = <String>{
        for (final p in pluginSources)
          if (p.enabled && lxPlatformCodeOf(p) == 'wy') p.id,
      };
      if (wyIds.isEmpty) return;

      final pending = <DailyRecommendItem>[];
      final ids = <String>[];
      final seen = <String>{};
      for (final it in items) {
        if (it.pluginFormat != PluginFormat.musicfree.value) {
          continue;
        }
        if (!wyIds.contains(it.pluginId)) continue;
        final cover = it.coverUrl;
        if (cover != null && cover.isNotEmpty) continue;
        final id = _wySongId(it.song);
        if (id == null || !seen.add(id)) continue;
        pending.add(it);
        ids.add(id);
      }
      if (pending.isEmpty) return;

      final patches = await _fetchWyTrackMeta(ids);
      if (patches.isEmpty) return;

      var changed = false;
      for (final it in pending) {
        final id = _wySongId(it.song);
        if (id == null) continue;
        final p = patches[id];
        if (p == null) continue;
        if (p.coverUrl.isNotEmpty) {
          it.song['coverUrl'] = p.coverUrl;
          changed = true;
        }
        if (it.durationMs <= 0 && p.durationMs > 0) {
          it.song['durationMs'] = p.durationMs;
          it.song['dt'] = p.durationMs;
          final sec = p.durationMs ~/ 1000;
          it.song['interval'] =
              '${(sec ~/ 60).toString().padLeft(2, '0')}:${(sec % 60).toString().padLeft(2, '0')}';
          changed = true;
        }
      }
      if (!changed || state is! AsyncData) return;
      final cur = state.valueOrNull;
      if (cur == null) return;
      state = AsyncData(DailyRecommendState(
        items: cur.items,
        algorithm: cur.algorithm,
        batch: cur.batch,
        loggedIn: cur.loggedIn,
      ));
    } catch (_) {
      // 补齐失败不影响列表展示
    }
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
