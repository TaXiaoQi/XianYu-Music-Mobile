import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/library/library_provider.dart';
import '../../src/library/saf_channel.dart';
import '../../src/plugin/plugin_backup_file.dart';
import '../../src/plugin/plugin_backup_import.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/playlist/playlist_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/add_to_playlist_sheet.dart'
    show importedSongFromQueueItem;
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/online_cover.dart';

/// 导入歌单页：备份文件 / 本地文件 / 云端导入 三种方式
/// （对齐桌面端导入歌单弹窗，独立成页不与音源页共用）。
class PlaylistImportPage extends ConsumerStatefulWidget {
  const PlaylistImportPage({super.key});

  @override
  ConsumerState<PlaylistImportPage> createState() =>
      _PlaylistImportPageState();
}

class _PlaylistImportPageState extends ConsumerState<PlaylistImportPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabBar = TabBar(
      controller: _tabCtrl,
      tabs: const [
        Tab(text: '备份文件'),
        Tab(text: '本地文件'),
        Tab(text: '云端导入'),
      ],
    );
    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(
              top: GlassTopBar.height(context, bottom: tabBar),
            ),
            child: TabBarView(
              controller: _tabCtrl,
              children: const [
                _BackupImportTab(),
                _LocalFolderTab(),
                _CloudImportTab(),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: const Text('导入歌单'),
              bottom: tabBar,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 1：备份文件导入（BakaMusic / MusicFree / 洛雪 备份，选择本地文件）
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
      final isPlaylist = lowerName.endsWith('.m3u') ||
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
          // .txt 可能是 JSON 备份：播放列表解析失败时回退 JSON 解析。
          if (lowerName.endsWith('.txt')) {
            prepared = preparePluginBackupImport(
                extractBackupJsonBytes(bytes, name), sources);
          } else {
            rethrow;
          }
        }
      } else {
        final jsonContent = extractBackupJsonBytes(bytes, name);
        prepared = preparePluginBackupImport(jsonContent, sources);
      }

      final playlists = await ref
          .read(playlistManagerProvider.notifier)
          .addFromBackup(prepared);
      if (!mounted) return;
      await _showResult(prepared, playlists.length);
    } on FormatException catch (e) {
      if (!mounted) return;
      _toast('导入失败：${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 本地曲库歌曲引用（供 M3U/TXT 导入时把跨设备失效路径匹配回本地）。
  List<LocalSongRef> _localSongRefs() {
    final library = ref.read(libraryProvider);
    return library.songs
        .map((s) => (
              path: s.path,
              title: s.title,
              artist: s.artist,
              duration: s.duration,
            ))
        .toList();
  }

  void _toast(String msg) {
    showXianYuToast(context, msg);
  }

  Future<void> _showResult(
      PreparedPluginBackupImport prepared, int createdCount) async {
    final versionNote = describeBackupVersion(prepared);
    await showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入完成'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$versionNote\n'
                '新增 $createdCount 个歌单，'
                '成功导入 ${prepared.importedSongCount} 首歌曲，'
                '${prepared.failures.length} 首未导入。',
                style: const TextStyle(fontSize: 14),
              ),
              if (prepared.missingPlugins.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('缺失插件：',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(ctx).colorScheme.error)),
                const SizedBox(height: 4),
                for (final missing in prepared.missingPlugins)
                  Text(
                    '· ${missing.platform}（${missing.songCount} 首）',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                  ),
              ],
              if (prepared.associations.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('关联插件：',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                for (final assoc in prepared.associations)
                  Text(
                    '· ${assoc.pluginName} → ${assoc.platform}（${assoc.songCount} 首）',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好的'),
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
      _toast('读取文件失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          '支持 BakaMusic / MusicFree / 洛雪音乐备份（JSON、ZIP、lxmc）与 '
          'M3U/M3U8 播放列表、椒盐音乐 TXT 导出，自动匹配已安装音源插件，'
          '本地路径歌曲匹配本地曲库导入。',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Center(
          child: OutlinedButton.icon(
            onPressed: _loading ? null : _pickLocalFile,
            icon: const Icon(Icons.folder_open, size: 24),
            label: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('选择本地备份文件', style: TextStyle(fontSize: 15)),
            ),
          ),
        ),
        if (_loading) ...[
          const SizedBox(height: 20),
          const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 2：本地文件夹导入（SAF 选目录 → fd 解析 → 创建本地歌曲歌单）
// ---------------------------------------------------------------------------

class _LocalFolderTab extends ConsumerStatefulWidget {
  const _LocalFolderTab();

  @override
  ConsumerState<_LocalFolderTab> createState() => _LocalFolderTabState();
}

class _LocalFolderTabState extends ConsumerState<_LocalFolderTab> {
  /// SAF 枚举白名单（与曲库扫描一致的音频扩展名）。
  static const _audioExtensions = [
    'flac', 'mp3', 'wav', 'aac', 'm4a', 'm4b', 'mp4',
    'ogg', 'oga', 'aif', 'aiff', 'dsf', 'dff',
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
      showXianYuToast(context, '本地文件夹导入仅支持 Android 设备');
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
      final segments =
          name.split('/').where((s) => s.trim().isNotEmpty).toList();
      _nameCtrl.text = segments.isNotEmpty ? segments.last : name;
    }
  }

  Future<void> _import() async {
    final treeUri = _treeUri;
    if (treeUri == null || _importing) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      showXianYuToast(context, '请输入歌单名称');
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
        _finish(false, '所选文件夹中没有支持的音乐文件');
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
            songs.add(ImportedSong(
              title: (parsed['title'] as String? ?? '').isNotEmpty
                  ? parsed['title'] as String
                  : f.name,
              artist: parsed['artist'] as String? ?? '',
              album: parsed['album'] as String? ?? '',
              duration: (parsed['duration'] as num?)?.toInt() ?? 0,
              localPath: path,
              path: path,
            ));
          }
        } catch (_) {
          // 单文件解析失败跳过
        } finally {
          await SafChannel.closeFd(fd);
        }
        if (mounted) setState(() => _parsed = songs.length);
      }

      if (songs.isEmpty) {
        if (!mounted) return;
        _finish(false, '未能解析出任何歌曲');
        return;
      }

      final manager = ref.read(playlistManagerProvider.notifier);
      await manager.create(name);
      final created = ref.read(playlistManagerProvider).playlists;
      if (created.isEmpty) {
        if (!mounted) return;
        _finish(false, '歌单创建失败');
        return;
      }
      await manager.addSongs(created.last.id, songs);
      if (!mounted) return;
      _finish(true, '已创建歌单「$name」，共导入 ${songs.length} 首歌曲');
    } catch (e) {
      if (!mounted) return;
      _finish(false, '导入失败：$e');
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
          decoration: const InputDecoration(
            labelText: '歌单名称 *',
            hintText: '请输入新歌单名称',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        Text('音乐文件夹 *',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
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
                      Icon(Icons.folder_open_outlined,
                          size: 30, color: scheme.outline),
                      const SizedBox(height: 6),
                      Text('点击选择包含音乐的文件夹',
                          style: TextStyle(
                              fontSize: 12.5, color: scheme.onSurfaceVariant)),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_rounded,
                          size: 30, color: scheme.primary),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          _folderName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '将递归读取所选文件夹中的音乐文件并创建为独立歌单，不会加入本地库扫描目录。',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        if (_importing) ...[
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: _total > 0 ? _parsed / _total : null,
          ),
          const SizedBox(height: 6),
          Text(
            _total > 0 ? '正在解析 $_parsed / $_total …' : '正在读取文件夹…',
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
          label: Text(_importing ? '导入中…' : '读取并创建'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 3：云端导入（MusicFree 插件搜索歌单/链接自动识别平台 → 拉取详情 → 建歌单）
// ---------------------------------------------------------------------------

class _CloudImportTab extends ConsumerStatefulWidget {
  const _CloudImportTab();

  @override
  ConsumerState<_CloudImportTab> createState() => _CloudImportTabState();
}

class _CloudImportTabState extends ConsumerState<_CloudImportTab> {
  /// 「自动识别」下拉项占位 key。
  static const _autoKey = '__auto__';

  /// 当前下拉框选中值：插件 id 或 [_autoKey]（自动识别）。
  String? _selectedPluginId;
  /// 自动识别解析出的插件（供导入步骤复用，避免用户切换下拉后再搜索）。
  PluginSource? _resolved;
  bool _searching = false;
  bool _importing = false;
  List<MfSheetItem> _sheets = const [];
  String? _error;
  final _keywordCtrl = TextEditingController();
  final _renameCtrl = TextEditingController();

  @override
  void dispose() {
    _keywordCtrl.dispose();
    _renameCtrl.dispose();
    super.dispose();
  }

  List<PluginSource> get _plugins => ref
      .watch(pluginManagerProvider)
      .sources
      .where((s) => s.enabled && s.format == PluginFormat.musicfree)
      .toList();

  /// 当前下拉框选中的具体插件（自动识别或无有效选择时为 null）。
  PluginSource? get _selected {
    final id = _selectedPluginId;
    if (id == null || id.isEmpty || id == _autoKey) return null;
    return _plugins.where((s) => s.id == id).firstOrNull;
  }

  /// 各平台匹配关键词（对标桌面端 parseLink 支持的网易云/QQ音乐/酷我/酷狗）。
  static const Map<String, List<String>> _platformKeywords = {
    'netease': ['网易云', 'netease', 'wy'],
    'qq': ['qq音乐', 'qqmusic', '腾讯', 'tx', 'qq'],
    'kuwo': ['kuwo', '酷我', 'kw'],
    'kugou': ['kugou', '酷狗', 'kg'],
  };

  /// 从分享链接识别平台 key（netease/qq/kuwo/kugou），识别不出返回 null。
  String? _detectPlatformFromUrl(String input) {
    final t = input.toLowerCase();
    if (t.contains('music.163.com') ||
        t.contains('163cn.tv') ||
        t.contains('163.com/playlist')) {
      return 'netease';
    }
    if (t.contains('y.qq.com') || t.contains('c.y.qq.com')) return 'qq';
    if (t.contains('kuwo.cn')) return 'kuwo';
    if (t.contains('kugou.com') || t.contains('t.kugou.com')) {
      return 'kugou';
    }
    return null;
  }

  PluginSource? _matchPluginByPlatform(
      String canonical, List<PluginSource> plugins) {
    final keywords = _platformKeywords[canonical] ?? const [];
    for (final p in plugins) {
      for (final label in [p.name, ...p.sources]) {
        final n = _normPlatform(label);
        for (final k in keywords) {
          final nk = _normPlatform(k);
          if (n == nk || (nk.length >= 2 && n.contains(nk))) return p;
        }
      }
    }
    return null;
  }

  String _normPlatform(Object? v) => (v?.toString() ?? '')
      .replaceAll(RegExp(r'[\s_.\-—/\\()[\]（）【】·]+'), '')
      .replaceAll(RegExp(r'(?:音乐|music|音源|source)+$'), '')
      .toLowerCase();

  Future<void> _search() async {
    final keyword = _keywordCtrl.text.trim();
    if (keyword.isEmpty || _searching) return;

    final plugins = _plugins;
    var source = _selected;
    if (source == null) {
      // 自动识别：从分享链接识别平台并匹配已安装插件。
      // 纯歌单 ID 无法确定平台，若只装了一个插件则直接使用，否则提示选择音源。
      final canonical = _detectPlatformFromUrl(keyword);
      if (canonical != null) {
        source = _matchPluginByPlatform(canonical, plugins);
        if (source == null) {
          setState(() {
            _error = '未找到支持该平台的音源插件，请先安装对应插件';
          });
          return;
        }
      } else if (plugins.length == 1) {
        source = plugins.first;
      } else {
        setState(() {
          _error = '无法识别歌单链接，请选择对应音源后重试，或直接粘贴分享链接';
        });
        return;
      }
      _resolved = source;
    }

    setState(() {
      _searching = true;
      _error = null;
      _sheets = const [];
    });
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final catalog = PluginCatalogService(
        engine,
        ref.read(pluginManagerProvider).sources,
      );
      final sheets = await catalog.searchSheets(source, keyword);
      if (!mounted) return;
      setState(() {
        _sheets = sheets;
        if (sheets.isEmpty) _error = '未找到匹配的歌单，换个关键词或链接试试';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _importSheet(MfSheetItem sheet) async {
    // 歌单可能来自自动识别的插件，优先按返回结果的 pluginId 定位，避免选错源。
    final plugins = _plugins;
    final sheetPlugin =
        plugins.where((p) => p.id == sheet.pluginId).firstOrNull;
    final source = sheetPlugin ?? _resolved ?? _selected;
    if (source == null || _importing) return;
    setState(() => _importing = true);
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final catalog = PluginCatalogService(
        engine,
        ref.read(pluginManagerProvider).sources,
      );

      // 分页拉取歌单全部曲目（安全上限 50 页）。
      // 以插件返回的 isEnd 判断是否还有下一页，避免按返回数量猜页大小（如每页 20 首）
      // 导致提前截断丢歌；同时按 songmid|标题|歌手 去重，兼容忽略 page 参数每页返回同一批的插件。
      final songs = <ImportedSong>[];
      final seen = <String>{};
      var page = 1;
      var maxPageSize = 0;
      final total = sheet.trackCount ?? 0;
      while (page <= 50) {
        final result = await catalog.getMusicSheetInfoWithEnd(
            source, sheet.raw, page: page);
        final results = result.songs;
        if (results.isEmpty) break;
        final fresh = results.where((r) {
          final key = '${r.songmid}|${r.name}|${r.singer}';
          return seen.add(key);
        }).toList();
        if (fresh.isEmpty) break;
        songs.addAll(fresh
            .map((r) =>
                importedSongFromQueueItem(PluginCatalogService.toQueueItem(source, r)))
            .toList());
        if (result.isEnd == true) break;
        if (total > 0 && songs.length >= total) break;
        if (results.length > maxPageSize) maxPageSize = results.length;
        if (results.length < maxPageSize) break;
        page++;
      }

      if (songs.isEmpty) {
        if (!mounted) return;
        _toast('歌单为空或获取失败');
        return;
      }

      final rename = _renameCtrl.text.trim();
      final name = rename.isNotEmpty ? rename : sheet.title;
      final manager = ref.read(playlistManagerProvider.notifier);
      await manager.create(name);
      final created = ref.read(playlistManagerProvider).playlists;
      if (created.isEmpty) {
        if (!mounted) return;
        _toast('歌单创建失败');
        return;
      }
      await manager.addSongs(created.last.id, songs);
      if (!mounted) return;
      _toast('已导入「$name」，共 ${songs.length} 首歌曲');
    } catch (e) {
      if (!mounted) return;
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _toast(String msg) {
    showXianYuToast(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plugins = _plugins;

    if (plugins.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 52, color: scheme.outline),
              const SizedBox(height: 12),
              Text('暂无可用的音源插件',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Text(
                '先在 设置 → 音源 安装并启用插件，再回来导入在线歌单',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
          ),
        ),
      );
    }

    // 下拉框选中值自净化：已被卸载的插件回退到自动识别。
    var selected = _selectedPluginId;
    if (selected != null &&
        selected != _autoKey &&
        !plugins.any((p) => p.id == selected)) {
      selected = _autoKey;
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text('选择音源',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: selected ?? _autoKey,
          items: [
            const DropdownMenuItem(
              value: _autoKey,
              child: Text('自动识别'),
            ),
            for (final p in plugins)
              DropdownMenuItem(value: p.id, child: Text(p.name)),
          ],
          onChanged: (v) => setState(() {
            _selectedPluginId = v;
            _resolved = null;
          }),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _keywordCtrl,
          enabled: !_searching && !_importing,
          onSubmitted: (_) => _search(),
          decoration: const InputDecoration(
            labelText: '歌单分享链接或歌单 ID',
            hintText: '粘贴歌单分享链接或输入歌单 ID',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _renameCtrl,
          enabled: !_importing,
          decoration: const InputDecoration(
            labelText: '歌单重命名（可选）',
            hintText: '导入后给歌单起个新名字',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '选择「自动识别」直接粘贴网易云/QQ音乐/酷我/酷狗的分享链接，或选择对应音源后输入歌单 ID，点击搜索即可导入全部曲目。',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: (_searching || _importing) ? null : _search,
          icon: _searching
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search, size: 18),
          label: const Text('搜索歌单'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.errorContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(_error!,
                style:
                    TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ),
        ],
        if (_sheets.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('搜索结果 · ${_sheets.length}',
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final sheet in _sheets)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: appCardColor(context),
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _importing ? null : () => _importSheet(sheet),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(
                      children: [
                        OnlineCover(url: sheet.coverUrl, size: 48, radius: 8),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                sheet.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                sheet.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        if (_importing)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Icon(Icons.download_for_offline_outlined,
                              size: 22, color: scheme.primary),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
