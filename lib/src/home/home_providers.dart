import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
import '../core/db_path.dart';
import '../library/library_provider.dart';
import '../rust/api.dart';
import '../i18n/i18n.dart';

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

  try {
    final durationsJson = await statsGetListenDurations(dbPath: dbPath);
    final dj = jsonDecode(durationsJson) as Map<String, dynamic>;
    totalSecs = (dj['total'] as num?)?.toInt() ?? 0;
    todaySecs = (dj['daily'] as num?)?.toInt() ?? 0;
    todayCount = (dj['today_play_count'] as num?)?.toInt() ?? 0;
  } catch (_) {}

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
        if (baseDate != today) baseDaily = 0;
        final deltaTotal = (totalSecs - baseTotal).clamp(0, 1 << 31);
        final deltaDaily = (todaySecs - baseDaily).clamp(0, 1 << 31);

        final resp = await api.reportListenStatsDelta(
          deltaTotal: deltaTotal,
          deltaDaily: deltaDaily,
        );

        if (resp['resetAt'] != null) {
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
