part of 'sync_provider.dart';

/// 收藏同步服务：由 [SyncNotifier] 装配，状态经 [SyncDomainLens] 读写。
class FavoritesSyncService {
  FavoritesSyncService(this._ref, this._lens);

  final Ref _ref;
  final SyncDomainLens _lens;

  AccountApi get _api => _ref.read(accountApiProvider);

  // ==================== 收藏同步 ====================

  Future<void> upload() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final favEntries = _ref.read(favoritesProvider).entries;
      if (favEntries.isEmpty) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('本地收藏为空，跳过上传'),
          lastTime: DateTime.now(),
          errors: [],
        );
        return;
      }
      final localOnly = await FavoritesSyncState.localOnlyPaths();
      final cloudKeep = await FavoritesSyncState.cloudKeepPaths();
      final payload = favEntries.where((e) => !localOnly.contains(e.path)).map((e) {
        return {
          'title': e.title,
          'name': e.title,
          'path': e.path,
          'artist': e.artist,
          'album': e.album,
          'duration': e.durationMs,
          'coverUrl': e.coverUrl,
          'source': e.source,
          'onlineSongJson': e.onlineSongJson,
          'onlineQuality': e.onlineQuality,
          'onlineInfoJson': e.onlineInfoJson,
        };
      }).toList();
      final prefs = await SharedPreferences.getInstance();
      final currentPaths = favEntries.map((e) => e.path).toSet();
      await FavoritesSyncState
          .removeLocalOnlyPaths(localOnly.where((p) => !currentPaths.contains(p)));
      await FavoritesSyncState.removeCloudKeepPaths(currentPaths);
      final deletePaths = (prefs.getStringList('synced_favorites_paths') ?? [])
          .where((p) => !currentPaths.contains(p) && !cloudKeep.contains(p))
          .toList();
      final count = await _api.uploadFavorites(payload, deletePaths: deletePaths);
      await prefs.setStringList('synced_favorites_paths', currentPaths.toList());
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('已上传 {n} 首收藏歌曲', {'n': count}),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLogger.instance.log('sync', '收藏上传失败: $e');
      _fail(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> download() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final favs = await _api.downloadFavorites();
      if (favs.isEmpty) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('云端暂无收藏数据'),
          lastTime: DateTime.now(),
        );
        return;
      }
      final notifier = _ref.read(favoritesProvider.notifier);
      final library = _ref.read(libraryProvider);
      if (library.loading) {
        await _ref.read(libraryProvider.notifier).load();
      }
      final index = SyncNotifier._buildLibraryIndex(_ref);
      final cloudKeep = await FavoritesSyncState.cloudKeepPaths();
      for (final item in favs) {
        final path = item['path'] as String?;
        if (path == null || path.isEmpty) continue;
        final title = (item['title'] ?? item['name'] ?? path
            .split(RegExp(r'[\\/]'))
            .last) as String;
        final artist = (item['artist'] as String?) ?? '';
        final durationMs = (item['duration'] as num?)?.toInt() ?? 0;

        final musicInfo = SyncNotifier._asMap(item['musicInfo']);
        var source = item['source'] as String?;
        var onlineInfoJson = item['onlineInfoJson'] as String?;
        final hasMobileJson =
            (item['onlineSongJson'] as String?)?.isNotEmpty == true ||
            onlineInfoJson?.isNotEmpty == true;
        if (!hasMobileJson && musicInfo.isNotEmpty) {
          source ??= musicInfo['source'] as String? ?? SyncNotifier._lxSourceOf(path);
          final mi = <String, dynamic>{'source': source, ...musicInfo};
          if (mi['songmid'] == null) mi['songmid'] = SyncNotifier._lxSongmidOf(path);
          onlineInfoJson = jsonEncode(mi);
        }
        final coverUrl = (item['coverUrl'] as String?)?.isNotEmpty == true
            ? item['coverUrl'] as String?
            : SyncNotifier._httpCover(musicInfo['img']) ?? SyncNotifier._httpCover(item['cover_thumb_path']);

        final matched = SyncNotifier._matchLocalLibrarySong(
            index.byPath, index.byMeta, path, title, artist, (durationMs / 1000).round());
        if (cloudKeep.contains(path) ||
            (matched != null && cloudKeep.contains(matched.path))) {
          continue;
        }
        await notifier.add(
          QueueItem(
            path: matched?.path ?? path,
            title: matched?.title ?? title,
            artist: matched?.artist ?? artist,
            album: matched?.album ?? (item['album'] as String?) ?? '',
            durationMs: durationMs,
            coverUrl: coverUrl,
            coverPath: matched?.coverThumbPath,
            source: source,
            onlineSongJson: item['onlineSongJson'] as String?,
            onlineQuality: item['onlineQuality'] as String?,
            onlineInfoJson: onlineInfoJson,
          ),
        );
      }
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('已拉取 {n} 首收藏', {'n': favs.length}),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLogger.instance.log('sync', '收藏下载失败: $e');
      _fail(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  void _fail(String err) {
    _lens.item = _lens.item.copyWith(
      syncing: false,
      errors: [err],
    );
  }

}
