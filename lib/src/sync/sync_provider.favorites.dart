part of 'sync_provider.dart';

/// 收藏同步服务：由 [SyncNotifier] 装配，状态经 [SyncDomainLens] 读写。
class FavoritesSyncService {
  FavoritesSyncService(this._ref, this._lens);

  final Ref _ref;
  final SyncDomainLens _lens;

  AccountApi get _api => _ref.read(accountApiProvider);

  // ==================== 收藏同步 ====================

  Future<void> upload({bool overwrite = false}) async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final favEntries = _ref.read(favoritesProvider).entries;
      if (overwrite) {
        // 覆盖上传（手动「同步至服务器」）：本地收藏全集即云端目标状态，
        // 忽略「仅保留本地」墓碑并清空墓碑缓存；本地为空即清空云端收藏。
        final payload = favEntries.map(_entryToPayload).toList();
        await FavoritesSyncState
            .removeLocalOnlyPaths(await FavoritesSyncState.localOnlyPaths());
        await FavoritesSyncState
            .removeCloudKeepPaths(await FavoritesSyncState.cloudKeepPaths());
        final count = await _api.uploadFavorites(payload, merge: false);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
            'synced_favorites_paths', favEntries.map((e) => e.path).toList());
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('已覆盖上传 {n} 首收藏歌曲', {'n': count}),
          lastTime: DateTime.now(),
          errors: [],
        );
        return;
      }
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
      final payload = favEntries.where((e) => !localOnly.contains(e.path)).map(_entryToPayload).toList();
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
      AppLog.warn('sync', '收藏上传失败: $e');
      _fail(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> download({bool overwrite = false}) async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final res = await _api.downloadFavorites();
      final favs = res.favorites;
      // 覆盖下载不应用删除账本与墓碑：云端收藏全集即本地目标状态
      if (!overwrite) await _trimCloudDeleted(res.deletedPaths);
      if (favs.isEmpty && !overwrite) {
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
      if (overwrite) {
        // 覆盖下载（手动「更新至本地」）：云端收藏全集替换本地，墓碑缓存一并清空；
        // 云端为空时结果即本地清空。
        await FavoritesSyncState
            .removeLocalOnlyPaths(await FavoritesSyncState.localOnlyPaths());
        await FavoritesSyncState
            .removeCloudKeepPaths(await FavoritesSyncState.cloudKeepPaths());
        final now = DateTime.now().millisecondsSinceEpoch;
        final entries = <FavoriteEntry>[];
        final seen = <String>{};
        for (final item in favs) {
          final parsed = _parseCloudItem(index, item);
          if (parsed == null || !seen.add(parsed.target)) continue;
          entries.add(FavoriteEntry(
            path: parsed.target,
            title: parsed.title,
            artist: parsed.artist,
            album: parsed.album,
            durationMs: parsed.durationMs,
            coverUrl: parsed.coverUrl,
            source: parsed.source,
            onlineSongJson: parsed.onlineSongJson,
            onlineQuality: parsed.onlineQuality,
            onlineInfoJson: parsed.onlineInfoJson,
            addedAt: now,
          ));
        }
        await notifier.replaceAll(entries);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
            'synced_favorites_paths', entries.map((e) => e.path).toList());
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: entries.isNotEmpty
              ? tr('已覆盖下载 {n} 首收藏歌曲', {'n': entries.length})
              : tr('云端暂无收藏，本地收藏已清空'),
          lastTime: DateTime.now(),
          errors: [],
        );
        return;
      }
      final cloudKeep = await FavoritesSyncState.cloudKeepPaths();
      // 统计实际新增数：云端原始条数含双端各自上传的同曲重复条目，
      // 直接用 favs.length 会造成「本地 33 首却显示拉取 64 首」的口径错位。
      var added = 0;
      for (final item in favs) {
        final parsed = _parseCloudItem(index, item);
        if (parsed == null) continue;
        if (cloudKeep.contains(parsed.rawPath) ||
            cloudKeep.contains(parsed.target)) {
          continue;
        }
        final isNew = !_ref.read(favoritesProvider).contains(parsed.target);
        await notifier.add(
          QueueItem(
            path: parsed.target,
            title: parsed.title,
            artist: parsed.artist,
            album: parsed.album,
            durationMs: parsed.durationMs,
            coverUrl: parsed.coverUrl,
            coverPath: parsed.coverPath,
            source: parsed.source,
            onlineSongJson: parsed.onlineSongJson,
            onlineQuality: parsed.onlineQuality,
            onlineInfoJson: parsed.onlineInfoJson,
          ),
        );
        if (isNew) added++;
      }
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: added > 0
            ? tr('已拉取 {n} 首收藏', {'n': added})
            : tr('收藏已是最新'),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLog.warn('sync', '收藏下载失败: $e');
      _fail(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  /// 云端删除广播裁剪：其他端「删除全部/删除云端」的收藏真删本地。
  /// 「仅保留本地」墓碑中的路径是本机故意留下的，跳过；同时从
  /// synced_favorites_paths 移除，避免下次上传把删除重推导一遍。
  Future<void> _trimCloudDeleted(List<String> deletedPaths) async {
    if (deletedPaths.isEmpty) return;
    final localOnly = await FavoritesSyncState.localOnlyPaths();
    final victims =
        deletedPaths.where((p) => p.isNotEmpty && !localOnly.contains(p)).toSet();
    if (victims.isEmpty) return;
    final notifier = _ref.read(favoritesProvider.notifier);
    for (final p in victims) {
      try {
        await notifier.remove(p);
      } catch (e) {
        AppLog.warn('sync', '收藏 $p 云端删除裁剪失败: $e');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    final synced =
        prefs.getStringList('synced_favorites_paths') ?? const <String>[];
    final next = synced.where((p) => !victims.contains(p)).toList();
    if (next.length != synced.length) {
      await prefs.setStringList('synced_favorites_paths', next);
    }
  }

  /// 云端收藏条目 → 本地条目：解析标题/音源信息并匹配本地曲库。
  /// 返回 null 表示条目无 path；rawPath 为云端原始 path，target 为匹配
  /// 本地曲库后的落点 path。
  ({
    String rawPath,
    String target,
    String title,
    String artist,
    String album,
    int durationMs,
    String? coverUrl,
    String? coverPath,
    String? source,
    String? onlineSongJson,
    String? onlineQuality,
    String? onlineInfoJson,
  })? _parseCloudItem(
      ({Map<String, Song> byPath, Map<String, List<Song>> byMeta}) index,
      Map<String, dynamic> item) {
    final path = item['path'] as String?;
    if (path == null || path.isEmpty) return null;
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
    return (
      rawPath: path,
      target: matched?.path ?? path,
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
    );
  }

  /// 收藏条目 → 云端上传 payload。
  Map<String, dynamic> _entryToPayload(FavoriteEntry e) => {
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

  void _fail(String err) {
    _lens.item = _lens.item.copyWith(
      syncing: false,
      errors: [err],
    );
  }

}
