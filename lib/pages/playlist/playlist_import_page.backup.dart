// 部分：backup Tab（part 拆分自 playlist_import_page.dart）
part of 'playlist_import_page.dart';

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------

class _BackupImportTab extends ConsumerStatefulWidget {
  const _BackupImportTab();

  @override
  ConsumerState<_BackupImportTab> createState() => _BackupImportTabState();
}

class _BackupImportTabState extends ConsumerState<_BackupImportTab> {
  bool _loading = false;

  Future<void> _importFile(String path, String name) async {
    if (path.isEmpty || _loading) return;
    setState(() => _loading = true);
    try {
      final bytes = await File(path).readAsBytes();
      final lowerName = name.toLowerCase();
      final isPlaylist =
          lowerName.endsWith('.m3u') ||
          lowerName.endsWith('.m3u8') ||
          lowerName.endsWith('.txt');

      final sources = ref.read(pluginManagerProvider).sources;
      PreparedPluginBackupImport prepared;
      if (isPlaylist) {
        final content = utf8.decode(bytes, allowMalformed: true);
        try {
          prepared = preparePlaylistFileImport(
            content,
            name,
            localSongs: _localSongRefs(),
          );
        } on FormatException {
          if (lowerName.endsWith('.txt')) {
            prepared = preparePluginBackupImport(
              extractBackupJsonBytes(bytes, name),
              sources,
            );
          } else {
            rethrow;
          }
        }
      } else {
        final jsonContent = extractBackupJsonBytes(bytes, name);
        prepared = preparePluginBackupImport(jsonContent, sources);
      }

      final manager = ref.read(playlistManagerProvider.notifier);
      final beforeCount = ref.read(playlistManagerProvider).playlists.length;
      final playlists = await manager.addFromBackup(prepared);
      final addedCount = (playlists.length - beforeCount).clamp(
        0,
        playlists.length,
      );
      if (!mounted) return;
      await _showResult(prepared, addedCount);
    } on FormatException catch (e) {
      if (!mounted) return;
      _toast(tr('导入失败：{e}', {'e': e.message}));
    } catch (e) {
      if (!mounted) return;
      _toast(tr('导入失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<LocalSongRef> _localSongRefs() {
    final library = ref.read(libraryProvider);
    return library.songs
        .map(
          (s) => (
            path: s.path,
            title: s.title,
            artist: s.artist,
            album: s.album,
            duration: s.duration,
            coverThumbPath: s.coverThumbPath,
          ),
        )
        .toList();
  }

  void _toast(String msg) {
    showXianYuToast(context, msg);
  }

  Future<void> _showResult(
    PreparedPluginBackupImport prepared,
    int createdCount,
  ) async {
    final versionNote = describeBackupVersion(prepared);
    await showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('导入完成')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$versionNote\n'
                '${tr('新增 {n} 个歌单，', {'n': createdCount})}'
                '${tr('成功导入 {n} 首歌曲，', {'n': prepared.importedSongCount})}'
                '${tr('{n} 首未导入。', {'n': prepared.failures.length})}',
                style: const TextStyle(fontSize: 14),
              ),
              if (prepared.missingPlugins.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  tr('缺失插件：'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(ctx).colorScheme.error,
                  ),
                ),
                const SizedBox(height: 4),
                for (final missing in prepared.missingPlugins)
                  Text(
                    tr('· {platform}（{n} 首）', {
                      'platform': missing.platform,
                      'n': missing.songCount,
                    }),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
              if (prepared.associations.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  tr('关联插件：'),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                for (final assoc in prepared.associations)
                  Text(
                    tr('· {plugin} → {platform}（{n} 首）', {
                      'plugin': assoc.pluginName,
                      'platform': assoc.platform,
                      'n': assoc.songCount,
                    }),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('好的')),
          ),
        ],
      ),
    );
  }

  Future<void> _pickLocalFile() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt', 'zip', 'lxmc', 'm3u', 'm3u8'],
      );
      if (files.isEmpty) return;
      final file = files.single;
      final path = file.path;
      if (path == null) return;
      await _importFile(path, file.name);
    } catch (e) {
      if (!mounted) return;
      _toast(tr('读取文件失败：{e}', {'e': e}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          tr(
            '支持 BakaMusic / MusicFree / 洛雪音乐备份（JSON、ZIP、lxmc）与 M3U/M3U8 播放列表、椒盐音乐 TXT 导出。',
          ),
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Center(
          child: OutlinedButton.icon(
            onPressed: _loading ? null : _pickLocalFile,
            icon: const Icon(Icons.folder_open, size: 24),
            label: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(tr('选择本地备份文件'), style: TextStyle(fontSize: 15)),
            ),
          ),
        ),
        if (_loading) ...[
          const SizedBox(height: 20),
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ],
    );
  }
}
