// 部分：local Tab（part 拆分自 playlist_import_page.dart）
part of 'playlist_import_page.dart';

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------

class _LocalFolderTab extends ConsumerStatefulWidget {
  const _LocalFolderTab();

  @override
  ConsumerState<_LocalFolderTab> createState() => _LocalFolderTabState();
}

class _LocalFolderTabState extends ConsumerState<_LocalFolderTab> {
  static const _audioExtensions = [
    'flac',
    'mp3',
    'wav',
    'aac',
    'm4a',
    'm4b',
    'mp4',
    'ogg',
    'oga',
    'aif',
    'aiff',
    'dsf',
    'dff',
  ];

  final _nameCtrl = TextEditingController();
  String? _treeUri;
  String _folderName = '';
  bool _importing = false;
  int _parsed = 0;
  int _total = 0;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    if (!SafChannel.isSupported) {
      showXianYuToast(context, tr('本地文件夹导入仅支持 Android 设备'));
      return;
    }
    final uri = await SafChannel.chooseFolderTree();
    if (uri == null || uri.isEmpty) return;
    await SafChannel.persistPermission(uri);
    if (!mounted) return;
    final name = await SafChannel.friendlyTreeName(uri);
    if (!mounted) return;
    setState(() {
      _treeUri = uri;
      _folderName = name;
    });
    if (_nameCtrl.text.trim().isEmpty) {
      final segments = name
          .split('/')
          .where((s) => s.trim().isNotEmpty)
          .toList();
      _nameCtrl.text = segments.isNotEmpty ? segments.last : name;
    }
  }

  Future<void> _import() async {
    final treeUri = _treeUri;
    if (treeUri == null || _importing) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      showXianYuToast(context, tr('请输入歌单名称'));
      return;
    }

    setState(() {
      _importing = true;
      _parsed = 0;
      _total = 0;
    });

    try {
      final files = await SafChannel.listAudioTree(treeUri, _audioExtensions);
      if (files.isEmpty) {
        if (!mounted) return;
        _finish(false, tr('所选文件夹中没有支持的音乐文件'));
        return;
      }
      setState(() => _total = files.length);

      final songs = <ImportedSong>[];
      for (final f in files) {
        final path = SafChannel.songPath(treeUri, f.docId);
        final fd = await SafChannel.openFd(treeUri, f.docId);
        if (fd < 0) continue;
        try {
          final songJson = await parseAudioFromFdAndroid(
            fd: fd,
            fileName: f.name,
            pathKey: path,
            format: f.ext,
          );
          final parsed = jsonDecode(songJson) as Map<String, dynamic>;
          if ((parsed['duration'] as num? ?? 0) > 0) {
            songs.add(
              ImportedSong(
                title: (parsed['title'] as String? ?? '').isNotEmpty
                    ? parsed['title'] as String
                    : f.name,
                artist: parsed['artist'] as String? ?? '',
                album: parsed['album'] as String? ?? '',
                duration: (parsed['duration'] as num?)?.toInt() ?? 0,
                localPath: path,
                path: path,
              ),
            );
          }
        } catch (e) {
          AppLog.debug('playlist', '解析音频失败，跳过 ${f.name}: $e');
        } finally {
          await SafChannel.closeFd(fd);
        }
        if (mounted) setState(() => _parsed = songs.length);
      }

      if (songs.isEmpty) {
        if (!mounted) return;
        _finish(false, tr('未能解析出任何歌曲'));
        return;
      }

      final manager = ref.read(playlistManagerProvider.notifier);
      await manager.create(name);
      final created = ref.read(playlistManagerProvider).playlists;
      if (created.isEmpty) {
        if (!mounted) return;
        _finish(false, tr('歌单创建失败'));
        return;
      }
      await manager.addSongs(created.last.id, songs);
      if (!mounted) return;
      _finish(
        true,
        tr('已创建歌单「{name}」，共导入 {n} 首歌曲', {'name': name, 'n': songs.length}),
      );
    } catch (e) {
      if (!mounted) return;
      _finish(false, tr('导入失败：{e}', {'e': e}));
    }
  }

  void _finish(bool ok, String message) {
    setState(() => _importing = false);
    showXianYuToast(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        TextField(
          controller: _nameCtrl,
          enabled: !_importing,
          decoration: InputDecoration(
            labelText: tr('歌单名称 *'),
            hintText: tr('请输入新歌单名称'),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          tr('音乐文件夹 *'),
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: _importing ? null : _pickFolder,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 92,
            decoration: BoxDecoration(
              color: appCardColor(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _treeUri != null
                    ? scheme.primary.withValues(alpha: 0.5)
                    : scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            alignment: Alignment.center,
            child: _treeUri == null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_open_outlined,
                        size: 30,
                        color: scheme.outline,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        tr('点击选择包含音乐的文件夹'),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_rounded,
                        size: 30,
                        color: scheme.primary,
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          _folderName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          tr('将递归读取所选文件夹中的音乐文件并创建为独立歌单，不会加入本地库扫描目录。'),
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        if (_importing) ...[
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _total > 0 ? _parsed / _total : null),
          const SizedBox(height: 6),
          Text(
            _total > 0 ? '正在解析 $_parsed / $_total …' : tr('正在读取文件夹…'),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: (_importing || _treeUri == null) ? null : _import,
          icon: _importing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.library_add_check_outlined, size: 18),
          label: Text(_importing ? tr('导入中…') : tr('读取并创建')),
        ),
      ],
    );
  }
}
