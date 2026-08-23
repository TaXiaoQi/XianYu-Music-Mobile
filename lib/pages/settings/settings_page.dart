import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../src/core/settings.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/widgets/user_avatar.dart';

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
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          150 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          _AccountCard(auth: auth, onTap: () => context.push('/account')),
          
          _sectionHeader(context, '外观与界面'),
          _CardGroup(
            children: [
              _tile(
                context,
                icon: Icons.palette_outlined,
                title: '主题模式',
                trailing: _themeLabel(settings),
                onTap: () => _pickThemeMode(context, ref, settings),
              ),
              _tile(
                context,
                icon: Icons.color_lens_outlined,
                title: '主题色',
                trailing: _ColorDot(color: Color(settings?.accentColor ?? 0xFFEC4141)),
                onTap: () => _pickAccentColor(context, ref, settings),
              ),
              _switchTile(
                context,
                icon: Icons.blur_on_outlined,
                title: '晶莹液态玻璃 (Liquid Glass)',
                value: settings?.liquidGlass ?? true,
                onChanged: (v) => notifier.setLiquidGlass(v),
              ),
              _tile(
                context,
                icon: Icons.navigation_outlined,
                title: '导航栏位置',
                trailing: Text(switch (settings?.navBarPosition ?? NavBarPosition.bottom) {
                  NavBarPosition.bottom => '底部导航',
                  NavBarPosition.side => '侧边悬浮',
                }),
                onTap: () => _pickNavBarPosition(context, ref, settings),
              ),
              if ((settings?.navBarPosition ?? NavBarPosition.bottom) == NavBarPosition.bottom)
                _switchTile(
                  context,
                  icon: Icons.subtitles_outlined,
                  title: '悬浮式底栏',
                  value: settings?.floatingNavBar ?? true,
                  onChanged: (v) => notifier.setFloatingNavBar(v),
                ),
              if ((settings?.navBarPosition ?? NavBarPosition.side) == NavBarPosition.side)
                _tile(
                  context,
                  icon: Icons.swap_vert_outlined,
                  title: '侧边栏展开方向',
                  trailing: Text(switch (settings?.sideBarExpandDirection ?? SideBarExpandDirection.down) {
                    SideBarExpandDirection.down => '向下展开',
                    SideBarExpandDirection.up => '向上展开',
                  }),
                  onTap: () => _pickSideBarExpandDirection(context, ref, settings),
                ),
            ],
          ),

          _sectionHeader(context, '播放与音效'),
          _CardGroup(
            children: [
              _tile(
                context,
                icon: Icons.volume_up_outlined,
                title: '音量',
                trailing: _volumeSlider(settings, notifier),
              ),
              _tile(
                context,
                icon: Icons.high_quality_outlined,
                title: '在线默认音质',
                trailing: Text(settings?.onlineDefaultQuality ?? '320k'),
                onTap: () => _pickQuality(context, ref, settings, isOnline: true),
              ),
              _switchTile(
                context,
                icon: Icons.usb_outlined,
                title: 'USB 独占输出 (Bit-perfect)',
                subtitle: '绕过系统混音器直达 USB DAC，仅本地音乐生效；均衡器与音效走原生 DSP 管线，无 USB DAC 或启动失败时自动回退',
                value: settings?.usbExclusiveOutput ?? false,
                onChanged: (v) => notifier.setUsbExclusiveOutput(v),
              ),
              _switchTile(
                context,
                icon: Icons.balance_outlined,
                title: '音量平衡 (ReplayGain)',
                subtitle: '按歌曲内置的 ReplayGain 标签调整增益，让不同歌曲响度一致；无标签的歌曲保持原音量',
                value: settings?.volumeBalanceEnabled ?? false,
                onChanged: (v) => notifier.setVolumeBalanceEnabled(v),
              ),
              if (settings?.volumeBalanceEnabled ?? false) ...[
                _tile(
                  context,
                  icon: Icons.tune_outlined,
                  title: '整体增益偏移',
                  trailing: _gainOffsetSlider(settings, notifier),
                ),
                _switchTile(
                  context,
                  icon: Icons.shield_outlined,
                  title: '防削波破音保护',
                  subtitle: '增益可能超出 0 dB 极限时自动压低；无峰值标签的歌曲不提升音量',
                  value: settings?.volumeBalancePreventClipping ?? true,
                  onChanged: (v) => notifier.setVolumeBalancePreventClipping(v),
                ),
              ],
            ],
          ),

          _sectionHeader(context, '歌词显示'),
          _CardGroup(
            children: [
              _switchTile(
                context,
                icon: Icons.translate_outlined,
                title: '显示翻译',
                value: settings?.showLyricsTranslation ?? true,
                onChanged: (v) => notifier.setShowLyricsTranslation(v),
              ),
              _switchTile(
                context,
                icon: Icons.spellcheck_outlined,
                title: '逐字动效',
                value: settings?.enableWordEffect ?? true,
                onChanged: (v) => notifier.setEnableWordEffect(v),
              ),
            ],
          ),

          _sectionHeader(context, '音乐库管理'),
          _CardGroup(
            children: [
              _tile(
                context,
                icon: Icons.create_new_folder_outlined,
                title: '扫描文件夹',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/scan-folders'),
              ),
              _tile(
                context,
                icon: Icons.timer_outlined,
                title: '排除短音频（秒）',
                trailing: Text('${settings?.libraryMinDurationSeconds ?? 0}'),
                onTap: () => _pickMinDuration(context, ref, settings),
              ),
              _switchTile(
                context,
                icon: Icons.verified_outlined,
                title: '显示音质标识',
                value: settings?.showQualityBadges ?? true,
                onChanged: (v) => notifier.setShowQualityBadges(v),
              ),
              _tile(
                context,
                icon: Icons.cloud_outlined,
                title: '远程音乐库 (WebDAV)',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/remote-library'),
              ),
            ],
          ),

          _sectionHeader(context, '下载设置'),
          _CardGroup(
            children: [
              _tile(
                context,
                icon: Icons.folder_outlined,
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
                icon: Icons.download_outlined,
                title: '下载音质',
                trailing: Text(settings?.downloadQuality ?? '320k'),
                onTap: () => _pickQuality(context, ref, settings, isOnline: false),
              ),
              _switchTile(
                context,
                icon: Icons.lyrics_outlined,
                title: '同时下载歌词',
                value: settings?.downloadLyrics ?? true,
                onChanged: (v) => notifier.setDownloadLyrics(v),
              ),
              _tile(
                context,
                icon: Icons.download_done_outlined,
                title: '下载管理',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/download'),
              ),
            ],
          ),

          _sectionHeader(context, '数据与扩展'),
          _CardGroup(
            children: [
              _tile(
                context,
                icon: Icons.cloud_sync_outlined,
                title: '同步与备份',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/sync'),
              ),
              _tile(
                context,
                icon: Icons.extension_outlined,
                title: '插件扩展',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/plugin'),
              ),
              _tile(
                context,
                icon: Icons.queue_music_outlined,
                title: '我的歌单',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/playlists'),
              ),
              _tile(
                context,
                icon: Icons.wallpaper_outlined,
                title: '壁纸中心',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/wallpaper'),
              ),
              _tile(
                context,
                icon: Icons.lock_open_outlined,
                title: 'QMC 文件解密',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/qmc-decrypt'),
              ),
              _tile(
                context,
                icon: Icons.drive_file_rename_outline,
                title: '批量重命名',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/batch-rename'),
              ),
              _tile(
                context,
                icon: Icons.leaderboard_outlined,
                title: '听歌排行榜',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/leaderboard'),
              ),
            ],
          ),

          _sectionHeader(context, '关于与系统'),
          _CardGroup(
            children: [
              _switchTile(
                context,
                icon: Icons.screen_lock_rotation_outlined,
                title: '保持屏幕常亮',
                value: settings?.keepScreenOn ?? true,
                onChanged: (v) => notifier.setKeepScreenOn(v),
              ),
              _tile(
                context,
                icon: Icons.feedback_outlined,
                title: '意见反馈',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/feedback'),
              ),
              _tile(
                context,
                icon: Icons.info_outline,
                title: '关于',
                trailing: const SizedBox.shrink(),
                onTap: () => context.push('/about'),
              ),
            ],
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
      required ValueChanged<bool> onChanged,
      String? subtitle}) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      value: value,
      onChanged: onChanged,
    );
  }

  Future<void> _pickNavBarPosition(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.navBarPosition ?? NavBarPosition.bottom;
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      builder: (_) => _choiceSheet(context, const [
        _Choice('底部导航', NavBarPosition.bottom),
        _Choice('侧边悬浮', NavBarPosition.side),
      ], cur, labelOf: (v) => switch (v) {
        NavBarPosition.bottom => '底部导航',
        NavBarPosition.side => '侧边悬浮',
        _ => '底部导航',
      }),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setNavBarPosition(choice.value as NavBarPosition);
    }
  }

  Future<void> _pickSideBarExpandDirection(
      BuildContext context, WidgetRef ref, AppSettings? s) async {
    final cur = s?.sideBarExpandDirection ?? SideBarExpandDirection.down;
    final choice = await showModalBottomSheet<_Choice>(
      context: context,
      builder: (_) => _choiceSheet(context, const [
        _Choice('向下展开', SideBarExpandDirection.down),
        _Choice('向上展开', SideBarExpandDirection.up),
      ], cur, labelOf: (v) => switch (v) {
        SideBarExpandDirection.down => '向下展开',
        SideBarExpandDirection.up => '向上展开',
        _ => '向下展开',
      }),
    );
    if (choice != null) {
      await ref
          .read(settingsProvider.notifier)
          .setSideBarExpandDirection(choice.value as SideBarExpandDirection);
    }
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

  /// 音量平衡整体增益偏移滑条（-12 ~ +6 dB）。
  Widget _gainOffsetSlider(AppSettings? s, SettingsNotifier n) {
    final db = s?.volumeBalanceGainOffsetDb ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 130,
          child: Slider(
            min: -12,
            max: 6,
            divisions: 18,
            value: db.clamp(-12.0, 6.0),
            onChanged: (v) => n.setVolumeBalanceGainOffsetDb(v),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${db > 0 ? '+' : ''}${db.toStringAsFixed(0)} dB',
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      ],
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
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(ctx).padding.bottom + 80, // 给全局底部导航栏和安全区留出空间
        ),
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
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 80,
      ),
      child: SafeArea(
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
      ),
    );
  }
}

