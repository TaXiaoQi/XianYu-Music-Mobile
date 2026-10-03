import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
import '../core/application_logger.dart';
import '../core/db_path.dart';
import '../library/library_provider.dart';
import '../online/online_meta_store.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';
import '../i18n/i18n.dart';

class MostPlayedEntry {
  final Song? song;
  final QueueItem? onlineItem;
  final int playCount;
  const MostPlayedEntry({this.song, this.onlineItem, required this.playCount});

  QueueItem? toQueueItem() => song?.toQueueItem() ?? onlineItem;
}

bool isOnlineSongPath(String p) =>
    p.startsWith('lx://') || p.startsWith('plugin://');

final mostPlayedProvider = FutureProvider<List<MostPlayedEntry>>((ref) async {
  final dbPath = await ref.read(dbPathProvider.future);
  final json = await statsGetBehaviorStats(
    dbPath: dbPath,
    timeRangeJson: '{"type":"All"}',
  );
  final j = jsonDecode(json) as Map<String, dynamic>;
  final top = (j['top_songs'] as List? ?? const []);
  final songsByPath = {
    for (final s in ref.watch(libraryProvider.select((st) => st.songs)))
      s.path: s,
  };
  final onlinePaths = [
    for (final e in top)
      if (isOnlineSongPath(
          (e as Map<String, dynamic>)['song_path'] as String? ?? ''))
        e['song_path'] as String,
  ];
  final onlineMeta = onlinePaths.isEmpty
      ? const <String, QueueItem>{}
      : await ref.read(onlineMetaStoreProvider).getAll(onlinePaths);
  final entries = <MostPlayedEntry>[];
  for (final e in top) {
    final m = e as Map<String, dynamic>;
    final path = m['song_path'] as String? ?? '';
    final song = songsByPath[path];
    if (song != null) {
      entries.add(MostPlayedEntry(
        song: song,
        playCount: (m['play_count'] as num?)?.toInt() ?? 0,
      ));
      continue;
    }
    if (isOnlineSongPath(path)) {
      final item = onlineMeta[path];
      if (item != null) {
        entries.add(MostPlayedEntry(
          onlineItem: item,
          playCount: (m['play_count'] as num?)?.toInt() ?? 0,
        ));
      }
    }
  }
  return entries;
});

class ListenStatsData {
  final int totalSeconds;
  final int todaySeconds;
  final int todayPlayCount;

  const ListenStatsData({
    this.totalSeconds = 0,
    this.todaySeconds = 0,
    this.todayPlayCount = 0,
  });

  String get totalDurationText => _formatDuration(totalSeconds);
  String get todayDurationText => _formatDuration(todaySeconds);

  static String _formatDuration(int seconds) {
    if (seconds <= 0) return tr('0 分钟');
    final hours = seconds ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    if (hours > 0) {
      // 累计值会长成「21 小时 14 分钟」九个字，挤在三等分的一列里会把
      // 另外两列压窄；十小时以上收成小数小时（21.2 小时），精度够用也更整齐。
      if (hours >= 10) {
        final h = seconds / 3600;
        final text = h.toStringAsFixed(1);
        return '${text.endsWith('.0') ? h.toStringAsFixed(0) : text} 小时';
      }
      return '$hours 小时 $mins 分';
    }
    return '$mins 分钟';
  }
}

class ListenServerSnapshot {
  final int total;
  final int daily;
  final int weekly;
  const ListenServerSnapshot({required this.total, required this.daily, required this.weekly});
}

final listenServerSnapshotProvider = StateProvider<ListenServerSnapshot?>((ref) => null);

int _lastListenReportAt = 0;

const _listenBaselineKey = 'listen_report_baseline_v2';
const _listenSnapshotKey = 'listen_server_snapshot_v2';

Future<void> _persistJson(String key, Map<String, dynamic> data) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(data));
  } catch (e) {
    AppLog.debug('home', '写入统计缓存失败: $e');
  }
}

