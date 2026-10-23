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

  // ---- Android Auto / MediaBrowser 浏览树 ----
  // root → 收藏 / 最近播放 / 歌单（二级） → 歌曲。歌曲 mediaId 与队列一致
  // （item.path），AA 点击播放经 playMediaItem 按目录上下文整单替换队列后
  // 定位播放。音频类车机端（AA/AudioBrowser 客户端）通用，HiCar 后续可复用。
  // 每目录列表上限 500 首：MediaBrowser 无分页，超大集合会拖慢车机端渲染。
  static const _browseFavorites = 'xy:favorites';
  static const _browseRecent = 'xy:recent';
  static const _browsePlaylists = 'xy:playlists';
  static const _browsePlaylistPrefix = 'xy:playlist:';
  static const _browseMaxChildren = 500;

  final Map<String, List<QueueItem>> _browseContexts = {};

  Ref? get _browseRef => _notifier?._ref;

  as_pkg.MediaItem _browseFolder(String mediaId, String title) {
    return as_pkg.MediaItem(
      id: mediaId,
      title: title,
      playable: false, // 0.18 原生侧以 playable 区分 BROWSABLE/PLAYABLE
    );
  }

  as_pkg.MediaItem _browseSong(QueueItem item) {
    return as_pkg.MediaItem(
      id: item.path,
      title: item.title,
      artist: item.artist.isEmpty ? null : item.artist,
      album: item.album.isEmpty ? null : item.album,
      duration: item.durationMs > 0
          ? Duration(milliseconds: item.durationMs)
          : null,
      artUri: _materializer.artUriFor(item),
      playable: true,
    );
  }

  Future<List<QueueItem>?> _resolveSongList(String mediaId, Ref ref) async {
    if (mediaId == _browseFavorites) {
      return [for (final e in ref.read(favoritesProvider).entries) e.toQueueItem()];
    }
    if (mediaId == _browseRecent) {
      return [
        for (final e in ref.read(recentProvider).entries)
          if (e.toQueueItem() != null) e.toQueueItem()!,
      ];
    }
    if (mediaId.startsWith(_browsePlaylistPrefix)) {
      final pid = mediaId.substring(_browsePlaylistPrefix.length);
      for (final p in ref.read(playlistManagerProvider).playlists) {
        if (p.id == pid) return [for (final s in p.songs) importedSongToQueueItem(s)];
      }
      return null;
    }
    return null;
  }

  @override
  Future<List<as_pkg.MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    final ref = _browseRef;
    if (ref == null) return const [];
    if (parentMediaId == 'root') {
      return [
        _browseFolder(_browseFavorites, tr('收藏')),
        _browseFolder(_browseRecent, tr('最近播放')),
        _browseFolder(_browsePlaylists, tr('歌单')),
      ];
    }
    if (parentMediaId == _browsePlaylists) {
      return [
        for (final p in ref.read(playlistManagerProvider).playlists)
          _browseFolder('$_browsePlaylistPrefix${p.id}', p.name),
      ];
    }
    final items = await _resolveSongList(parentMediaId, ref);
    if (items == null) return const [];
    final capped = items.length > _browseMaxChildren
        ? items.sublist(0, _browseMaxChildren)
        : items;
    _browseContexts[parentMediaId] = capped;
    return [for (final item in capped) _browseSong(item)];
  }

  @override
  Future<as_pkg.MediaItem?> getMediaItem(String mediaId) async {
    final ref = _browseRef;
    if (ref == null) return null;
    if (mediaId == _browseFavorites) return _browseFolder(mediaId, tr('收藏'));
    if (mediaId == _browseRecent) {
      return _browseFolder(mediaId, tr('最近播放'));
    }
    if (mediaId == _browsePlaylists) return _browseFolder(mediaId, tr('歌单'));
    if (mediaId.startsWith(_browsePlaylistPrefix)) {
      final pid = mediaId.substring(_browsePlaylistPrefix.length);
      for (final p in ref.read(playlistManagerProvider).playlists) {
        if (p.id == pid) return _browseFolder(mediaId, p.name);
      }
      return null;
    }
    for (final items in _browseContexts.values) {
      final idx = items.indexWhere((e) => e.path == mediaId);
      if (idx >= 0) return _browseSong(items[idx]);
    }
    return null;
  }

  @override
  Future<void> playMediaItem(as_pkg.MediaItem mediaItem) async {
    final ref = _browseRef;
    final notifier = _notifier;
    if (ref == null || notifier == null) return;
    final id = mediaItem.id;
    if (id.startsWith('xy:')) return; // 目录节点不可播
    // 命中已缓存的目录上下文 → 整单替换队列并定位播放（车机上下文 = 完整列表）
    for (final entry in _browseContexts.entries) {
      final idx = entry.value.indexWhere((e) => e.path == id);
      if (idx >= 0) {
        await notifier.playQueue(entry.value, startIndex: idx);
        return;
      }
    }
    // 缓存未命中（车机残留项 / 冷启动）：解析本地目录兜底
    for (final dir in const [_browseFavorites, _browseRecent]) {
      final items = await _resolveSongList(dir, ref);
      if (items == null) continue;
      final idx = items.indexWhere((e) => e.path == id);
      if (idx >= 0) {
        final capped = items.length > _browseMaxChildren
            ? items.sublist(0, _browseMaxChildren)
            : items;
        _browseContexts[dir] = capped;
        await notifier.playQueue(capped, startIndex: idx);
        return;
      }
    }
    // 不在任何本地目录：若恰好在当前队列则跳播，否则忽略
    final idx = notifier.state.queue.indexWhere((e) => e.path == id);
    if (idx >= 0) await notifier.playQueueItem(idx);
  }

  /// 蓝牙歌词：把当前歌词行写入 MediaSession 元数据标题，车机经蓝牙
  /// AVRCP 读取后即可在屏幕上滚动显示歌词（仅作用于 path 匹配的曲目，
  /// 切歌后自动失效回退真实标题，无需依赖监听顺序）。
  String? _bluetoothLyric;
  String? _bluetoothLyricPath;

  void setBluetoothLyric(String? line, {required String songPath}) {
    if (line == null) {
      if (_bluetoothLyricPath == songPath) _bluetoothLyricPath = null;
      _bluetoothLyric = null;
    } else {
      _bluetoothLyric = line;
      _bluetoothLyricPath = songPath;
    }
    final item = _lastSyncItem;
    if (item != null) {
      mediaItem.add(
        _buildMediaItem(item, _lastSyncDuration, _materializer.artUriFor(item)),
      );
    }
  }

  final CoverMaterializer _materializer = CoverMaterializer();

  as_pkg.MediaItem _buildMediaItem(
      QueueItem item, double durationSecs, Uri? artUri) {
    final lyricTitle =
        _bluetoothLyric != null && item.path == _bluetoothLyricPath
            ? _bluetoothLyric
            : null;
    return as_pkg.MediaItem(
      id: item.path,
      album: item.album.isEmpty ? tr('弦予音乐') : item.album,
      title: lyricTitle ?? item.title,
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