/// 分组圆角卡片包裹容器
class _CardGroup extends StatelessWidget {
  const _CardGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i != children.length - 1) {
        items.add(
          Divider(
            height: 1,
            indent: 52,
            endIndent: 16,
            thickness: 0.5,
            color: scheme.onSurface.withValues(alpha: 0.08),
          ),
        );
      }
    }

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(children: items),
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

/// 设置页账号卡片：登录时显示头像+昵称，未登录时显示登录引导。
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.auth, required this.onTap});
  final AuthState auth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = auth.user;
    final loggedIn = auth.isLoggedIn && user != null;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              // 头像
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary,
                ),
                clipBehavior: Clip.antiAlias,
                child: loggedIn
                    ? (user.avatar != null && user.avatar!.isNotEmpty
                        ? UserAvatarImage(
                            avatar: user.avatar,
                            fallback:
                                _fallback(scheme, user.nickname),
                          )
                        : _fallback(scheme, user.nickname))
                    : Icon(Icons.person, color: scheme.onPrimary, size: 26),
              ),
              const SizedBox(width: 14),
              // 昵称 + 副标题
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loggedIn
                          ? (user.nickname.isEmpty
                              ? '未命名用户'
                              : user.nickname)
                          : '未登录',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      loggedIn
                          ? '点击管理账号与安全'
                          : '登录后同步你的音乐与设置',
                      style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallback(ColorScheme scheme, String nickname) {
    final char = nickname.isEmpty
        ? '?'
        : String.fromCharCode(nickname.runes.first);
    return Center(
      child: Text(
        char,
        style: TextStyle(
            fontSize: 20, fontWeight: FontWeight.bold, color: scheme.onPrimary),
      ),
    );
  }
}

class _Choice {
  final String label;
  final dynamic value;
  const _Choice(this.label, this.value);
}