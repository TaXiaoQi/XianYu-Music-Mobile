part of 'sync_provider.dart';

/// 歌单同步服务：由 [SyncNotifier] 装配，状态经 [SyncDomainLens] 读写。
class PlaylistSyncService {
  PlaylistSyncService(this._ref, this._lens);

  final Ref _ref;
  final SyncDomainLens _lens;

  AccountApi get _api => _ref.read(accountApiProvider);

  // ==================== 歌单同步 ====================

  Map<String, dynamic> _songToSyncPayload(ImportedSong s) => {
        ...s.toJson(),
        'name': s.title,
        'duration': s.duration * 1000,
        'syncType': SyncNotifier._classifySyncSong(s),
        'song_hash': playlistSyncSongHash(s),
      };

  String _firstRemoteSongCover(List<ImportedSong> songs) {
    for (final s in songs) {
      final cover = s.coverUrl ?? '';
      if (cover.startsWith('http://') || cover.startsWith('https://')) {
        return cover;
      }
    }
    return '';
  }

  ImportedSong _songFromSyncPayload(
    Map<String, dynamic> j,
    Map<String, Song> byPath,
    Map<String, List<Song>> byMeta,
  ) {
    final rawPath = j['path'] as String? ?? '';
    final title = (j['title'] ?? j['name'] ?? '').toString();
    final artist = (j['artist'] ?? '').toString();
    final durationSec = (((j['duration'] as num?) ?? 0) / 1000).round();

    final isOnline = SyncNotifier._isOnlineSyncPath(rawPath) ||
        j['syncType'] == 'online' ||
        j['source_type'] == 'remote' ||
        j['source_type'] == 'plugin';
    if (isOnline) {
      return ImportedSong.fromJson({
        'title': title,
        'artist': j['artist'],
        'album': j['album'],
        'duration': durationSec,
        'coverUrl': j['coverUrl'],
        'pluginId': j['pluginId'],
        'source': j['source'],
        'format': j['format'],
        'musicInfo': j['musicInfo'],
        'addedInApp': j['addedInApp'] == true,
        'path': rawPath,
      });
    }

    final isCloudLocal = j['syncType'] == 'local' || j['source_type'] == 'local';
    final cloudLocalPath = (j['localPath'] as String?) ??
        (isCloudLocal ? rawPath : null);
    final matchPath = (cloudLocalPath != null && cloudLocalPath.isNotEmpty)
        ? cloudLocalPath
        : rawPath;
    final matched = SyncNotifier._isLocalFilePath(matchPath)
        ? SyncNotifier._matchLocalLibrarySong(
            byPath, byMeta, matchPath, title, artist, durationSec)
        : null;
    final resolvedPath = matched?.path ?? matchPath;
    return ImportedSong.fromJson({
      'title': matched?.title ?? title,
      'artist': matched?.artist ?? (j['artist'] ?? ''),
      'album': matched?.album ?? (j['album'] ?? ''),
      'duration': durationSec,
      'coverUrl': j['coverUrl'],
      'coverThumbPath': matched?.coverThumbPath,
      'localPath': resolvedPath,
      'pluginId': j['pluginId'],
      'source': j['source'],
      'format': j['format'],
      'musicInfo': j['musicInfo'],
      'addedInApp': j['addedInApp'] == true,
      'path': resolvedPath,
    });
  }