Future<Map<String, dynamic>?> _loadJson(String key) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

String _todayStr() {
  final d = DateTime.now();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

final FutureProvider<ListenStatsData> listenStatsProvider =
    FutureProvider<ListenStatsData>((ref) async {
  final dbPath = await ref.read(dbPathProvider.future);

  int totalSecs = 0;
  int todaySecs = 0;
  int todayCount = 0;

  try {
    final durationsJson = await statsGetListenDurations(dbPath: dbPath);
    final dj = jsonDecode(durationsJson) as Map<String, dynamic>;
    totalSecs = (dj['total'] as num?)?.toInt() ?? 0;
    todaySecs = (dj['daily'] as num?)?.toInt() ?? 0;
    todayCount = (dj['today_play_count'] as num?)?.toInt() ?? 0;
  } catch (e) {
    AppLog.warn('home', '读取本地听歌统计失败: $e');
  }

  final auth = ref.watch(authProvider);
  ListenServerSnapshot? snapshot;
  int pendingTotal = 0;
  int pendingDaily = 0;
  if (auth.isLoggedIn) {
    final cached = await _loadJson(_listenSnapshotKey);
    if (cached != null) {
      snapshot = ListenServerSnapshot(
        total: (cached['total'] as num?)?.toInt() ?? 0,
        daily: (cached['daily'] as num?)?.toInt() ?? 0,
        weekly: (cached['weekly'] as num?)?.toInt() ?? 0,
      );
      ref.read(listenServerSnapshotProvider.notifier).state = snapshot;
    }

    Future(() async {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastListenReportAt < 30000) return;
      _lastListenReportAt = now;
      try {
        final api = ref.read(accountApiProvider);

        final baseline = await _loadJson(_listenBaselineKey) ?? const {};
        final today = _todayStr();
        final baseTotal = (baseline['total'] as num?)?.toInt() ?? 0;
        var baseDaily = (baseline['daily'] as num?)?.toInt() ?? 0;
        final baseDate = baseline['date'] as String? ?? today;
        final reportedAt = (baseline['reported_at'] as num?)?.toInt() ?? 0;
        if (baseDate != today) baseDaily = 0;
        var deltaTotal = (totalSecs - baseTotal).clamp(0, 1 << 31);
        var deltaDaily = (todaySecs - baseDaily).clamp(0, deltaTotal);

        // 防全量重报护栏：baseline 丢失/重置时 delta 会等于本地全部历史累计。
        // 单次上报物理上限 = 自上次成功上报以来的墙钟时间 × 3 + 10 分钟（倍速与
        // 时钟误差余量；首次无时间戳给 10 分钟兜底，与服务端首报上限一致），
        // 超限截断，baseline 只推进已上报部分，剩余留给后续上报分批追平——宁可少报，绝不重报。
        final elapsedSecs = reportedAt > 0
            ? ((now - reportedAt) / 1000).floor().clamp(0, 30 * 86400).toInt()
            : 0;
        final maxDelta = reportedAt > 0 ? elapsedSecs * 3 + 600 : 600;
        if (deltaTotal > maxDelta) deltaTotal = maxDelta;
        if (deltaDaily > deltaTotal) deltaDaily = deltaTotal;

        final resp = await api.reportListenStatsDelta(
          deltaTotal: deltaTotal,
          deltaDaily: deltaDaily,
          elapsedSecs: reportedAt > 0 ? elapsedSecs : -1,
        );

        if (resp['resetAt'] != null) {
          try {
            await statsClearListenStats(dbPath: dbPath);
          } catch (e) {
            AppLog.debug('home', '清空本地听歌统计失败: $e');
          }
          await _persistJson(_listenBaselineKey,
              {'total': 0, 'daily': 0, 'date': _todayStr()});
          await _persistJson(_listenSnapshotKey,
              {'total': 0, 'daily': 0, 'weekly': 0});
          ref.read(listenServerSnapshotProvider.notifier).state =
              const ListenServerSnapshot(total: 0, daily: 0, weekly: 0);
        } else if (resp.isNotEmpty) {
          // 响应回执对账：服务端确认量 = 回执总量 − 上次快照总量，两方对上账
          // 才推进 baseline；服务端截断/异常时只推进确认部分，剩余留本地追报
          final prevSnap = await _loadJson(_listenSnapshotKey);
          final prevTotal = (prevSnap?['total'] as num?)?.toInt() ?? 0;
          final respTotal = (resp['total'] as num?)?.toInt() ?? 0;
          final serverDelta = respTotal - prevTotal;
          final confirmedTotal = serverDelta >= 0 && serverDelta < deltaTotal
              ? serverDelta
              : deltaTotal;
          final confirmedDaily = deltaDaily < confirmedTotal ? deltaDaily : confirmedTotal;
          // 只推进已上报的部分：截断场景下剩余 delta 留在本地，下次继续追
          await _persistJson(_listenBaselineKey, {
            'total': baseTotal + confirmedTotal,
            'daily': baseDaily + confirmedDaily,
            'date': today,
            'reported_at': now,
          });
          final snap = ListenServerSnapshot(
            total: (resp['total'] as num?)?.toInt() ?? 0,
            daily: (resp['daily'] as num?)?.toInt() ?? 0,
            weekly: (resp['weekly'] as num?)?.toInt() ?? 0,
          );
          await _persistJson(_listenSnapshotKey, {
            'total': snap.total,
            'daily': snap.daily,
            'weekly': snap.weekly,
          });
          ref.read(listenServerSnapshotProvider.notifier).state = snap;
        }
        ref.invalidate(listenStatsProvider);
      } catch (_) {
        // 上报失败（超时/网络抖动）时快照会停留在旧值，个人中心退化为纯本地口径，
        // 与排行榜（服务端真值）脱节。空 delta 上报 = 服务端纯快照拉取
        // （report_listen_stats 对全 0 delta 直接回执快照），把快照追平。
        try {
          await Future<void>.delayed(const Duration(seconds: 2));
          final resp = await ref
              .read(accountApiProvider)
              .reportListenStatsDelta(deltaTotal: 0, deltaDaily: 0);
          if (resp.isEmpty || resp['resetAt'] != null) return;
          final snap = ListenServerSnapshot(
            total: (resp['total'] as num?)?.toInt() ?? 0,
            daily: (resp['daily'] as num?)?.toInt() ?? 0,
            weekly: (resp['weekly'] as num?)?.toInt() ?? 0,
          );
          if (snap.total <= 0 && snap.daily <= 0) return;
          await _persistJson(_listenSnapshotKey,
              {'total': snap.total, 'daily': snap.daily, 'weekly': snap.weekly});
          ref.read(listenServerSnapshotProvider.notifier).state = snap;
          ref.invalidate(listenStatsProvider);
        } catch (e) {
          AppLog.debug('home', '服务端快照兜底拉取失败: $e');
        }
      }
    });
  }

  if (snapshot != null) {
    final baseline = await _loadJson(_listenBaselineKey) ?? const {};
    final baseTotal = (baseline['total'] as num?)?.toInt() ?? 0;
    var baseDaily = (baseline['daily'] as num?)?.toInt() ?? 0;
    if ((baseline['date'] as String? ?? _todayStr()) != _todayStr()) baseDaily = 0;
    pendingTotal = (totalSecs - baseTotal).clamp(0, 1 << 31);
    pendingDaily = (todaySecs - baseDaily).clamp(0, 1 << 31);
    totalSecs = snapshot.total + pendingTotal;
    todaySecs = snapshot.daily + pendingDaily;
  }

  return ListenStatsData(
    totalSeconds: totalSecs,
    todaySeconds: todaySecs,
    todayPlayCount: todayCount,
  );
});
