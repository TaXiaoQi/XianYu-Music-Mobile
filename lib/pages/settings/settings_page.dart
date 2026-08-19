import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/settings.dart';
import '../../src/auth/auth_provider.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final notifier = ref.read(settingsProvider.notifier);
    final auth = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 150),
        children: [
          _sectionHeader(context, '账号'),
          _tile(
            context,
            icon: Icons.account_circle,
            title: '账号与安全',
            trailing: Text(
              auth.isLoggedIn ? auth.user!.nickname : '未登录',
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            onTap: () => context.push('/account'),
          ),
          _sectionHeader(context, '外观'),
          _tile(
            context,
            icon: Icons.palette,
            title: '主题模式',
            trailing: _themeLabel(settings),
            onTap: () => _pickThemeMode(context, ref, settings),
          ),
          _tile(
            context,
            icon: Icons.color_lens,
            title: '主题色',
            trailing: _ColorDot(color: Color(settings?.accentColor ?? 0xFFEC4141)),
            onTap: () => _pickAccentColor(context, ref, settings),
          ),
          _sectionHeader(context, '播放'),
          _tile(context, icon: Icons.volume_up, title: '音量',
              trailing: _volumeSlider(settings, notifier)),
          _tile(
            context,
            icon: Icons.high_quality,
            title: '在线默认音质',
            trailing: Text(settings?.onlineDefaultQuality ?? '320k'),
            onTap: () => _pickQuality(context, ref, settings, isOnline: true),
          ),
          _sectionHeader(context, '歌词'),
          _switchTile(
            context,
            icon: Icons.translate,
            title: '显示翻译',
            value: settings?.showLyricsTranslation ?? true,
            onChanged: (v) => notifier.setShowLyricsTranslation(v),
          ),
          _switchTile(
            context,
            icon: Icons.spellcheck,
            title: '逐字动效',
            value: settings?.enableWordEffect ?? true,
            onChanged: (v) => notifier.setEnableWordEffect(v),
          ),
          _sectionHeader(context, '音乐库'),
          _tile(
            context,
            icon: Icons.timer,
            title: '排除短音频（秒）',
            trailing: Text('${settings?.libraryMinDurationSeconds ?? 0}'),
            onTap: () => _pickMinDuration(context, ref, settings),
          ),
          _switchTile(
            context,
            icon: Icons.verified,
            title: '显示音质标识',
            value: settings?.showQualityBadges ?? true,
            onChanged: (v) => notifier.setShowQualityBadges(v),
          ),
          _sectionHeader(context, '下载'),
          _tile(
            context,
            icon: Icons.folder,
            title: '下载路径',
            trailing: Text(
              settings?.downloadPath == null || settings!.downloadPath.isEmpty
                  ? '默认'
                  : '自定义',
            ),
            onTap: () => _pickDownloadPath(context, ref, settings),
          ),
          _tile(
            context,
            icon: Icons.download,
            title: '下载音质',
            trailing: Text(settings?.downloadQuality ?? '320k'),
            onTap: () => _pickQuality(context, ref, settings, isOnline: false),
          ),
          _switchTile(
            context,
            icon: Icons.lyrics,
            title: '同时下载歌词',
            value: settings?.downloadLyrics ?? true,
            onChanged: (v) => notifier.setDownloadLyrics(v),
          ),
          _sectionHeader(context, '其他'),
          _switchTile(
            context,
            icon: Icons.screen_lock_rotation,
            title: '保持屏幕常亮',
            value: settings?.keepScreenOn ?? true,
            onChanged: (v) => notifier.setKeepScreenOn(v),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _tile(BuildContext context,
      {required IconData icon,
      required String title,
      required Widget trailing,
      VoidCallback? onTap}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: onTap == null
          ? trailing
          : Row(mainAxisSize: MainAxisSize.min, children: [
              trailing,
              const SizedBox(width: 4),
              Icon(Icons.chevron_right,
                  size: 18, color: Theme.of(context).colorScheme.outline),
            ]),
      onTap: onTap,
    );
  }

  Widget _switchTile(BuildContext context,
      {required IconData icon,
      required String title,
      required bool value,
      required ValueChanged<bool> onChanged}) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _themeLabel(AppSettings? s) {
    return Text(switch (s?.themeMode ?? ThemeModePreference.system) {
      ThemeModePreference.system => '跟随系统',
      ThemeModePreference.light => '浅色',
      ThemeModePreference.dark => '深色',
    });
  }

  Widget _volumeSlider(AppSettings? s, SettingsNotifier n) {
    return SizedBox(
      width: 120,
      child: Slider(
        value: s?.volume ?? 1.0,
        onChanged: (v) => n.setVolume(v),
      ),
    );
  }

  Future<void> _pickThemeMode(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.themeMode ?? ThemeModePreference.system;
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      builder: (_) => _choiceSheet(context, const [
        _Choice('跟随系统', ThemeModePreference.system),
        _Choice('浅色', ThemeModePreference.light),
        _Choice('深色', ThemeModePreference.dark),
      ], cur, labelOf: (v) => switch (v) {
        ThemeModePreference.system => '跟随系统',
        ThemeModePreference.light => '浅色',
        ThemeModePreference.dark => '深色',
        _ => '跟随系统',
      }),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setThemeMode(choice.value as ThemeModePreference);
    }
  }

  Future<void> _pickAccentColor(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.accentColor ?? 0xFFEC4141;
    const colors = [
      0xFFEC4141, 0xFFE64A2E, 0xFFFF8A00, 0xFF4CAF50, 0xFF2196F3,
      0xFF7C4DFF, 0xFF9C27B0, 0xFF795548, 0xFF607D8B, 0xFF000000,
    ];
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('主题色', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final c in colors)
                  InkWell(
                    onTap: () => Navigator.pop(context, c),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: c == cur
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: c == cur
                          ? const Icon(Icons.check, color: Colors.white, size: 20)
                          : null,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setAccentColor(choice);
    }
  }

  Future<void> _pickQuality(BuildContext context, WidgetRef ref,
      AppSettings? s, {required bool isOnline}) async {
    final cur = isOnline
        ? s?.onlineDefaultQuality ?? '320k'
        : s?.downloadQuality ?? '320k';
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      builder: (_) => _choiceSheet(context, const [
        _Choice('128k', '128k'),
        _Choice('192k', '192k'),
        _Choice('320k', '320k'),
        _Choice('标准无损', 'flac'),
      ], cur, labelOf: (v) => v as String),
    );
    if (choice != null) {
      final n = ref.read(settingsProvider.notifier);
      if (isOnline) {
        await n.setOnlineDefaultQuality(choice.value as String);
      } else {
        await n.setDownloadQuality(choice.value as String);
      }
    }
  }

  Future<void> _pickMinDuration(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.libraryMinDurationSeconds ?? 0;
    final choices = const [
      _Choice('不排除', 0),
      _Choice('10 秒', 10),
      _Choice('30 秒', 30),
      _Choice('60 秒', 60),
    ];
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      builder: (_) => _choiceSheet(context, choices, cur, labelOf: (v) => switch (v) {
        0 => '不排除',
        10 => '10 秒',
        30 => '30 秒',
        60 => '60 秒',
        _ => '$v 秒',
      }),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setLibraryMinDurationSeconds(choice.value as int);
    }
  }

  Future<void> _pickDownloadPath(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.downloadPath ?? '';
    final controller = TextEditingController(text: cur);
    final action = await showModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('下载路径',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '留空使用默认下载目录',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.outline),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: '路径',
                hintText: '例如 /storage/emulated/0/Music',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'default'),
                  child: const Text('恢复默认'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                  child: const Text('确定'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    final path = action == 'default' ? '' : action as String;
    await ref.read(settingsProvider.notifier).setDownloadPath(path);
  }

  Widget _choiceSheet(BuildContext context, List<_Choice> choices, Object? cur,
      {required String Function(dynamic) labelOf}) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in choices)
            ListTile(
              title: Text(labelOf(c.value)),
              trailing: c.value == cur
                  ? Icon(Icons.check,
                      color: Theme.of(context).colorScheme.primary)
                  : null,
              selected: c.value == cur,
              onTap: () => Navigator.pop(context, c),
            ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _Choice {
  final String label;
  final dynamic value;
  const _Choice(this.label, this.value);
}