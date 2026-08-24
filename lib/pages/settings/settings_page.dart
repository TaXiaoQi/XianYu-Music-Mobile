import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/widgets/glass_appbar.dart';

/// 设置导航页：浅白底 + 纯白分类卡片，默认展示分类列表，点入详情。
///
/// 分类参考桌面版导航（常规/音源/外观/播放/下载/音乐库/工具箱/高级设置/关于），
/// 账号入口在「我的」页，桌面歌词、快捷按键等移动端无对应项故未列出。
/// 本页为二级推入页（从「我的」页菜单与首页顶栏进入）。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  /// 分组：标题 -> 分类条目。每个条目的 path 指向分类详情页或既有页面。
  static const _groups = <(String, List<_CategoryEntry>)>[
    (
      '偏好',
      [
        _CategoryEntry('常规', Icons.tune, '语言、反馈、存储', '/settings/general'),
        _CategoryEntry('外观', Icons.palette_outlined, '主题、主题色、液态玻璃、导航栏、歌词', '/settings/appearance'),
        _CategoryEntry('播放', Icons.play_circle_outline, '音量、双击播放、在线音质、输出', '/settings/playback'),
      ],
    ),
    (
      '在线与音源',
      [
        _CategoryEntry('音源', Icons.library_music_outlined, '插件音源：导入、启用、更新、卸载', '/plugin'),
        _CategoryEntry('下载', Icons.download_outlined, '音质、路径、并发、嵌入', '/settings/download'),
      ],
    ),
    (
      '曲库',
      [
        _CategoryEntry('音乐库', Icons.album_outlined, '扫描文件夹、短音频、远程库', '/settings/library'),
        _CategoryEntry('工具箱', Icons.handyman_outlined, '歌单、壁纸、解密、重命名', '/settings/toolbox'),
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
    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      body: Stack(
        children: [
          // 内容列表：顶部预留顶栏高度，静止时位于毛玻璃下方，上拉时内容滑入顶栏被高斯模糊。
          // 底部避让：二级页底栏隐藏，仅迷你播放条悬浮在距底 18px 处（高 58）。
          ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              GlassTopBar.height(context),
              16,
              92 + MediaQuery.of(context).padding.bottom,
            ),
            children: [
              for (final (header, entries) in _groups) ...[
                _sectionHeader(context, header),
                _CardGroup(children: [
                  for (var i = 0; i < entries.length; i++)
                    _CategoryTile(entry: entries[i]),
                ]),
              ],
            ],
          ),
          // 顶栏高斯模糊毛玻璃（二级页带返回按钮）。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: const Text('设置'),
            ),
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