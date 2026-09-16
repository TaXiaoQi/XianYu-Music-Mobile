import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
import '../core/db_path.dart';
import '../library/library_provider.dart';
import '../rust/api.dart';
import '../i18n/i18n.dart';

/// 听过最多的单曲（本地曲库内，按播放次数倒序）。
class MostPlayedEntry {
  final Song song;
  final int playCount;
  const MostPlayedEntry({required this.song, required this.playCount});
}

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
  final entries = <MostPlayedEntry>[];
  for (final e in top) {
    final m = e as Map<String, dynamic>;
    final path = m['song_path'] as String? ?? '';
    final song = songsByPath[path];
    if (song == null) continue;
    entries.add(MostPlayedEntry(
      song: song,
      playCount: (m['play_count'] as num?)?.toInt() ?? 0,
    ));
  }
  return entries;
});

/// 首页统计数据：听歌总时长、今天听歌时长/听歌首数。
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
      return '$hours 小时 $mins 分钟';
    }
    return '$mins 分钟';
  }
}

/// 云端听歌统计快照（多端真源，秒）。登录后由后台 delta 上报回传填充。
class ListenServerSnapshot {
  final int total;
  final int daily;
  final int weekly;
  const ListenServerSnapshot({required this.total, required this.daily, required this.weekly});
}

/// 服务端快照 Provider（账号页/统计卡显示基准）。
final listenServerSnapshotProvider = StateProvider<ListenServerSnapshot?>((ref) => null);

/// 上次 report_listen_stats 上报时间（毫秒）。播放落库/切页都会触发
/// listenStatsProvider 重算，30s 节流避免频繁上报（对齐桌面端 REPORT_THROTTLE_MS）。
int _lastListenReportAt = 0;

/// delta 上报基线持久化键：上次成功上报时的本地累计 {total, daily, date}。
const _listenBaselineKey = 'listen_report_baseline_v2';
/// 服务端快照持久化键（登录态显示基准，重启后立即有值）。
const _listenSnapshotKey = 'listen_server_snapshot_v2';

Future<void> _persistJson(String key, Map<String, dynamic> data) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(data));
  } catch (_) {}
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

  // 1. 取日/周/总听歌时长（秒）+ 今日听歌首数（本地快速查询）
  try {
    final durationsJson = await statsGetListenDurations(dbPath: dbPath);
    final dj = jsonDecode(durationsJson) as Map<String, dynamic>;
    totalSecs = (dj['total'] as num?)?.toInt() ?? 0;
    todaySecs = (dj['daily'] as num?)?.toInt() ?? 0;
    todayCount = (dj['today_play_count'] as num?)?.toInt() ?? 0;
  } catch (_) {}

  // 2. 登录账号：后台 delta 增量上报（不阻塞本地展示）。
  //    统一协议 stats_mode=delta：只上报自上次成功上报后的增量，服务端合计为
  //    唯一真源并回传账号累计/今日/本周快照；本地统计不再被云端回写（旧
  //    GREATEST/快照合并废弃），显示 = 服务端快照 + 本端未上报增量。
  final auth = ref.watch(authProvider);
  ListenServerSnapshot? snapshot;
  int pendingTotal = 0;
  int pendingDaily = 0;
  if (auth.isLoggedIn) {
    // 先展示上次持久化的服务端快照（重启后立即有多端一致值）。
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

        // 计算增量：本地累计 - 已上报基线（跨天时 daily 基线清零）。
        final baseline = await _loadJson(_listenBaselineKey) ?? const {};
        final today = _todayStr();
        final baseTotal = (baseline['total'] as num?)?.toInt() ?? 0;
        var baseDaily = (baseline['daily'] as num?)?.toInt() ?? 0;
        final baseDate = baseline['date'] as String? ?? today;
        if (baseDate != today) baseDaily = 0;
        final deltaTotal = (totalSecs - baseTotal).clamp(0, 1 << 31);
        final deltaDaily = (todaySecs - baseDaily).clamp(0, 1 << 31);

        final resp = await api.reportListenStatsDelta(
          deltaTotal: deltaTotal,
          deltaDaily: deltaDaily,
        );

        if (resp['resetAt'] != null) {
          // 服务端重置：清本地统计、基线与快照，从零重新累计。
          try {
            await statsClearListenStats(dbPath: dbPath);
          } catch (_) {}
          await _persistJson(_listenBaselineKey,
              {'total': 0, 'daily': 0, 'date': _todayStr()});
          await _persistJson(_listenSnapshotKey,
              {'total': 0, 'daily': 0, 'weekly': 0});
          ref.read(listenServerSnapshotProvider.notifier).state =
              const ListenServerSnapshot(total: 0, daily: 0, weekly: 0);
        } else if (resp.isNotEmpty) {
          // 成功：基线推进到当前本地累计，保存服务端快照。
          await _persistJson(_listenBaselineKey,
              {'total': totalSecs, 'daily': todaySecs, 'date': today});
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
        // 网络失败时沿用本地数据。
      }
    });
  }

  // 3. 显示值 = 服务端快照 + 本端未上报增量（多端一致且实时）；
  //    未登录 / 从未同步过时回退本地累计。
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
