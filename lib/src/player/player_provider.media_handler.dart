part of 'player_provider.dart';

class XianYuAudioHandler extends as_pkg.BaseAudioHandler with as_pkg.SeekHandler {
  PlayerNotifier? _notifier;

  void bindNotifier(PlayerNotifier notifier) {
    _notifier = notifier;
  }

  void syncMediaItem(QueueItem item, double durationSecs) {
    _lastSyncItem = item;
    _lastSyncDuration = durationSecs;
    mediaItem.add(
      _buildMediaItem(item, durationSecs, _materializer.artUriFor(item)),
    );
    unawaited(
      _materializer.materializeOnlineArt(item).then((path) {
        if (path != null && _lastSyncItem?.path == item.path) {
          mediaItem.add(
            _buildMediaItem(item, _lastSyncDuration, Uri.file(path)),
          );
        }
      }),
    );
  }

  void syncQueue(List<QueueItem> items, Map<String, String> artCache) {
    queue.add([
      for (final item in items)
        _buildMediaItem(
          item,
          _lastSyncItem?.path == item.path ? _lastSyncDuration : 0,
          _materializer.artUriForWithCache(item, artCache),
        ),
    ]);
  }

  QueueItem? _lastSyncItem;
  double _lastSyncDuration = 0;

  final CoverMaterializer _materializer = CoverMaterializer();

  as_pkg.MediaItem _buildMediaItem(
      QueueItem item, double durationSecs, Uri? artUri) {
    return as_pkg.MediaItem(
      id: item.path,
      album: item.album.isEmpty ? tr('弦予音乐') : item.album,
      title: item.title,
      artist: item.artist.isEmpty ? tr('未知歌手') : item.artist,
      duration:
          durationSecs > 0 ? Duration(milliseconds: (durationSecs * 1000).round()) : null,
      artUri: artUri,
    );
  }

  void syncPlaybackState({
    required bool isPlaying,
    required double positionSecs,
    required double durationSecs,
    required bool isFavorite,
    required int playMode,
    int? queueIndex,
  }) {
    playbackState.add(
      as_pkg.PlaybackState(
        controls: [
          as_pkg.MediaControl.skipToPrevious,
          if (isPlaying) as_pkg.MediaControl.pause else as_pkg.MediaControl.play,
          as_pkg.MediaControl.skipToNext,
          as_pkg.MediaControl(
            androidIcon: isFavorite
                ? 'drawable/ic_notif_favorite_filled'
                : 'drawable/ic_notif_favorite',
            label: isFavorite ? tr('取消收藏') : tr('收藏'),
            action: as_pkg.MediaAction.custom,
            customAction: const as_pkg.CustomMediaAction(name: 'toggleFavorite'),
          ),
          as_pkg.MediaControl(
            androidIcon: _playModeIcon(playMode),
            label: _playModeLabel(playMode),
            action: as_pkg.MediaAction.custom,
            customAction: const as_pkg.CustomMediaAction(name: 'cyclePlayMode'),
          ),
        ],
        systemActions: const {
          as_pkg.MediaAction.seek,
          as_pkg.MediaAction.seekForward,
          as_pkg.MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: as_pkg.AudioProcessingState.ready,
        playing: isPlaying,
        updatePosition: Duration(milliseconds: (positionSecs * 1000).round()),
        bufferedPosition: Duration(milliseconds: (positionSecs * 1000).round()),
        speed: 1.0,
        queueIndex: queueIndex,
      ),
    );
  }

  String _playModeIcon(int mode) => switch (mode) {
        1 => 'drawable/ic_notif_mode_repeat_one',
        2 => 'drawable/ic_notif_mode_shuffle',
        _ => 'drawable/ic_notif_mode_repeat',
      };

  String _playModeLabel(int mode) => switch (mode) {
        1 => tr('单曲循环'),
        2 => tr('随机播放'),
        _ => tr('列表循环'),
      };

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'toggleFavorite':
        await _notifier?.toggleFavoriteFromSystem();
      case 'cyclePlayMode':
        await _notifier?.cyclePlayMode();
    }
  }

  @override
  Future<void> play() => _notifier?.resumeFromSystem() ?? Future.value();

  @override
  Future<void> pause() =>
      _notifier?.pauseFromSystem(origin: 'mediasession.pause') ??
      Future.value();

  @override
  Future<void> skipToNext() => _notifier?.next() ?? Future.value();

  @override
  Future<void> skipToPrevious() => _notifier?.previous() ?? Future.value();

  @override
  Future<void> seek(Duration position) =>
      _notifier?.seek(position.inMilliseconds / 1000.0) ?? Future.value();

  @override
  Future<void> stop() =>
      _notifier?.pauseFromSystem(origin: 'mediasession.stop') ??
      Future.value();

  @override
  Future<void> onTaskRemoved() async {
    // 划掉多任务 = 彻底退出进程。暂停只是收尾动作（保存会话/统计），
    // 绝不能挡住 exit(0)：toggle 里 await _player.pause() 若撞上
    // ExoPlayer 主线程楔死（本项目有先例，见 xianyu/diag 楔死探测）
    // 或任何一环抛异常，进程就永远退不出去，表现为"划掉还在播"。
    // 因此 try/catch 全包 + 2 秒超时，无论暂停成败，退出必达。
    try {
      await _notifier
          ?.pauseFromSystem(origin: 'mediasession.taskRemoved')
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      AppLog.warn('playgate', 'taskRemoved 收尾异常(忽略): $e');
    }
    try {
      await super.stop();
    } catch (_) {}
    exit(0);
  }
}
