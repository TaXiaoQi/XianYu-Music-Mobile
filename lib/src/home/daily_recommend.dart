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

class DailyRecommendItem {
  final Map<String, dynamic> song;
  final String reason;
  final String strategyId;
  final String pluginId;
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
  String? get coverUrl {
    final resolved = resolveSongCoverUrl(song);
    if (resolved != null && resolved.isNotEmpty) return resolved;
    return song['img'] as String?;
  }

  int get durationMs => _intervalToMs((song['interval'] as String?) ?? '');

  String? get dedupKey {
    final normTitle = _normalizeText(title);
    final normArtist = _normalizeText(_firstArtist(artist));
    if (normTitle.isEmpty || normArtist.isEmpty) return null;
    return '$normTitle|$normArtist';
  }

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
      source: isMf ? null : src,
      onlineInfoJson: isMf ? null : jsonEncode(song),
      fromDailyRecommend: true,
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

const _searchLimit = 20;
const _searchConcurrency = 4;
const _maxCandidates = 90;
const _minDurationMs = 45000;
const _cacheKey = 'daily_recommend_v3';

int _imul(int a, int b) => ((a * b) & 0xFFFFFFFF).toSigned(32);

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

String _normalizeText(String input) {
  var s = input.toLowerCase();
  s = s.replaceAll(RegExp(r'[（(【\[][^）)】\]]*[）)】\]]'), '');
  s = s.replaceAll(RegExp(r"[\s'’`·・~～!！?？.。,，、]"), '');
  return s.trim();
}

String _firstArtist(String artist) {
  final parts = artist.split(RegExp(r'[/、,&]'));
  return parts.isEmpty ? '' : parts.first.trim();
}

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

class _PluginSearchTask {
  final DailyRecommendStrategy strategy;
  final String query;
  final PluginSource plugin;
  const _PluginSearchTask(this.strategy, this.query, this.plugin);
}

typedef _Collected = ({DailyRecommendItem item, double score});

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
  final playable = <PluginSource>[];
  for (final p in enabledPlugins) {
    if (await engine.canPlayMusic(p)) playable.add(p);
  }
  String probeKeyword = '热门音乐';
  for (final s in algorithm.strategies) {
    if (s.queries.isNotEmpty) {
      probeKeyword = s.queries.first;
      break;
    }
  }
  final probes = await Future.wait(
      playable.map((p) => _probePluginAlive(engine, p, probeKeyword)));
  final alivePlugins = <PluginSource>[
    for (var i = 0; i < playable.length; i++)
      if (probes[i]) playable[i],
  ];
  final collected = <_Collected>[];
  if (alivePlugins.isEmpty) return const [];
  await _searchAll(engine, algorithm, alivePlugins, exclusionSet, collected);

  final best = <String, _Collected>{};
  for (final c in collected) {
    final key = c.item.dedupKey;
    if (key == null) continue;
    final prev = best[key];
    if (prev == null || c.score > prev.score) best[key] = c;
  }

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
      }
    }
  }

  final workerCount = math.min(_searchConcurrency, tasks.length);
  await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
}

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
    }
  }
  return merged;
}

const Duration _aliveProbeTtl = Duration(minutes: 15);
const Duration _aliveProbeTimeout = Duration(seconds: 4);
final Map<String, ({bool alive, DateTime at})> _aliveProbes = {};

