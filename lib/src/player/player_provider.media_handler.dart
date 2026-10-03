part of 'player_provider.dart';

class XianYuAudioHandler extends as_pkg.BaseAudioHandler with as_pkg.SeekHandler {
  PlayerNotifier? _notifier;

  void bindNotifier(PlayerNotifier notifier) {
    _notifier = notifier;
  }

  void syncMediaItem(QueueItem item, double durationSecs) {
    _lastSyncItem = item;
    _lastSyncDuration = durationSecs;
    mediaItem.add(_buildMediaItem(item, durationSecs, _artUriFor(item)));
    unawaited(_materializeOnlineArt(item));
  }

  void syncQueue(List<QueueItem> items, Map<String, String> artCache) {
    queue.add([
      for (final item in items)
        _buildMediaItem(
          item,
          _lastSyncItem?.path == item.path ? _lastSyncDuration : 0,
          _artUriForWithCache(item, artCache),
        ),
    ]);
  }

  Uri? _artUriForWithCache(QueueItem item, Map<String, String> artCache) {
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) {
      final cached = artCache[url];
      if (cached != null && File(cached).existsSync()) return Uri.file(cached);
      final art = _artFileCache[url];
      if (art != null && File(art).existsSync()) return Uri.file(art);
      // 需代理的 CDN 不交 http URL：避免直连低清图与高清物化结果竞态。
      if (!CoverProxy.needsProxy(url)) return Uri.tryParse(url);
      return null;
    }
    final local = item.coverPath;
    if (local != null &&
        local.isNotEmpty &&
        !local.startsWith('http') &&
        File(local).existsSync()) {
      return Uri.file(local);
    }
    return null;
  }

  QueueItem? _lastSyncItem;
  double _lastSyncDuration = 0;

  final Map<String, String> _artFileCache = {};
  final Set<String> _artMaterializing = {};

  Uri? _artUriFor(QueueItem item) {
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) {
      final cached = _artFileCache[url];
      if (cached != null) {
        if (File(cached).existsSync()) return Uri.file(cached);
        _artFileCache.remove(url);
      }
      // 需代理的 CDN 不交 http URL：系统直连下载既无 Referer 易 403，
      // 又可能与随后落盘的高清封面竞态（低清结果后到会覆盖通知）。
      if (!CoverProxy.needsProxy(url)) return Uri.tryParse(url);
      return null;
    }
    final local = item.coverPath;
    if (local != null &&
        local.isNotEmpty &&
        !local.startsWith('http') &&
        File(local).existsSync()) {
      return Uri.file(local);
    }
    return null;
  }

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

  /// 把常见 CDN 的缩略图 URL 升级为高清候选；认不出的规则返回 null
  /// （视为已是原图）。只做可安全升级的替换，失败由调用方回退原 URL。
  String? _hdCoverUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host;
    // 网易云：?param=200y200 → 1024y1024（官方图片服务参数，超原图上限自动适配）
    if (host.endsWith('126.net') || host.endsWith('163.com')) {
      final param = uri.queryParameters['param'];
      if (param != null && RegExp(r'^\d+y\d+$').hasMatch(param)) {
        return uri
            .replace(queryParameters: <String, String>{
              ...uri.queryParameters,
              'param': '1024y1024',
            })
            .toString();
      }
      return null;
    }
    // 酷我 / 咪咕：路径中的尺寸段（/300x300/、/W300h300/）删掉即为原图
    if (host.endsWith('kuwo.cn') || host.endsWith('migu.cn')) {
      final cleaned = url
          .replaceFirst(RegExp(r'/\d+x\d+/'), '/')
          .replaceFirst(RegExp(r'/[Ww]\d+[Hh]\d+/'), '/');
      return cleaned == url ? null : cleaned;
    }
    return null;
  }

  Future<void> _materializeOnlineArt(QueueItem item) async {
    if (!Platform.isAndroid) return;
    final url = item.coverUrl;
    if (url == null || url.isEmpty) return;
    final cached = _artFileCache[url];
    if (cached != null) {
      if (File(cached).existsSync()) return;
      _artFileCache.remove(url);
    }
    if (!_artMaterializing.add(url)) return;
    try {
      // 优先拉高清候选，失败再回退原 URL；落盘 key 仍用原 URL 的哈希。
      final hd = _hdCoverUrl(url);
      var bytes = hd == null ? null : await CoverProxy.fetch(hd);
      bytes ??= await CoverProxy.fetch(url);
      if (bytes == null || bytes.isEmpty) return;
      final dir = await getTemporaryDirectory();
      final key = md5.convert(utf8.encode(url)).toString();
      final file = File('${dir.path}/media_art_$key.jpg');
      await file.writeAsBytes(bytes, flush: true);
      _artFileCache[url] = file.path;
      if (_lastSyncItem?.path == item.path) {
        mediaItem.add(
          _buildMediaItem(item, _lastSyncDuration, Uri.file(file.path)),
        );
      }
    } catch (e) {
      AppLog.debug('player', '通知封面物化失败: $e');
    } finally {
      _artMaterializing.remove(url);
    }
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
    await _notifier?.pauseFromSystem(origin: 'mediasession.taskRemoved');
    await super.stop();
    exit(0);
  }
}