  Future<void> upload() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final local = await PlaylistStore().loadAll();
      if (local.isEmpty) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('本地暂无可上传的歌单'),
          lastTime: DateTime.now(),
        );
        return;
      }
      final payload = <Map<String, dynamic>>[];
      for (final p in local) {
        var payloadSongs = p.songs.map(_songToSyncPayload).toList();
        List<String>? deletedSongPaths;
        final cloudId = p.cloudId ?? '';
        if (cloudId.isNotEmpty) {
          final localPaths = p.songs.map((s) => s.path).toSet();
          final keepMap = await PlaylistSongSyncState.cloudKeepSongs(cloudId);
          for (final entry in keepMap.entries) {
            if (!payloadSongs.any((s) => s['path'] == entry.key)) {
              try {
                final decoded = jsonDecode(entry.value);
                if (decoded is Map<String, dynamic>) payloadSongs.add(decoded);
              } catch (_) {
                // 解析失败按默认值处理
              }
            }
          }
          await PlaylistSongSyncState.pruneCloudKeepSongs(cloudId, localPaths);
          final localOnly = await PlaylistSongSyncState.localOnlySongs(cloudId);
          if (localOnly.isNotEmpty) {
            payloadSongs = payloadSongs
                .where((s) => !localOnly.contains(s['path']))
                .toList();
            await PlaylistSongSyncState.pruneLocalOnlySongs(
                cloudId, localPaths);
          }
          final pending = await PlaylistSongSyncState.pendingDeletedSongs(cloudId);
          if (pending.isNotEmpty) {
            await PlaylistSongSyncState.prunePendingDeletedSongs(
                cloudId, pending.where(localPaths.contains));
          }
          final report = {
            ...await PlaylistSongSyncState.localOnlySongs(cloudId),
            ...await PlaylistSongSyncState.pendingDeletedSongs(cloudId),
          };
          if (report.isNotEmpty) deletedSongPaths = report.toList();
        }
        payload.add({
          'id': p.id,
          'name': p.name,
          'cloudCoverUrl': _firstRemoteSongCover(p.songs),
          'cloudId': p.cloudId,
          if (p.sourcePluginId != null) 'sourcePluginId': p.sourcePluginId,
          if (p.sourceUrl != null) 'sourceUrl': p.sourceUrl,
          if (p.sourceRaw != null) 'sourceRaw': p.sourceRaw,
          'songs': payloadSongs,
          'deletedSongPaths': ?deletedSongPaths,
        });
      }
      final res = await _api.fileSyncUpload(payload);
      final store = PlaylistStore();
      if (res.idMap.isNotEmpty) {
        for (final entry in res.idMap) {
          final localId = (entry['id'] as String?);
          final cloudId = (entry['cloudId'] as String?);
          if (localId != null && localId.isNotEmpty) {
            await store.setCloudId(localId, cloudId);
          }
        }
      }
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('已上传 {pcount} 个歌单 / {scount} 首', {'pcount': res.playlistCount, 'scount': res.songTotal}),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLog.warn('sync', '歌单上传失败: $e');
      _fail(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  /// v2 下载协议开关：true 走 file_sync_v2_download_ops（服务端 diff 下发最小
  /// ops），置 false 回退 v1 全量快照下载（与桌面端 USE_SYNC_V2 一致）。
  static const _useSyncV2 = true;

  Future<void> download() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      if (_useSyncV2) {
        await _downloadViaOps();
      } else {
        await _downloadViaSnapshot();
      }
    } catch (e) {
      AppLog.warn('sync', '歌单下载失败: $e');
      _fail(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  /// v2 路径：上报本地歌单概要（song_hash），服务端 diff 后下发 ops 幂等应用。
  Future<void> _downloadViaOps() async {
    final store = PlaylistStore();
    final working = await store.loadAll();
    final library = _ref.read(libraryProvider);
    if (library.loading) {
      await _ref.read(libraryProvider.notifier).load();
    }
    final index = SyncNotifier._buildLibraryIndex(_ref);
    final reports = <Map<String, dynamic>>[];
    for (final p in working) {
      reports.add({
        'localId': p.id,
        if ((p.cloudId ?? '').isNotEmpty) 'cloudId': p.cloudId,
        'name': p.name,
        'cloudCoverUrl': _firstRemoteSongCover(p.songs),
        if (p.importedAt > 0) 'createdAt': p.importedAt,
        if (p.sourcePluginId != null) 'sourcePluginId': p.sourcePluginId,
        if (p.sourceUrl != null) 'sourceUrl': p.sourceUrl,
        'song_hashes': p.songs.map(playlistSyncSongHash).toList(),
      });
    }

    final data = await _api.fileSyncV2DownloadOps(reports);
    final ops = ((data['ops'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    if (ops.isEmpty) {
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('云端无变更'),
        lastTime: DateTime.now(),
      );
      return;
    }

    // 墓碑预载：applySyncOps 为同步纯函数，keep/pending 一次性读入内存
    final keepAll = await PlaylistSongSyncState.allCloudKeepSongs();
    final pendingAll = await PlaylistSongSyncState.allPendingDeletedSongs();
    final target = SyncOpsTarget(
      playlists: working,
      resolveSong: (payload) =>
          _songFromSyncPayload(payload, index.byPath, index.byMeta),
      isSongKept: (cloudId, path) =>
          keepAll[cloudId]?.containsKey(path) ?? false,
      isSongPendingDeleted: (cloudId, path) =>
          pendingAll[cloudId]?.contains(path) ?? false,
    );
    final outcome = applySyncOps(ops, target);
    await store.saveAll(target.playlists);
    // remove_songs 已被云端确认，清理对应待上报删除墓碑（对齐 v1 下载语义）
    for (final op in ops) {
      if (op['type'] != 'remove_songs') continue;
      final cloudId = (op['cloudId'] as String?) ?? '';
      if (cloudId.isEmpty) continue;
      await PlaylistSongSyncState.prunePendingDeletedSongs(
        cloudId,
        ((op['paths'] as List?) ?? const []).whereType<String>(),
      );
    }
    await _ref.read(playlistManagerProvider.notifier).refresh();
    _lens.item = _lens.item.copyWith(
      syncing: false,
      lastSummary: tr('已导入 {n} 个歌单 / {scount} 首', {
        'n': outcome.createdPlaylists + outcome.mergedPlaylists,
        'scount': outcome.addedSongs,
      }),
      lastTime: DateTime.now(),
      errors: [],
    );
  }

  /// v1 路径：全量快照下载 + 本地合并（回退开关用）。
  Future<void> _downloadViaSnapshot() async {
    final data = await _api.fileSyncDownload();
      final cloudPlaylists = ((data?['playlists'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (cloudPlaylists.isEmpty) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('云端暂无歌单数据'),
          lastTime: DateTime.now(),
        );
        return;
      }
      final toImport = <PluginBackupPlaylist>[];
      var songCount = 0;
      final library = _ref.read(libraryProvider);
      if (library.loading) {
        await _ref.read(libraryProvider.notifier).load();
      }
      final index = SyncNotifier._buildLibraryIndex(_ref);
      for (final pl in cloudPlaylists) {
        final cloudId = (pl['cloudId'] as String?) ?? '';
        final plName = (pl['name'] as String?) ?? tr('未命名歌单');
        final deletedPaths = ((pl['deletedSongPaths'] as List?) ?? const [])
            .whereType<String>()
            .toSet();
        final keepMap = cloudId.isNotEmpty
            ? await PlaylistSongSyncState.cloudKeepSongs(cloudId)
            : const <String, String>{};
        final pendingSet = cloudId.isNotEmpty
            ? await PlaylistSongSyncState.pendingDeletedSongs(cloudId)
            : const <String>{};
        final rawSongs =
            ((pl['songs'] as List?) ?? const []).whereType<Map>().toList();
        final visibleRaw = rawSongs.where((e) {
          final p = e['path'] as String?;
          if (p == null) return true;
          if (deletedPaths.contains(p) || pendingSet.contains(p)) return false;
          return !keepMap.containsKey(p);
        }).toList();
        final songs = visibleRaw
            .map((e) =>
                _songFromSyncPayload(e.cast<String, dynamic>(), index.byPath, index.byMeta))
            .toList();
        songCount += songs.length;
        toImport.add(PluginBackupPlaylist(
          name: plName,
          songs: songs,
          originalSongCount: songs.length,
          cloudId: pl['cloudId'] as String?,
          isCloud: true,
          sourcePluginId: (pl['sourcePluginId'] as String?),
          sourceUrl: (pl['sourceUrl'] as String?),
          sourceRaw: pl['sourceRaw'] is Map
              ? (pl['sourceRaw'] as Map).cast<String, dynamic>()
              : null,
        ));
        if (deletedPaths.isNotEmpty) {
          final removePaths = <String>{};
          for (final raw in rawSongs) {
            final p = raw['path'] as String?;
            if (p == null || !deletedPaths.contains(p)) continue;
            removePaths.add(p);
            removePaths.add(_songFromSyncPayload(
                    raw.cast<String, dynamic>(), index.byPath, index.byMeta)
                .path);
          }
          removePaths.remove('');
          await _propagateDeletedSongsToLocal(cloudId, plName, removePaths);
          await PlaylistSongSyncState.prunePendingDeletedSongs(
              cloudId, deletedPaths);
        }
      }
      await PlaylistStore().addPlaylists(toImport);
      await _ref.read(playlistManagerProvider.notifier).refresh();
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('已导入 {n} 个歌单 / {scount} 首', {'n': toImport.length, 'scount': songCount}),
        lastTime: DateTime.now(),
        errors: [],
      );
  }

  Future<void> _propagateDeletedSongsToLocal(
      String cloudId, String name, Set<String> removePaths) async {
    if (removePaths.isEmpty) return;
    final store = PlaylistStore();
    final all = await store.loadAll();
    var changed = false;
    final next = all.map((p) {
      final matched =
          (cloudId.isNotEmpty && p.cloudId == cloudId) || p.name == name;
      if (!matched) return p;
      final filtered =
          p.songs.where((s) => !removePaths.contains(s.path)).toList();
      if (filtered.length == p.songs.length) return p;
      changed = true;
      return p.copyWith(songs: filtered);
    }).toList();
    if (changed) {
      await store.saveAll(next);
      await _ref.read(playlistManagerProvider.notifier).refresh();
    }
  }

  void _fail(String err) {
    _lens.item = _lens.item.copyWith(
      syncing: false,
      errors: [err],
    );
  }

}
