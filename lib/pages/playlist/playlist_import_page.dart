import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/library/saf_channel.dart';
import '../../src/plugin/plugin_backup_import.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/playlist/playlist_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/add_to_playlist_sheet.dart'
    show importedSongFromQueueItem;
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
    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(
        title: const Text('导入歌单'),
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: '备份文件'),
            Tab(text: '本地文件'),
            Tab(text: '云端导入'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: const [
          _BackupImportTab(),
          _LocalFolderTab(),
          _CloudImportTab(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 1：备份文件导入（BakaMusic / MusicFree / 洛雪 JSON，URL / 本地 / 粘贴）
// ---------------------------------------------------------------------------

class _BackupImportTab extends ConsumerStatefulWidget {
  const _BackupImportTab();

  @override
  ConsumerState<_BackupImportTab> createState() => _BackupImportTabState();
}

class _BackupImportTabState extends ConsumerState<_BackupImportTab> {
  final _urlCtrl = TextEditingController();
  final _jsonCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _jsonCtrl.dispose();
    super.dispose();
  }

  Future<void> _import(String jsonContent) async {
    if (jsonContent.trim().isEmpty || _loading) return;
    setState(() => _loading = true);
    try {
      final sources = ref.read(pluginManagerProvider).sources;
      final prepared = preparePluginBackupImport(jsonContent, sources);
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

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _showResult(
      PreparedPluginBackupImport prepared, int createdCount) async {
    final versionNote = describeBackupVersion(prepared);
    await showDialog<void>(
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
        allowedExtensions: ['json', 'txt'],
      );
      if (files.isEmpty) return;
      final path = files.single.path;
      if (path == null) return;
      final content = await File(path).readAsString();
      await _import(content);
    } catch (e) {
      if (!mounted) return;
      _toast('读取文件失败：$e');
    }
  }

  Future<void> _importFromUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() => _loading = true);
    try {
      final content = await _fetch(url);
      if (content == null || content.isEmpty) {
        if (!mounted) return;
        _toast('无法获取备份文件');
        return;
      }
      await _import(content);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 与插件页一致的完整 Chrome UA，避免 WAF/CDN 拦截。
  Future<String?> _fetch(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(
          'User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      return await resp.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          '支持 BakaMusic / MusicFree / 洛雪音乐导出的备份 JSON，'
          '自动匹配已安装音源插件，本地文件路径的歌曲直接作为本地歌曲导入。',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _urlCtrl,
          enabled: !_loading,
          decoration: const InputDecoration(
            labelText: '备份文件 URL',
            hintText: 'https://example.com/backup.json',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _loading ? null : _pickLocalFile,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('选择本地文件'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _loading ? null : _importFromUrl,
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download, size: 18),
              label: const Text('从 URL 导入'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(child: Divider(color: scheme.outlineVariant)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('或粘贴 JSON 内容',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            ),
            Expanded(child: Divider(color: scheme.outlineVariant)),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _jsonCtrl,
          enabled: !_loading,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: '粘贴备份 JSON…',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            FilledButton(
              onPressed: _loading ? null : () => _import(_jsonCtrl.text),
              child: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('导入歌单'),
            ),
          ],
        ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地文件夹导入仅支持 Android 设备')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入歌单名称')),
      );
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: 92,
            decoration: BoxDecoration(
              color: appCardColor(context),
              borderRadius: BorderRadius.circular(12),
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
          '将递归读取所选文件夹中的音乐文件并创建为独立歌单，不会加入音乐库扫描目录。',
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
// Tab 3：云端导入（已安装 MusicFree 音源插件搜索歌单 → 拉取详情 → 建歌单）
// ---------------------------------------------------------------------------

class _CloudImportTab extends ConsumerStatefulWidget {
  const _CloudImportTab();

  @override
  ConsumerState<_CloudImportTab> createState() => _CloudImportTabState();
}

class _CloudImportTabState extends ConsumerState<_CloudImportTab> {
  final _keywordCtrl = TextEditingController();
  final _renameCtrl = TextEditingController();
  String? _selectedPluginId;
  bool _searching = false;
  bool _importing = false;
  List<MfSheetItem> _sheets = const [];
  String? _error;

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

  PluginSource? get _selected {
    final list = _plugins;
    if (list.isEmpty) return null;
    return list.where((s) => s.id == _selectedPluginId).firstOrNull ??
        list.first;
  }

  Future<void> _search() async {
    final keyword = _keywordCtrl.text.trim();
    final source = _selected;
    if (keyword.isEmpty || source == null || _searching) return;
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
        if (sheets.isEmpty) _error = '未找到匹配的歌单，换个关键词试试';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _importSheet(MfSheetItem sheet) async {
    final source = _selected;
    if (source == null || _importing) return;
    setState(() => _importing = true);
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final catalog = PluginCatalogService(
        engine,
        ref.read(pluginManagerProvider).sources,
      );

      // 分页拉取歌单全部曲目（安全上限 50 页）。
      final songs = <ImportedSong>[];
      var page = 1;
      while (page <= 50) {
        final results =
            await catalog.getMusicSheetInfo(source, sheet.raw, page: page);
        if (results.isEmpty) break;
        songs.addAll(results
            .map((r) =>
                importedSongFromQueueItem(PluginCatalogService.toQueueItem(source, r)))
            .toList());
        if (results.length < 30) break;
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

    final selected = _selected!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text('选择音源',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: selected.id,
          items: [
            for (final p in plugins)
              DropdownMenuItem(value: p.id, child: Text(p.name)),
          ],
          onChanged: (v) => setState(() => _selectedPluginId = v),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _keywordCtrl,
          enabled: !_searching && !_importing,
          decoration: const InputDecoration(
            labelText: '歌单名称或关键词',
            hintText: '输入歌单名称搜索并导入',
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
          '通过已安装的音源插件搜索在线歌单，点击搜索结果即可导入全部曲目。',
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
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
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
