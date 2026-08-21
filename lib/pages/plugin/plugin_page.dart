import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/plugin/plugin_backup_import.dart';
import '../../src/plugin/plugin_engine.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/plugin/plugin_updates.dart';
import '../../src/playlist/playlist_provider.dart';

/// 插件管理页：列表、安装（URL/脚本）、启用禁用、卸载、更新。
class PluginPage extends ConsumerStatefulWidget {
  const PluginPage({super.key});

  @override
  ConsumerState<PluginPage> createState() => _PluginPageState();
}

class _PluginPageState extends ConsumerState<PluginPage> {
  bool _installing = false;
  bool _checkingUpdates = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pluginManagerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('插件'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: '导入备份歌单',
            onPressed: _showBackupImportSheet,
          ),
          IconButton(
            icon: const Icon(Icons.system_update_alt_outlined),
            tooltip: '检查全部更新',
            onPressed: _checkingUpdates ? null : _checkAllUpdates,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '安装插件',
            onPressed: _installing ? null : _showInstallSheet,
          ),
        ],
      ),
      body: state.loading
          ? const Center(child: CircularProgressIndicator())
          : state.sources.isEmpty
              ? _EmptyState(onInstall: _showInstallSheet)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 150),
                  itemCount: state.sources.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _PluginCard(source: state.sources[index]),
                ),
    );
  }

  void _showInstallSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _InstallSheet(
        onInstall: (script, name) => _install(script, name),
      ),
    );
  }

  Future<void> _install(String script, String name) async {
    if (script.trim().isEmpty) return;
    setState(() => _installing = true);
    try {
      final source = await ref
          .read(pluginManagerProvider.notifier)
          .installFromScript(script, fileName: name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('插件「${source.name}」安装成功')),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e is PluginEngineException ? e.message : e.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('安装失败：$msg')),
      );
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<PluginUpdateService> _updateService() async {
    final engine = await ref.read(pluginEngineProvider.future);
    return PluginUpdateService(engine, ref.read(pluginManagerProvider.notifier));
  }

  void _showBackupImportSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _BackupImportSheet(
        onImport: _importBackup,
      ),
    );
  }

  Future<void> _importBackup(String jsonContent) async {
    if (jsonContent.trim().isEmpty) return;
    try {
      final sources = ref.read(pluginManagerProvider).sources;
      final prepared = preparePluginBackupImport(jsonContent, sources);
      final playlists = await ref
          .read(playlistManagerProvider.notifier)
          .addFromBackup(prepared);
      if (!mounted) return;
      await _showBackupResult(prepared, playlists.length);
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  Future<void> _showBackupResult(
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
                Text('关联插件：',
                    style: const TextStyle(
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

  Future<void> _checkAllUpdates() async {
    setState(() => _checkingUpdates = true);
    try {
      final service = await _updateService();
      final results = await service.checkAll();
      if (!mounted) return;
      final updateCount =
          results.values.where((r) => r.hasUpdate).length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(updateCount > 0
              ? '发现 $updateCount 个插件可更新'
              : '所有插件均为最新版本'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('检查更新失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onInstall});
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.extension_outlined, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text('还没有安装插件', style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(
            '支持 LX / MusicFree 格式音源插件',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onInstall,
            icon: const Icon(Icons.add),
            label: const Text('安装插件'),
          ),
        ],
      ),
    );
  }
}

class _PluginCard extends ConsumerWidget {
  const _PluginCard({required this.source});
  final PluginSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(pluginManagerProvider.notifier);

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            // 图标
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                source.format == PluginFormat.lx
                    ? Icons.music_note
                    : Icons.extension,
                color: scheme.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            // 名称 + 版本 + 音源
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          source.name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (source.version.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          'v${source.version}',
                          style: TextStyle(
                              fontSize: 12, color: scheme.outline),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    source.author.isEmpty
                        ? (source.format == PluginFormat.lx ? 'LX 插件' : 'MusicFree 插件')
                        : source.author,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (source.sources.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      '音源：${source.sources.join(' / ')}',
                      style:
                          TextStyle(fontSize: 11, color: scheme.outline),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // 更新
            IconButton(
              icon: Icon(Icons.system_update_alt_outlined,
                  size: 20, color: scheme.outline),
              tooltip: '检查更新',
              onPressed: () => _checkUpdate(context, ref),
            ),
            // 卸载
            IconButton(
              icon: Icon(Icons.delete_outline, size: 20, color: scheme.outline),
              tooltip: '卸载',
              onPressed: () => _confirmRemove(context, manager),
            ),
            // 启用开关
            Switch(
              value: source.enabled,
              onChanged: (_) => manager.toggleEnabled(source.id),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkUpdate(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final engine = await ref.read(pluginEngineProvider.future);
    final service =
        PluginUpdateService(engine, ref.read(pluginManagerProvider.notifier));
    final result = await service.checkPluginUpdate(source);
    if (!context.mounted) return;
    if (result == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('无可用更新源')));
      return;
    }
    if (!result.hasUpdate) {
      messenger.showSnackBar(
          SnackBar(content: Text('「${source.name}」已是最新版本')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发现新版本'),
        content: Text(
            '「${source.name}」\n当前版本：v${result.currentVersion}\n'
            '新版本：v${result.newVersion}\n\n是否立即更新？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('更新'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final outcome = await service.performPluginUpdate(source, result);
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(outcome.message)),
    );
  }

  void _confirmRemove(BuildContext context, PluginManager manager) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载插件'),
        content: Text('确定要卸载「${source.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              manager.remove(source.id);
            },
            child: const Text('卸载'),
          ),
        ],
      ),
    );
  }
}

/// 安装方式选择：URL 或脚本粘贴。
class _InstallSheet extends StatefulWidget {
  const _InstallSheet({required this.onInstall});
  final void Function(String script, String name) onInstall;

  @override
  State<_InstallSheet> createState() => _InstallSheetState();
}

class _InstallSheetState extends State<_InstallSheet> {
  final _urlCtrl = TextEditingController();
  final _scriptCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _scriptCtrl.dispose();
    super.dispose();
  }

  Future<void> _installFromUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() => _loading = true);
    try {
      final script = await _fetch(url);
      if (script == null || script.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法获取插件脚本')));
        return;
      }
      widget.onInstall(script, url);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _fetch(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36');
      final resp = await req.close().timeout(const Duration(seconds: 15));
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
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('安装插件',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '支持 LX（落雪）与 MusicFree 格式音源插件',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: '插件 URL',
                hintText: 'https://example.com/plugin.js',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton.icon(
                  onPressed: _loading ? null : _installFromUrl,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download, size: 18),
                  label: const Text('从 URL 安装'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Divider(color: scheme.outlineVariant),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('或粘贴脚本内容',
                      style: TextStyle(fontSize: 12, color: scheme.outline)),
                ),
                Expanded(child: Divider(color: scheme.outlineVariant)),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _scriptCtrl,
              maxLines: 6,
              decoration: const InputDecoration(
                hintText: '粘贴插件 JS 脚本…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    widget.onInstall(_scriptCtrl.text, '粘贴脚本');
                    Navigator.pop(context);
                  },
                  child: const Text('安装'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 备份歌单导入：URL 或 JSON 粘贴。
class _BackupImportSheet extends StatefulWidget {
  const _BackupImportSheet({required this.onImport});
  final void Function(String jsonContent) onImport;

  @override
  State<_BackupImportSheet> createState() => _BackupImportSheetState();
}

class _BackupImportSheetState extends State<_BackupImportSheet> {
  final _urlCtrl = TextEditingController();
  final _jsonCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _jsonCtrl.dispose();
    super.dispose();
  }

  Future<void> _importFromUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() => _loading = true);
    try {
      final content = await _fetch(url);
      if (content == null || content.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法获取备份文件')));
        return;
      }
      widget.onImport(content);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _fetch(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36');
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
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('导入备份歌单',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '支持 BakaMusic / MusicFree / 洛雪音乐导出的备份 JSON',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: '备份文件 URL',
                hintText: 'https://example.com/backup.json',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
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
            const SizedBox(height: 16),
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
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    widget.onImport(_jsonCtrl.text);
                    Navigator.pop(context);
                  },
                  child: const Text('导入'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
