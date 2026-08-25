import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../src/auth/account_api.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/backup/app_backup.dart';
import '../../src/core/db_path.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/rust/api.dart';
import '../../src/sync/auto_sync.dart';

/// 同步与备份：设置同步（上传/下载）+ 自动同步调度。
class SyncPage extends ConsumerStatefulWidget {
  const SyncPage({super.key});

  @override
  ConsumerState<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends ConsumerState<SyncPage> {
  AutoSyncConfig? _config;
  bool _busy = false;
  bool _statsBusy = false;
  bool _backupBusy = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await ref.read(autoSyncProvider).getConfig();
    if (!mounted) return;
    setState(() => _config = config);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _uploadSettings() async {
    final settings = ref.read(settingsProvider).valueOrNull;
    if (settings == null) return;
    setState(() {
      _busy = true;
    });
    try {
      await ref.read(accountApiProvider).uploadSettings(settings);
      if (!mounted) return;
      _toast('设置已上传到云端');
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : '上传失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadSettings() async {
    setState(() {
      _busy = true;
    });
    try {
      final cloud = await ref.read(accountApiProvider).downloadSettings();
      if (!mounted) return;
      if (cloud == null || cloud.isEmpty) {
        _toast('云端暂无设置');
        return;
      }
      final local = ref.read(settingsProvider).valueOrNull;
      if (local == null) return;
      final merged = applySyncedSettings(local, cloud);
      await ref.read(settingsProvider.notifier).saveAll(merged);
      if (!mounted) return;
      _toast('已应用云端设置');
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : '下载失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveConfig(AutoSyncConfig next) async {
    setState(() => _config = next);
    await ref.read(autoSyncProvider).setConfig(next);
  }

  // ==================== 应用备份（歌单/收藏/插件/设置） ====================

  /// 导出完整应用备份并调起系统分享。
  Future<void> _exportBackup() async {
    if (_backupBusy) return;
    setState(() => _backupBusy = true);
    try {
      final service = ref.read(appBackupProvider);
      final json = await service.exportJson();
      final docs = await getApplicationDocumentsDirectory();
      final path = await writeBackupFile(docs.path, json);
      if (!mounted) return;
      _toast('备份已导出');
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], text: '弦予音乐应用备份'),
      );
    } catch (e) {
      if (!mounted) return;
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  /// 选择备份文件 → 预览摘要 → 选择导入内容 → 执行。
  Future<void> _importBackup() async {
    if (_backupBusy) return;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (files.isEmpty) return;
      final file = files.first;

      String content = '';
      final path = file.path ?? '';
      if (path.isNotEmpty && File(path).existsSync()) {
        content = await File(path).readAsString();
      } else {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          _toast('无法读取所选文件');
          return;
        }
        content = utf8.decode(bytes);
      }

      final service = ref.read(appBackupProvider);
      final backup = service.parse(content);
      final options = await _confirmBackupImport(service.summarize(backup));
      if (options == null) return;

      setState(() => _backupBusy = true);
      final result = await service.import(backup, includePlaylists: options.$1,
          includeFavorites: options.$2, includePlugins: options.$3, includeSettings: options.$4);
      if (!mounted) return;
      final parts = <String>[
        if (options.$1) '歌单 ${result.importedPlaylists}',
        if (options.$2) '收藏 ${result.importedFavorites}',
        if (options.$3)
          '插件 ${result.importedPlugins}'
          '${result.skippedPlugins > 0 ? '（跳过 ${result.skippedPlugins}）' : ''}',
        if (options.$4 && result.settingsApplied) '设置',
      ];
      _toast(parts.isEmpty ? '未导入任何内容' : '导入完成：${parts.join('，')}');
      if (result.errors.isNotEmpty && mounted) {
        await showDialog<void>(
          context: context,
          useRootNavigator: true,
          builder: (ctx) => AlertDialog(
            title: const Text('部分内容导入失败'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final e in result.errors)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(e, style: const TextStyle(fontSize: 12.5)),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    } on FormatException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  /// 导入确认对话框：摘要 + 导入内容勾选，返回 null 表示取消。
  Future<(bool, bool, bool, bool)?> _confirmBackupImport(
      AppBackupSummary summary) {
    var playlists = true;
    var favorites = true;
    var plugins = true;
    var settings = false;
    return showDialog<(bool, bool, bool, bool)>(
            context: context,
            useRootNavigator: true,
            builder: (ctx) => StatefulBuilder(
              builder: (ctx, setDialog) => AlertDialog(
                title: const Text('导入应用备份'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (summary.createdAt.isNotEmpty)
                      Text(
                          '备份时间：${summary.createdAt.length >= 19 ? summary.createdAt.substring(0, 19).replaceAll('T', ' ') : summary.createdAt}',
                          style: const TextStyle(fontSize: 12.5)),
                    const SizedBox(height: 6),
                    Text(
                      '歌单 ${summary.playlistCount} 个（${summary.totalSongs} 首）\n'
                      '收藏 ${summary.favoriteCount} 首、收藏集 ${summary.favoriteCollectionCount} 个\n'
                      '插件 ${summary.pluginCount} 个${summary.hasSettings ? '\n含设置' : ''}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    const SizedBox(height: 10),
                    const Text('选择导入内容：', style: TextStyle(fontSize: 12.5)),
                    _backupCheck('歌单', playlists, summary.playlistCount > 0,
                        (v) => setDialog(() => playlists = v ?? false)),
                    _backupCheck('收藏', favorites,
                        summary.favoriteCount + summary.favoriteCollectionCount > 0,
                        (v) => setDialog(() => favorites = v ?? false)),
                    _backupCheck('插件', plugins, summary.pluginCount > 0,
                        (v) => setDialog(() => plugins = v ?? false)),
                    _backupCheck(
                        '设置（覆盖当前设置）',
                        settings,
                        summary.hasSettings,
                        (v) => setDialog(() => settings = v ?? false)),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(ctx, (playlists, favorites, plugins, settings)),
                    child: const Text('导入'),
                  ),
                ],
              ),
            ),
          );
  }

  Widget _backupCheck(
      String label, bool value, bool enabled, ValueChanged<bool?> onChanged) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(label, style: const TextStyle(fontSize: 13.5)),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }

  // ==================== 统计备份（本地导入/导出） ====================

  /// 导出听歌统计到 JSON 文件并调起系统分享。
  Future<void> _exportStats() async {
    if (_statsBusy) return;
    setState(() => _statsBusy = true);
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final docs = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now();
      final name =
          'xianyu-stats-${stamp.year}${stamp.month.toString().padLeft(2, '0')}${stamp.day.toString().padLeft(2, '0')}-${stamp.hour}${stamp.minute.toString().padLeft(2, '0')}.json';
      final outPath = p.join(docs.path, name);
      final resultJson = await statsExportStatisticsFile(
        dbPath: dbPath,
        optionsJson: jsonEncode({'filePath': outPath, 'includeRecentPlays': true}),
      );
      final result = jsonDecode(resultJson) as Map<String, dynamic>;
      final filePath = result['filePath'] as String? ?? outPath;
      if (!mounted) return;
      _toast('统计已导出');
      await SharePlus.instance.share(
        ShareParams(files: [XFile(filePath)], text: '弦予音乐统计备份'),
      );
    } catch (e) {
      if (!mounted) return;
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _statsBusy = false);
    }
  }

  /// 选择统计备份文件 → 预览 → 确认导入。
  Future<void> _importStats() async {
    if (_statsBusy) return;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (files.isEmpty) return;
      final file = files.first;

      // Android content URI 只有 bytes，先落到临时文件供 Rust 读取。
      String path = file.path ?? '';
      if (path.isEmpty || !File(path).existsSync()) {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          _toast('无法读取所选文件');
          return;
        }
        final tmp = Directory.systemTemp;
        path = p.join(tmp.path, 'stats_import_${DateTime.now().millisecondsSinceEpoch}.json');
        await File(path).writeAsBytes(bytes);
      }

      setState(() => _statsBusy = true);
      final dbPath = await ref.read(dbPathProvider.future);
      final previewJson = await statsPreviewStatisticsImport(
        dbPath: dbPath,
        optionsJson: jsonEncode({'filePath': path}),
      );
      final preview =
          jsonDecode(previewJson) as Map<String, dynamic>;
      if (!mounted) return;

      final duplicate = preview['duplicateImportDetected'] as bool? ?? false;
      final mode = await _pickImportMode(preview, duplicate);
      if (mode == null) return;

      final resultJson = await statsImportStatisticsFile(
        dbPath: dbPath,
        optionsJson: jsonEncode({
          'filePath': path,
          'mode': mode,
          'continueDuplicateImport': duplicate,
        }),
      );
      final result = jsonDecode(resultJson) as Map<String, dynamic>;
      if (!mounted) return;
      final matched = result['matchedSongCount'] as num? ?? 0;
      final merged = result['mergedSongCount'] as num? ?? 0;
      _toast('导入完成：匹配 $matched 首，合并 $merged 首');
    } catch (e) {
      if (!mounted) return;
      _toast(e.toString().contains('已经导入过') ? '该备份已导入过' : '导入失败：$e');
    } finally {
      if (mounted) setState(() => _statsBusy = false);
    }
  }

  /// 导入模式选择：merge 合并 / overwrite 覆盖；重复导入时给出警示。
  Future<String?> _pickImportMode(
      Map<String, dynamic> preview, bool duplicate) {
    final songCount = preview['songStatsCount'] as num? ?? 0;
    final matched = preview['matchedSongCount'] as num? ?? 0;
    final unmatched = preview['unmatchedSongCount'] as num? ?? 0;
    final exportedAt = preview['exportedAt'] as String? ?? '';
    return showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('导入统计备份'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (exportedAt.isNotEmpty)
              Text('备份时间：$exportedAt', style: const TextStyle(fontSize: 12.5)),
            const SizedBox(height: 6),
            Text('歌曲统计 $songCount 条（匹配 $matched / 未匹配 $unmatched）',
                style: const TextStyle(fontSize: 12.5)),
            const SizedBox(height: 12),
            Text(
              duplicate ? '该备份似乎已导入过，继续可能产生重复数据' : '选择导入方式：合并保留现有数据，覆盖将清空后导入',
              style: TextStyle(
                  fontSize: 12,
                  color: duplicate
                      ? Theme.of(ctx).colorScheme.error
                      : Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'merge'),
            child: const Text('合并'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'overwrite'),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = ref.watch(authProvider);
    final config = _config;

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(title: const Text('同步与备份')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!auth.isLoggedIn)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: appCardColor(context),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: scheme.outline, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                      child: Text('登录后可同步设置到云端', style: TextStyle(fontSize: 13))),
                ],
              ),
            ),
          const SizedBox(height: 16),
          _sectionTitle(context, '设置同步'),
          _actionTile(
            context,
            icon: Icons.upload_outlined,
            title: '上传设置',
            subtitle: '将本地设置同步到云端',
            enabled: auth.isLoggedIn && !_busy,
            onTap: _uploadSettings,
          ),
          _actionTile(
            context,
            icon: Icons.download_outlined,
            title: '下载设置',
            subtitle: '从云端拉取并应用设置',
            enabled: auth.isLoggedIn && !_busy,
            onTap: _downloadSettings,
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, '自动同步'),
          if (config != null) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用自动同步', style: TextStyle(fontSize: 15)),
              subtitle: const Text('定时将设置同步到云端', style: TextStyle(fontSize: 12)),
              value: config.enabled,
              onChanged: auth.isLoggedIn
                  ? (v) => _saveConfig(config.copyWith(enabled: v))
                  : null,
            ),
            if (config.enabled) ...[
              _intervalTile(context, config),
              _maxDelayTile(context, config),
            ],
          ],
          const SizedBox(height: 20),
          _sectionTitle(context, '应用备份'),
          _actionTile(
            context,
            icon: Icons.archive_outlined,
            title: '导出应用备份',
            subtitle: '歌单、收藏、插件、设置备份为 JSON 并分享',
            enabled: !_backupBusy,
            busy: _backupBusy,
            onTap: _exportBackup,
          ),
          _actionTile(
            context,
            icon: Icons.settings_backup_restore_outlined,
            title: '导入应用备份',
            subtitle: '从备份文件恢复（支持选择导入内容）',
            enabled: !_backupBusy,
            busy: _backupBusy,
            onTap: _importBackup,
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, '统计备份'),
          _actionTile(
            context,
            icon: Icons.file_upload_outlined,
            title: '导出统计',
            subtitle: '听歌统计备份为 JSON 并分享',
            enabled: !_statsBusy,
            busy: _statsBusy,
            onTap: _exportStats,
          ),
          _actionTile(
            context,
            icon: Icons.file_download_outlined,
            title: '导入统计',
            subtitle: '从备份文件恢复统计（支持合并/覆盖）',
            enabled: !_statsBusy,
            busy: _statsBusy,
            onTap: _importStats,
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, '其他同步'),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: appCardColor(context),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '歌单、收藏、插件的同步与上传位于「账号与安全」页的云端同步板块。',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary)),
    );
  }

  Widget _actionTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool enabled,
    bool busy = false,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(icon, color: scheme.primary),
        title: Text(title, style: const TextStyle(fontSize: 15)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: busy
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(Icons.chevron_right, color: scheme.outline),
        enabled: enabled,
        onTap: enabled ? onTap : null,
      ),
    );
  }

  Widget _intervalTile(BuildContext context, AutoSyncConfig config) {
    const options = [
      (value: 1800, label: '30 分钟'),
      (value: 3600, label: '1 小时'),
      (value: 7200, label: '2 小时'),
      (value: 21600, label: '6 小时'),
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('同步间隔', style: TextStyle(fontSize: 15)),
      trailing: DropdownButton<int>(
        value: config.syncIntervalSeconds,
        underline: const SizedBox.shrink(),
        items: [
          for (final o in options)
            DropdownMenuItem(value: o.value, child: Text(o.label)),
        ],
        onChanged: (v) {
          if (v != null) _saveConfig(config.copyWith(syncIntervalSeconds: v));
        },
      ),
    );
  }

  Widget _maxDelayTile(BuildContext context, AutoSyncConfig config) {
    const options = [
      (value: 15, label: '15 分钟'),
      (value: 30, label: '30 分钟'),
      (value: 60, label: '1 小时'),
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('繁忙延后上限', style: TextStyle(fontSize: 15)),
      subtitle: const Text('服务器繁忙时自动延后同步的最大时长',
          style: TextStyle(fontSize: 12)),
      trailing: DropdownButton<int>(
        value: config.maxDelayMinutes,
        underline: const SizedBox.shrink(),
        items: [
          for (final o in options)
            DropdownMenuItem(value: o.value, child: Text(o.label)),
        ],
        onChanged: (v) {
          if (v != null) _saveConfig(config.copyWith(maxDelayMinutes: v));
        },
      ),
    );
  }
}
