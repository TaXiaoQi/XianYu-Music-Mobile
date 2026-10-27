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

  // 网盘导入（与本地文件夹互斥，后选的生效）：选中后「读取并创建」走
  // 网盘收集，歌曲以 cloud:// 引用入库，播放走网盘直链管线
  CloudProvider? _cloudProvider;
  String _cloudAccountId = '';
  List<(String, String)> _cloudFolders = const []; // (存储键, 可读名)

  bool get _isCloudImport => _cloudFolders.isNotEmpty;

  String get _cloudLabel {
    final folders = _cloudFolders;
    if (folders.isEmpty) return '';
    if (folders.length == 1) return folders.first.$2;
    return tr('已选 {n} 个文件夹', {'n': '${folders.length}'});
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    if (PlatformCaps.isOhos) {
      final uri = await OhosFolderChannel.pickFolder();
      if (uri == null || uri.isEmpty || !mounted) return;
      final segs =
          Uri.parse(uri).pathSegments.where((s) => s.isNotEmpty).toList();
      final name = segs.isNotEmpty ? segs.last : uri;
      setState(() {
        _treeUri = uri;
        _folderName = name;
        _cloudFolders = const []; // 与网盘文件夹互斥
        _cloudProvider = null;
      });
      if (_nameCtrl.text.trim().isEmpty) _nameCtrl.text = name;
      return;
    }
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
      _cloudFolders = const []; // 与网盘文件夹互斥
      _cloudProvider = null;
    });
    if (_nameCtrl.text.trim().isEmpty) {
      final segments = name
          .split('/')
          .where((s) => s.trim().isNotEmpty)
          .toList();
      _nameCtrl.text = segments.isNotEmpty ? segments.last : name;
    }
  }

  /// 选择网盘文件夹：复用「指定播放文件夹」选择器页（pick=1 选取模式，
  /// 不写播放范围 store）。多盘绑定时先选盘，账号由选择器自解析首账号。
  Future<void> _pickCloudFolder(List<CloudProvider> providers) async {
    CloudProvider? provider = providers.first;
    if (providers.length > 1) {
      provider = await showModalBottomSheet<CloudProvider>(
        context: context,
        builder: (ctx) => SafeArea(
          // ListView.shrinkWrap：高度随条目自适应，超出屏高可滚动
          //（绑定盘多时 Column 硬排会溢出）。
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final p in providers)
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: Text(p.displayName),
                  onTap: () => Navigator.pop(ctx, p),
                ),
            ],
          ),
        ),
      );
    }
    if (provider == null || !mounted) return;
    final picked =
        await context.push<({String accountId, List<(String, String)> folders})>(
      '/cloud/folder-picker/${provider.id}?pick=1',
    );
    if (picked == null || picked.folders.isEmpty || !mounted) return;
    setState(() {
      _cloudProvider = provider;
      _cloudAccountId = picked.accountId;
      _cloudFolders = picked.folders;
      _treeUri = null; // 与本地文件夹互斥
      _folderName = '';
    });
    if (_nameCtrl.text.trim().isEmpty) {
      _nameCtrl.text = picked.folders.first.$2;
    }
  }

  Future<void> _import() async {
    if (_importing) return;
    if (_isCloudImport) {
      await _importFromCloud();
      return;
    }
    final treeUri = _treeUri;
    if (treeUri == null) return;
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
      final songs = PlatformCaps.isOhos
          ? await _collectSongsOhos(treeUri)
          : await _collectSongsAndroid(treeUri);
      if (songs == null) return;
      if (songs.isEmpty) {
        if (!mounted) return;
        _finish(false, tr('未能解析出任何歌曲'));
        return;
      }
      await _saveImported(name, songs);
    } catch (e) {
      if (!mounted) return;
      // PlatformException 只保留 message/code，避免 toast 出现原始异常文本
      _finish(
        false,
        e is PlatformException
            ? ((e.message ?? '').trim().isEmpty ? e.code : e.message!.trim())
            : tr('导入失败：{e}', {'e': e}),
      );
    }
  }

  /// Android SAF：递归列文件 → 逐个 openFd 解析，歌曲直接引用 content URI。
  /// 返回 null 表示已在收集阶段提示并结束。
  Future<List<ImportedSong>?> _collectSongsAndroid(String treeUri) async {
    final files = await SafChannel.listAudioTree(treeUri, _audioExtensions);
    if (files.isEmpty) {
      if (!mounted) return null;
      _finish(false, tr('所选文件夹中没有支持的音乐文件'));
      return null;
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
    return songs;
  }

  /// 鸿蒙：DocumentViewPicker 临时授权 → 列音频 → 物化到沙盒
  /// `Documents/PlaylistImports/<文件夹名>/` → 按真实路径逐个解析。
  /// 与曲库导入同一物化模型：授权不持久化，歌单引用沙盒副本，重启可用；
  /// 目录不在曲库扫描根下，符合「不会加入本地库扫描目录」的说明。
  Future<List<ImportedSong>?> _collectSongsOhos(String folderUri) async {
    final files =
        await OhosFolderChannel.listAudioFiles(folderUri, _audioExtensions);
    if (files.isEmpty) {
      if (!mounted) return null;
      _finish(false, tr('所选文件夹中没有支持的音乐文件'));
      return null;
    }
    if (!mounted) return null;
    setState(() => _total = files.length);

    final docs = await getApplicationDocumentsDirectory();
    final segs =
        Uri.parse(folderUri).pathSegments.where((s) => s.isNotEmpty);
    final folderName = segs.isEmpty ? 'imported' : segs.last;
    final destDir = Directory(p.join(docs.path, 'PlaylistImports', folderName));
    await destDir.create(recursive: true);
    await OhosFolderChannel.importFiles(
      folderUri: folderUri,
      rels: [for (final f in files) f.rel],
      destDir: destDir.path,
    );

    final songs = <ImportedSong>[];
    for (final f in files) {
      final file = File(p.join(
        destDir.path,
        f.rel.replaceFirst(RegExp(r'^/+'), ''),
      ));
      if (!file.existsSync()) continue;
      final ext = p
          .extension(f.name)
          .replaceFirst('.', '')
          .toLowerCase();
      try {
        final songJson = await parseAudioFromPathAndroid(
          filePath: file.path,
          fileName: f.name,
          pathKey: file.path,
          format: ext,
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
              localPath: file.path,
              path: file.path,
            ),
          );
        }
      } catch (e) {
        AppLog.debug('playlist', '解析音频失败，跳过 ${f.name}: $e');
      }
      if (mounted) setState(() => _parsed = songs.length);
    }
    return songs;
  }

  /// 网盘导入：递归收集所选文件夹（含子目录）音频，歌曲以 cloud:// 引用
  /// 入库（不落盘、不进本地库），播放走网盘直链管线。大文件夹遍历可能
  /// 花较长时间；个别子目录失败会被跳过，全部失败才报错。
  Future<void> _importFromCloud() async {
    final provider = _cloudProvider;
    final folders = _cloudFolders;
    if (provider == null || folders.isEmpty || _importing) return;
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
      final accountId = _cloudAccountId;
      var cred = await CloudCredentialsStore.instance.credFor(
        provider.id,
        accountId,
      );
      cred ??= await CloudCredentialsStore.instance.soleCredFor(provider.id);
      if (cred == null || cred.isEmpty) {
        if (!mounted) return;
        _finish(false, tr('网盘账号未绑定或已失效'));
        return;
      }
      final files = await cloudListAllAudio(
        provider: provider,
        cred: cred,
        selectedRoots: [for (final f in folders) f.$1],
      );
      if (files.isEmpty) {
        if (!mounted) return;
        _finish(false, tr('所选文件夹中没有支持的音乐文件'));
        return;
      }
      final songs = <ImportedSong>[];
      for (final f in files) {
        // 文件名拆「歌手 - 歌名」；无时长（播放器起播实测回填）
        final parts = parseCloudFileName(f.name);
        songs.add(
          importedSongFromQueueItem(
            cloudPlayQueueItem(
              CloudPlayContext(
                provider: provider.id,
                accountId: accountId,
                file: f,
              ),
              title: parts.title,
              artist: parts.artist ?? '',
            ),
          ),
        );
      }
      await _saveImported(name, songs);
    } catch (e) {
      if (!mounted) return;
      _finish(false, tr('导入失败：{e}', {'e': e}));
    }
  }

  Future<void> _saveImported(String name, List<ImportedSong> songs) async {
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
  }

  void _finish(bool ok, String message) {
    setState(() => _importing = false);
    showXianYuToast(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 已绑定网盘才提供网盘文件夹导入入口
    final boundProviders =
        ref.watch(boundCloudProvidersProvider).valueOrNull ??
        const <CloudProvider>[];
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
        PressableScale(
          child: InkWell(
            onTap: _importing ? null : _pickFolder,
            borderRadius: BorderRadius.circular(16),
            child: Container(
            height: 92,
            decoration: BoxDecoration(
              color: appCardFill(context, ref),
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
        ),
        if (boundProviders.isNotEmpty) ...[
          const SizedBox(height: 10),
          PressableScale(
            child: InkWell(
              onTap: _importing ? null : () => _pickCloudFolder(boundProviders),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                height: 92,
                decoration: BoxDecoration(
                  color: appCardFill(context, ref),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _isCloudImport
                        ? scheme.primary.withValues(alpha: 0.5)
                        : scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                alignment: Alignment.center,
                child: !_isCloudImport
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.cloud_outlined,
                            size: 30,
                            color: scheme.outline,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            tr('选择网盘文件夹'),
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
                            Icons.cloud_rounded,
                            size: 30,
                            color: scheme.primary,
                          ),
                          const SizedBox(height: 6),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              _cloudLabel,
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
          ),
        ],
        const SizedBox(height: 10),
        Text(
          _isCloudImport
              ? tr('将递归读取所选网盘文件夹（含子文件夹）中的音频文件并创建为独立歌单，歌曲保留网盘引用，播放时在线获取。')
              : tr('将递归读取所选文件夹中的音乐文件并创建为独立歌单，不会加入本地库扫描目录。'),
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        if (_importing) ...[
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _total > 0 ? _parsed / _total : null),
          const SizedBox(height: 6),
          Text(
            _total > 0
                ? '正在解析 $_parsed / $_total …'
                : _isCloudImport
                    ? tr('正在读取网盘文件夹…')
                    : tr('正在读取文件夹…'),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 18),
        PressableScale(
          pressScale: 0.92,
          child: FilledButton.icon(
            onPressed:
                (_importing || (_treeUri == null && !_isCloudImport))
                    ? null
                    : _import,
            icon: _importing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.library_add_check_outlined, size: 18),
            label: Text(_importing ? tr('导入中…') : tr('读取并创建')),
          ),
        ),
      ],
    );
  }
}
