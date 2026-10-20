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


  Future<void> upload({bool overwrite = false}) async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final local = await PlaylistStore().loadAll();
      // 覆盖上传不早退：本地为空也上传空快照（merge=false），即快捷清空云端歌单
      if (local.isEmpty && !overwrite) {
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
        // 覆盖上传跳过墓碑/云端保留等合并裁剪，本地歌单全集即云端目标状态
        if (cloudId.isNotEmpty && !overwrite) {
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
      final res = await _api.fileSyncUpload(payload, merge: !overwrite);
      final store = PlaylistStore();
      if (res.idMap.isNotEmpty) {
        for (final entry in res.idMap) {
          final localId = (entry['id'] as String?);
          final cloudId = (entry['cloudId'] as String?);
          if (localId != null && localId.isNotEmpty) {
            await store.setCloudId(localId, cloudId);
          }
          // 重新上传视为用户要回该歌单，解除"仅删本地"的下载跳过
          if (cloudId != null && cloudId.isNotEmpty) {
            await PlaylistSongSyncState.removeDownloadSkipPlaylistIds([cloudId]);
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

  Future<void> download({bool overwrite = false}) async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      if (overwrite) {
        await _downloadOverwriteSnapshot();
      } else if (_useSyncV2) {
        await _downloadViaOps();
      } else {
        await _downloadViaSnapshot();
      }
    } catch (e) {
      AppLog.warn('sync', '歌单下载失败: $e');
      _fail(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  /// 覆盖下载（手动「更新至本地」）：v1 全量快照直接替换本地歌单。
  /// 不走 v2 diff、不应用墓碑/删除账本，本地独有歌单将被移除；
  /// 被替换歌单的墓碑随之清除，避免下次上传把覆盖前的删除重放到云端。
  Future<void> _downloadOverwriteSnapshot() async {
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
    final library = _ref.read(libraryProvider);
    if (library.loading) {
      await _ref.read(libraryProvider.notifier).load();
    }
    final index = SyncNotifier._buildLibraryIndex(_ref);

    // 本地歌单整体被替换：旧歌单的墓碑与下载跳过记录全部失效，一并清空
    final store = PlaylistStore();
    final working = await store.loadAll();
    final staleCloudIds = working
        .map((p) => p.cloudId ?? '')
        .where((c) => c.isNotEmpty)
        .toSet();
    for (final cid in staleCloudIds) {
      await PlaylistSongSyncState.clearTombstones(cid);
    }
    await PlaylistSongSyncState.removeDownloadSkipPlaylistIds(staleCloudIds);

    final rebuilt = <ImportedPlaylist>[];
    var songCount = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final pl in cloudPlaylists) {
      final deletedPaths = ((pl['deletedSongPaths'] as List?) ?? const [])
          .whereType<String>()
          .toSet();
      final rawSongs =
          ((pl['songs'] as List?) ?? const []).whereType<Map>().toList();
      // 仅过滤云端自带的 deletedSongPaths，不应用本地墓碑
      final visibleRaw = rawSongs.where((e) {
        final p = e['path'] as String?;
        return p == null || !deletedPaths.contains(p);
      }).toList();
      final songs = visibleRaw
          .map((e) =>
              _songFromSyncPayload(e.cast<String, dynamic>(), index.byPath, index.byMeta))
          .map((s) => s.copyWith(addedAt: s.addedAt ?? DateTime.now()))
          .toList();
      songCount += songs.length;
      rebuilt.add(ImportedPlaylist(
        id: PlaylistStore.newId(const {}),
        name: (pl['name'] as String?) ?? tr('未命名歌单'),
        songs: songs,
        importedAt: now,
        cloudId: pl['cloudId'] as String?,
        isCloud: true,
        sourcePluginId: pl['sourcePluginId'] as String?,
        sourceUrl: pl['sourceUrl'] as String?,
        sourceRaw: pl['sourceRaw'] is Map
            ? (pl['sourceRaw'] as Map).cast<String, dynamic>()
            : null,
      ));
    }
    await store.saveAll(rebuilt);
    await _ref.read(playlistManagerProvider.notifier).refresh();
    _lens.item = _lens.item.copyWith(
      syncing: false,
      lastSummary: tr('已导入 {n} 个歌单 / {scount} 首', {'n': rebuilt.length, 'scount': songCount}),
      lastTime: DateTime.now(),
      errors: [],
    );
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
    await _trimCloudDeletedPlaylists(((data['deleted_playlist_cloud_ids'] as List?) ?? const [])
        .whereType<String>()
        .toSet());
    final downloadSkip = await PlaylistSongSyncState.downloadSkipPlaylistIds();
    final ops = ((data['ops'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    // "仅删本地（云端保留）"的歌单：跳过 create，防止被同步拉回来
    final filteredOps = ops.where((op) {
      if (op['type'] != 'create_playlist') return true;
      final cid = (op['playlist']?['cloudId'] as String?) ?? '';
      return cid.isEmpty || !downloadSkip.contains(cid);
    }).toList();
    if (filteredOps.isEmpty) {
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
      // loadAll 在无本地歌单时返回 const []，applySyncOps 会 add 新建歌单，
      // 必须拷贝为可增长列表，否则 "Cannot add to an unmodifiable list"
      playlists: List.of(working),
      resolveSong: (payload) =>
          _songFromSyncPayload(payload, index.byPath, index.byMeta),
      isSongKept: (cloudId, path) =>
          keepAll[cloudId]?.containsKey(path) ?? false,
      isSongPendingDeleted: (cloudId, path) =>
          pendingAll[cloudId]?.contains(path) ?? false,
    );
    final outcome = applySyncOps(filteredOps, target);
    await store.saveAll(target.playlists);
    // remove_songs 已被云端确认，清理对应待上报删除墓碑（对齐 v1 下载语义）
    for (final op in filteredOps) {
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
      await _trimCloudDeletedPlaylists(((data?['deleted_playlist_cloud_ids'] as List?) ?? const [])
          .whereType<String>()
          .toSet());
      final downloadSkip = await PlaylistSongSyncState.downloadSkipPlaylistIds();
      final cloudPlaylists = ((data?['playlists'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .where((pl) {
            // 与 v2 一致："仅删本地"的歌单不再从云端拉回
            final cid = (pl['cloudId'] as String?) ?? '';
            return cid.isEmpty || !downloadSkip.contains(cid);
          })
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

  /// 云端删除广播裁剪：其他端「删除全部/删除云端」的歌单按 cloudId 真删本地。
  /// 仅按 cloudId 匹配，无绑定的独立歌单不动（名字跨端不可靠，不作匹配依据）；
  /// 裁剪后清该歌单的遗留墓碑，并解除「删除本地（云端保留）」的下载跳过。
  Future<void> _trimCloudDeletedPlaylists(Set<String> cloudIds) async {
    final victims = cloudIds.where((c) => c.isNotEmpty).toSet();
    if (victims.isEmpty) return;
    // 云端已删：本机对应墓碑与「删除本地（云端保留）」跳过记录随之失效，
    // 无论本地是否存在该歌单都清掉
    for (final cid in victims) {
      await PlaylistSongSyncState.clearTombstones(cid);
    }
    await PlaylistSongSyncState.removeDownloadSkipPlaylistIds(victims);
    final store = PlaylistStore();
    final all = await store.loadAll();
    final next = all.where((p) {
      final cid = p.cloudId ?? '';
      return cid.isEmpty || !victims.contains(cid);
    }).toList();
    if (next.length == all.length) return;
    await store.saveAll(next);
    await _ref.read(playlistManagerProvider.notifier).refresh();
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
