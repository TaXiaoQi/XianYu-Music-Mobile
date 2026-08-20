import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/settings.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/plugins/plugin_provider.dart';
import 'music_sources_page.dart';
import 'scan_folders_page.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final notifier = ref.read(settingsProvider.notifier);
    final auth = ref.watch(authProvider);

    return Scaffold(
      // 透明 AppBar 透出氛围背景，标题左对齐放大更现代。
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          '设置',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const _AmbientBackground(),
          ListView(
            padding: EdgeInsets.only(
              // AppBar 高度 + 状态栏，避免首组被顶栏盖住。
              top: MediaQuery.of(context).padding.top + kToolbarHeight,
              left: 16,
              right: 16,
              bottom: 150,
            ),
            children: [
              _section(context, '账号', [
                _GlassTile(
                  icon: Icons.account_circle,
                  title: '账号与安全',
                  trailing: Text(
                    auth.isLoggedIn ? auth.user!.nickname : '未登录',
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  onTap: () => context.push('/settings/account'),
                ),
              ]),
              _section(context, '外观', [
                _GlassTile(
                  icon: Icons.palette,
                  title: '主题模式',
                  trailing: _themeLabel(context, settings),
                  onTap: () => _pickThemeMode(context, ref, settings),
                ),
                _GlassTile(
                  icon: Icons.color_lens,
                  title: '主题色',
                  trailing: _ColorDot(
                      color: Color(settings?.accentColor ?? 0xFFEC4141)),
                  onTap: () => _pickAccentColor(context, ref, settings),
                ),
              ]),
              _section(context, '播放', [
                _GlassTile(
                  icon: Icons.volume_up,
                  title: '音量',
                  trailing: _volumeSlider(settings, notifier),
                ),
                _GlassTile(
                  icon: Icons.high_quality,
                  title: '在线默认音质',
                  trailing: Text(settings?.onlineDefaultQuality ?? '320k'),
                  onTap: () => _pickQuality(context, ref, settings, isOnline: true),
                ),
                // 在线播放依赖用户导入的音源插件
                _GlassTile(
                  icon: Icons.extension,
                  title: '音源管理',
                  trailing: _sourceSummary(context, ref),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MusicSourcesPage()),
                  ),
                ),
              ]),
              _section(context, '歌词', [
                _GlassSwitchTile(
                  icon: Icons.translate,
                  title: '显示翻译',
                  value: settings?.showLyricsTranslation ?? true,
                  onChanged: (v) => notifier.setShowLyricsTranslation(v),
                ),
                _GlassSwitchTile(
                  icon: Icons.spellcheck,
                  title: '逐字动效',
                  value: settings?.enableWordEffect ?? true,
                  onChanged: (v) => notifier.setEnableWordEffect(v),
                ),
              ]),
              _section(context, '音乐库', [
                _GlassTile(
                  icon: Icons.folder_special,
                  title: '扫描文件夹',
                  trailing: const Text(''),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ScanFoldersPage()),
                  ),
                ),
                _GlassTile(
                  icon: Icons.audiotrack,
                  title: '扫描格式',
                  trailing: Text('${settings?.scanFormats.length ?? 0} 种'),
                  onTap: () => _pickScanFormats(context, ref, settings),
                ),
                _GlassTile(
                  icon: Icons.timer,
                  title: '排除短音频（秒）',
                  trailing: Text('${settings?.libraryMinDurationSeconds ?? 0}'),
                  onTap: () => _pickMinDuration(context, ref, settings),
                ),
                _GlassSwitchTile(
                  icon: Icons.verified,
                  title: '显示音质标识',
                  value: settings?.showQualityBadges ?? true,
                  onChanged: (v) => notifier.setShowQualityBadges(v),
                ),
              ]),
              _section(context, '下载', [
                _GlassTile(
                  icon: Icons.folder,
                  title: '下载路径',
                  trailing: Text(
                    settings?.downloadPath == null ||
                            settings!.downloadPath.isEmpty
                        ? '默认'
                        : '自定义',
                  ),
                  onTap: () => _pickDownloadPath(context, ref, settings),
                ),
                _GlassTile(
                  icon: Icons.download,
                  title: '下载音质',
                  trailing: Text(settings?.downloadQuality ?? '320k'),
                  onTap: () => _pickQuality(context, ref, settings, isOnline: false),
                ),
                _GlassSwitchTile(
                  icon: Icons.lyrics,
                  title: '同时下载歌词',
                  value: settings?.downloadLyrics ?? true,
                  onChanged: (v) => notifier.setDownloadLyrics(v),
                ),
              ]),
              _section(context, '其他', [
                _GlassSwitchTile(
                  icon: Icons.screen_lock_rotation,
                  title: '保持屏幕常亮',
                  value: settings?.keepScreenOn ?? true,
                  onChanged: (v) => notifier.setKeepScreenOn(v),
                ),
              ]),
            ],
          ),
        ],
      ),
    );
  }

  /// 一组设置：小节标题 + 毛玻璃卡片。
  Widget _section(BuildContext context, String title, List<Widget> rows) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
          _GlassCard(children: rows),
        ],
      ),
    );
  }

  Widget _themeLabel(BuildContext context, AppSettings? s) {
    return Text(
      switch (s?.themeMode ?? ThemeModePreference.system) {
        ThemeModePreference.system => '跟随系统',
        ThemeModePreference.light => '浅色',
        ThemeModePreference.dark => '深色',
      },
      style: TextStyle(
          fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  /// 音源管理右侧摘要：已启用数量，未导入时提示去添加。
  Widget _sourceSummary(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pluginProvider);
    final scheme = Theme.of(context).colorScheme;
    final enabled = state.plugins.where((p) => p.enabled).length;

    if (state.plugins.isEmpty) {
      // 未导入音源时在线播放不可用，用主题色提示需要处理。
      return Text(
        '未导入',
        style: TextStyle(fontSize: 13, color: scheme.primary),
      );
    }
    return Text(
      '已启用 $enabled 个',
      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
    );
  }

  Widget _volumeSlider(AppSettings? s, SettingsNotifier n) {
    return SizedBox(
      width: 140,
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        ),
        child: Slider(
          value: s?.volume ?? 1.0,
          onChanged: (v) => n.setVolume(v),
        ),
      ),
    );
  }

  Future<void> _pickThemeMode(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.themeMode ?? ThemeModePreference.system;
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      useRootNavigator: true,
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
      useRootNavigator: true,
      builder: (_) => SafeArea(
        child: Padding(
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
      useRootNavigator: true,
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
      useRootNavigator: true,
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

  /// 扫描格式多选：勾选要扫描入库的音频格式（至少保留一种）。
  Future<void> _pickScanFormats(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final selected = {...(s?.scanFormats ?? kSupportedScanFormats)};
    const labels = {
      'flac': 'FLAC（无损）',
      'mp3': 'MP3',
      'wav': 'WAV（无损）',
      'aac': 'AAC',
      'm4a': 'M4A / ALAC',
      'ogg': 'OGG / Vorbis',
      'aiff': 'AIFF',
    };
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      useRootNavigator: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text('扫描格式',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 16)),
                  ),
                  for (final fmt in kSupportedScanFormats)
                    CheckboxListTile(
                      title: Text(labels[fmt] ?? fmt.toUpperCase()),
                      value: selected.contains(fmt),
                      onChanged: (v) {
                        setModalState(() {
                          if (v == true) {
                            selected.add(fmt);
                          } else {
                            selected.remove(fmt);
                          }
                        });
                      },
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: selected.isEmpty
                              ? null
                              : () => Navigator.pop(context, selected),
                          child: const Text('确定'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (result != null && result.isNotEmpty) {
      final ordered =
          kSupportedScanFormats.where((f) => result.contains(f)).toList();
      await ref.read(settingsProvider.notifier).setScanFormats(ordered);
    }
  }

  Future<void> _pickDownloadPath(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.downloadPath ?? '';
    final controller = TextEditingController(text: cur);
    final action = await showModalBottomSheet<Object?>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
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

/// 氛围背景：与主界面一致的主题色光斑，叠加全屏模糊晕开成柔光。
class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: scheme.surface),
          Positioned(
            top: -90,
            right: -70,
            child: _glow(300, scheme.primary.withValues(alpha: isDark ? 0.24 : 0.16)),
          ),
          Positioned(
            bottom: -70,
            left: -90,
            child: _glow(320, scheme.tertiary.withValues(alpha: isDark ? 0.14 : 0.09)),
          ),
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
            child: Container(color: Colors.transparent),
          ),
        ],
      ),
    );
  }

  Widget _glow(double size, Color color) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      );
}

/// 毛玻璃分组卡片：承载若干设置行，行间以细分割线隔开。
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.white.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.10 : 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 56,
                    color: scheme.onSurface.withValues(alpha: 0.06),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 毛玻璃设置行：图标 + 标题 + 右侧控件/箭头。
class _GlassTile extends StatelessWidget {
  const _GlassTile({
    required this.icon,
    required this.title,
    required this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // 图标用主题色容器包裹，增强分组感。
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: scheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500)),
            ),
            if (onTap != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DefaultTextStyle(
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant),
                    child: trailing,
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right,
                      size: 18, color: scheme.onSurfaceVariant),
                ],
              )
            else
              trailing,
          ],
        ),
      ),
    );
  }
}

/// 毛玻璃开关行：图标 + 标题 + 开关。
class _GlassSwitchTile extends StatelessWidget {
  const _GlassSwitchTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 18, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w500)),
          ),
          Switch(value: value, onChanged: onChanged),
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