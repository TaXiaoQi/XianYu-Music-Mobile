import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/widgets/user_avatar.dart';

/// 设置导航页：浅白底 + 纯白分类卡片，默认展示分类列表，点入详情。
///
/// 分类参考桌面版导航（账号/常规/音源/外观/播放/下载/音乐库/工具箱/高级设置/关于），
/// 桌面歌词、快捷按键等移动端无对应项故未列出。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  /// 分组：标题 -> 分类条目。每个条目的 path 指向分类详情页或既有页面。
  static const _groups = <(String, List<_CategoryEntry>)>[
    (
      '偏好',
      [
        _CategoryEntry('常规', Icons.tune, '语言、导航栏', '/settings/general'),
        _CategoryEntry('外观', Icons.palette_outlined, '主题、主题色、液态玻璃、歌词', '/settings/appearance'),
        _CategoryEntry('播放', Icons.play_circle_outline, '音量、双击播放、音量平衡', '/settings/playback'),
      ],
    ),
    (
      '在线与音源',
      [
        _CategoryEntry('音源', Icons.library_music_outlined, '默认音质、回退策略、输出设备、直出', '/settings/sources'),
        _CategoryEntry('下载', Icons.download_outlined, '音质、路径、并发、嵌入', '/settings/download'),
      ],
    ),
    (
      '曲库',
      [
        _CategoryEntry('音乐库', Icons.album_outlined, '扫描文件夹、短音频、远程库', '/settings/library'),
        _CategoryEntry('工具箱', Icons.handyman_outlined, '插件、歌单、壁纸、解密、重命名', '/settings/toolbox'),
      ],
    ),
    (
      '系统',
      [
        _CategoryEntry('高级设置', Icons.settings_suggest_outlined, '屏幕常亮', '/settings/advanced'),
        _CategoryEntry('意见反馈', Icons.feedback_outlined, '向我们反馈问题与建议', '/feedback'),
        _CategoryEntry('关于', Icons.info_outline, '版本信息、项目主页', '/about'),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          150 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          _AccountCard(
            auth: auth,
            onTap: () => context.push('/account'),
          ),
          for (final (header, entries) in _groups) ...[
            _sectionHeader(context, header),
            _CardGroup(children: [
              for (var i = 0; i < entries.length; i++)
                _CategoryTile(entry: entries[i]),
            ]),
          ],
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
}

class _CategoryEntry {
  const _CategoryEntry(this.title, this.icon, this.subtitle, this.path);
  final String title;
  final IconData icon;
  final String subtitle;
  final String path;
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.entry});
  final _CategoryEntry entry;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(entry.icon),
      title: Text(entry.title),
      subtitle: Text(entry.subtitle,
          style: Theme.of(context).textTheme.bodySmall),
      trailing: Icon(Icons.chevron_right,
          size: 18, color: Theme.of(context).colorScheme.outline),
      onTap: () => context.push(entry.path),
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
      color: appCardColor(context),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
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
                            fallback: _fallback(scheme, user.nickname),
                          )
                        : _fallback(scheme, user.nickname))
                    : Icon(Icons.person, color: scheme.onPrimary, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loggedIn
                          ? (user.nickname.isEmpty ? '未命名用户' : user.nickname)
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
                          fontSize: 12, color: scheme.onSurfaceVariant),
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

/// 分组圆角纯白卡片包裹容器。
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
      color: appCardColor(context),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(children: items),
    );
  }
}