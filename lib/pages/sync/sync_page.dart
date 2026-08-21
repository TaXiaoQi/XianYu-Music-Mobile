import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/account_api.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/core/settings.dart';
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = ref.watch(authProvider);
    final config = _config;

    return Scaffold(
      appBar: AppBar(title: const Text('同步与备份')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!auth.isLoggedIn)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
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
          _sectionTitle(context, '其他同步'),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '收藏、歌单、插件同步为桌面端专属功能，移动端暂不支持。',
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
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(icon, color: scheme.primary),
        title: Text(title, style: const TextStyle(fontSize: 15)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: _busy
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
