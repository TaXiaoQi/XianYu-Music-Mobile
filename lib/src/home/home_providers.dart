import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// 云端累计听歌总时长（秒），登录后由后台同步填充（跨端同步，不阻塞本地展示）。
final serverTotalDurationProvider = StateProvider<int>((ref) => 0);

final listenStatsProvider = FutureProvider<ListenStatsData>((ref) async {
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

  // 2. 登录账号：后台上报并拉取云端累计总时长（不阻塞本地展示）。
  //    服务端按 MAX 合并，实现桌面端/移动端跨端同步；今日时长/首数保持本地。
  final auth = ref.watch(authProvider);
  if (auth.isLoggedIn) {
    Future(() async {
      try {
        final api = ref.read(accountApiProvider);
        await api.reportListenStats({
          'total': totalSecs,
          'daily': todaySecs,
        });
        final server = await api.fetchListenStats();
        final serverTotal = (server['total_duration'] as num?)?.toInt() ?? 0;
        if (serverTotal > 0) {
          ref.read(serverTotalDurationProvider.notifier).state = serverTotal;
        }
      } catch (_) {
        // 网络失败时沿用本地数据。
      }
    });
  }

  // 3. 合并已同步的云端累计总时长（仅登录态、云端更长时覆盖本地）。
  final serverTotal = auth.isLoggedIn ? ref.watch(serverTotalDurationProvider) : 0;
  if (serverTotal > totalSecs) totalSecs = serverTotal;

  return ListenStatsData(
    totalSeconds: totalSecs,
    todaySeconds: todaySecs,
    todayPlayCount: todayCount,
  );
});
