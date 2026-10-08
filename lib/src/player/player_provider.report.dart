part of 'player_provider.dart';

/// 播放统计上报服务：fire-and-forget 的历史落库、听歌时长记录与
/// 行为上报。由 PlayerNotifier 装配（见 [PlayerNotifier.statsReporter]）；
/// 听歌时长的累计口径由本类维护（见 [flush]）；服务本身不触碰
/// StateNotifier.state（@protected）。
class PlayStatsReporter {
  PlayStatsReporter(this._ref);

  final Ref _ref;

  // ---- 听歌时长累计口径（服务端快照 + 本地会话增量）----
  double _lastStatPos = -1;
  DateTime? _trackStartTime;
  double _accumulatedTime = 0;
  bool _currentPlayCountRecorded = false;

  // ---- 云端事件流水（v2）：60 秒聚合一个幂等事件 ----
  double _eventAccum = 0;
  static const double _eventThresholdSecs = 60;

  /// 曲目开始/恢复播放时打点。
  void noteTrackStart() {
    _trackStartTime = DateTime.now();
  }

  /// 切曲且不复用统计会话时清零累计口径。
  void resetCounters() {
    _currentPlayCountRecorded = false;
    _accumulatedTime = 0;
    _eventAccum = 0; // 不足 60 秒的余额丢弃——宁可少报，绝不重报
  }

  /// 听歌时长累计口径：服务端快照 + 本地会话增量；达到阈值即落库。
  /// 由 Notifier 的周期计时与暂停/切曲时机调用（原 PlayerNotifier._flushPlayStats）。
  void flush(PlaybackState state) {
    final item = state.current;
    if (item == null) return;
    double currentSession = 0;
    final pos = state.position;
    if (_trackStartTime != null && state.isPlaying && pos > 0) {
      final delta = _lastStatPos >= 0 ? pos - _lastStatPos : 0.0;
      if (delta > 0) {
        final wallSec =
            DateTime.now().difference(_trackStartTime!).inMilliseconds / 1000.0;
        if (delta <= wallSec + 2) currentSession = delta;
      }
    }
    _lastStatPos = pos;
    final totalDuration = _accumulatedTime + currentSession;
    final shouldPersist =
        totalDuration >= 10 || (_currentPlayCountRecorded && totalDuration > 0);

    if (shouldPersist) {
      final countAsPlay = !_currentPlayCountRecorded;
      if (countAsPlay) _currentPlayCountRecorded = true;
      recordPlayStats(
        item,
        totalDuration,
        countAsPlay: countAsPlay,
        fallbackDurationMs: (state.duration * 1000).toInt(),
      );
      _accumulatedTime = 0;
    } else {
      _accumulatedTime = totalDuration;
    }
    // 云端事件流水：与本地落库同源（currentSession = 本次确认真实听到的
    // 秒数），60 秒聚合一个幂等事件入队；队列由同步器节流批量上报，
    // 失败保留重试。切曲时不足 60 秒的余额丢弃——宁可少报，绝不重报。
    _eventAccum += currentSession;
    if (_eventAccum >= _eventThresholdSecs) {
      final secs = _eventAccum.floor();
      _eventAccum -= secs;
      _ref.read(listenStatsSyncProvider.notifier).enqueue(secs);
    }
    _trackStartTime = state.isPlaying ? DateTime.now() : null;
  }

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