Future<bool> _probePluginAlive(
    PluginEngine engine, PluginSource p, String keyword) async {
  final cached = _aliveProbes[p.id];
  if (cached != null && DateTime.now().difference(cached.at) < _aliveProbeTtl) {
    return cached.alive;
  }
  bool alive = false;
  try {
    if (!await engine.canPlayMusic(p)) throw StateError('not playable');
    final hits = await _probeSearchOne(engine, p, keyword)
        .timeout(_aliveProbeTimeout);
    if (hits.isEmpty) {
      alive = true;
    } else if (p.format == PluginFormat.lx) {
      final first = hits.first;
      final lxSource = first.source.isNotEmpty ? first.source : 'kw';
      final songInfo = first.rawData is Map<String, dynamic>
          ? Map<String, dynamic>.from(first.rawData as Map)
          : first.toJson();
      final r = await engine
          .getMusicUrl(p, lxSource, songInfo, '128k')
          .timeout(_aliveProbeTimeout);
      alive = r != null && (r['url'] as String?)?.isNotEmpty == true;
    } else {
      final r = await engine
          .getMusicFreeUrl(p, Map<String, dynamic>.from(hits.first.toJson()),
              preferred: 'low', fallback: 'pause')
          .timeout(_aliveProbeTimeout);
      alive = r != null && r.url.isNotEmpty;
    }
  } catch (_) {
    alive = false;
  }
  _aliveProbes[p.id] = (alive: alive, at: DateTime.now());
  return alive;
}

Future<List<PluginSearchResult>> _probeSearchOne(
    PluginEngine engine, PluginSource p, String keyword) async {
  if (p.format == PluginFormat.musicfree) {
    return PluginCatalogService(engine, [p]).searchMusic(p, keyword, limit: 1);
  }
  for (final key in (p.sources.isEmpty ? <String>['default'] : p.sources)) {
    try {
      final r = await engine.searchInPlugin(p, key, keyword, limit: 1);
      if (r.isNotEmpty) return r;
    } catch (_) {
    }
  }
  return const [];
}

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

bool _accept(DailyRecommendItem item,
    {required int durationMs, required Set<String> exclusionSet}) {
  if (item.title.isEmpty || item.artist.isEmpty) return false;
  if (durationMs > 0 && durationMs < _minDurationMs) return false;
  final key = item.dedupKey;
  if (key == null) return false;
  if (exclusionSet.contains(key)) return false;
  return true;
}

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
  }
}

Future<void> clearDailyRecommendCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
  } catch (_) {}
}

String? _wySongId(Map<String, dynamic> song) {
  final id = (song['songmid'] ?? song['songId'] ?? song['id'] ?? '').toString().trim();
  if (RegExp(r'^\d+$').hasMatch(id) && id != '0') return id;
  return null;
}

typedef _WyTrackPatch = ({String coverUrl, int durationMs});

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
  } finally {
    client?.close();
  }
  return result;
}

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

    final pluginSources = ref.watch(pluginManagerProvider).sources;
    if (!pluginSources.any((s) => s.enabled)) {
      return const DailyRecommendState(items: []);
    }

    final data = await ref
        .read(authProvider.notifier)
        .requestAction('get_daily_recommend', {'ciyuanxi_id': ciyuanxiId});
    final algorithm = DailyRecommendAlgorithm.fromJson(data);
    final engine = await ref.read(pluginEngineProvider.future);
    final candidates = await _executeAlgorithm(algorithm, engine, pluginSources);
    if (candidates.isNotEmpty) {
      await _saveCache(_DailyCache(
        ciyuanxiId: ciyuanxiId,
        date: today,
        batch: 0,
        algorithm: algorithm,
        candidates: candidates,
      ));
    }
    final items = _pickBatch(candidates, algorithm, 0);
    unawaited(_backfillWyCovers(items));
    return DailyRecommendState(
      items: items,
      algorithm: algorithm,
      batch: 0,
    );
  }

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
    }
  }

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

Future<void> reportDailyLikeSignals(
  AuthNotifier auth,
  String ciyuanxiId, {
  required String signalType,
  required List<({String songName, String singer})> songs,
}) async {
  if (ciyuanxiId.isEmpty) return;
  final payload = [
    for (final s in songs)
      if (s.songName.trim().isNotEmpty)
        {'song_name': s.songName.trim(), 'singer': s.singer.trim()},
  ];
  if (payload.isEmpty) return;
  try {
    await auth.requestAction('report_daily_like', {
      'ciyuanxi_id': ciyuanxiId,
      'signal_type': signalType,
      'songs': payload,
    });
  } catch (_) {
  }
}
