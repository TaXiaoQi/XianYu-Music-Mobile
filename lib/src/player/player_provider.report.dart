part of 'player_provider.dart';

/// 播放统计上报服务：fire-and-forget 的历史落库、听歌时长记录与
/// 行为上报。由 PlayerNotifier 装配（见 [PlayerNotifier.statsReporter]）；
/// 播放状态的累计口径由 Notifier 类体内的 _flushPlayStats 维护，
/// 服务本身不触碰 StateNotifier.state（@protected）。
class PlayStatsReporter {
  PlayStatsReporter(this._ref);

  final Ref _ref;

  void recordHistory(QueueItem item) {
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await statsAddToHistory(dbPath: dbPath, songPath: item.path);
      } catch (e) {
        AppLog.warn('stats', 'add_to_history 失败: $e');
      }
    });
  }

  void recordPlayStats(
    QueueItem item,
    double listenedSecs, {
    bool countAsPlay = true,
    required int fallbackDurationMs,
  }) {
    if (listenedSecs <= 0) return;
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        final payloadJson = jsonEncode({
          'songPath': item.path,
          'listenedMs': (listenedSecs * 1000).toInt(),
          'durationMs': item.durationMs > 0
              ? item.durationMs
              : fallbackDurationMs,
          'title': item.title,
          'artist': item.artist,
          'album': item.album,
          'countAsPlay': countAsPlay,
        });
        await statsRecordPlay(dbPath: dbPath, payloadJson: payloadJson);
        _ref.invalidate(listenStatsProvider);
        _ref.invalidate(mostPlayedProvider);
      } catch (e) {
        AppLog.warn('stats', 'record_play_stats 失败: $e');
      }
    });
  }

  void reportBehavior(QueueItem item, String action, int listenDuration) {
    final hash = md5.convert(utf8.encode('${item.title}|${item.artist}|local')).toString();
    _ref.read(accountApiProvider).reportUserBehavior(
          songId: item.path,
          songName: item.title,
          singer: item.artist,
          songHash: hash,
          source: item.isOnline ? 'online' : 'local',
          action: action,
          listenDuration: listenDuration,
          playCount: 1,
        );
  }

  void recordRecentPlay(QueueItem item) {
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await statsAddToHistory(dbPath: dbPath, songPath: item.path);
        if (item.isOnline) {
          await _ref.read(onlineMetaStoreProvider).put(item);
        }
        _ref.invalidate(recentProvider);
      } catch (e) {
        AppLog.warn('stats', 'record_recent_play 失败: $e');
      }
    });
  }
}
