import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../library/library_provider.dart';

/// 音乐库网格：2 列方块卡，渐变图标块，6 入口。
class LibraryGrid extends ConsumerWidget {
  const LibraryGrid({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final border = Colors.white.withValues(alpha: 0.08);

    Widget tile({
      required String title,
      required String subtitle,
      required IconData icon,
      required List<Color> gradient,
      required VoidCallback onTap,
    }) {
      return Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(13),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: border),
            ),
            // GridView 已给定固定高度(mainAxisExtent)，Column 用默认 max
            // 配合 Spacer 实现"图标顶部、文字底部"且不溢出。
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: gradient,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: Colors.white, size: 18),
                ),
                // 弹性间距：高度富余时撑开，紧张时收缩，避免文字被裁。
                const Spacer(),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    void goLibraryTab(int tab) {
      ref.read(libraryTabProvider.notifier).state = tab;
      context.go('/library');
    }

    // 卡片高度按内容与系统字体缩放动态计算，避免副标题被裁切。
    // 固定部分：上下 padding 14*2 + 图标块 34 + 标题与副标题间距 1
    // 文字部分：标题 15px + 副标题 11px，乘以系统字体缩放系数
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final tileHeight = 14 * 2 + 34 + 1 + (15 + 11) * 1.35 * textScale + 10;

    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        mainAxisExtent: tileHeight,
      ),
      children: [
        tile(
          title: '歌曲',
          subtitle: '本地全部',
          icon: Icons.music_note,
          gradient: const [Color(0xFFEC4141), Color(0xFFFF6B6B)],
          onTap: () => goLibraryTab(0),
        ),
        tile(
          title: '文件夹',
          subtitle: '按目录浏览',
          icon: Icons.folder,
          gradient: const [Color(0xFF5B8DEF), Color(0xFF7C6BFF)],
          onTap: () => goLibraryTab(3),
        ),
        tile(
          title: '专辑',
          subtitle: '封面网格',
          icon: Icons.album,
          gradient: const [Color(0xFF2EC5A6), Color(0xFF5B8DEF)],
          onTap: () => goLibraryTab(2),
        ),
        tile(
          title: '歌手',
          subtitle: '字母索引',
          icon: Icons.person,
          gradient: const [Color(0xFFFFB347), Color(0xFFFF5C8A)],
          onTap: () => goLibraryTab(1),
        ),
        tile(
          title: '歌单',
          subtitle: '我的收藏',
          icon: Icons.favorite,
          gradient: const [Color(0xFFA06BFF), Color(0xFFFF5C8A)],
          onTap: () => context.push('/home/favorites'),
        ),
        tile(
          title: '最近播放',
          subtitle: '播放记录',
          icon: Icons.history,
          gradient: const [Color(0xFF3AC2A6), Color(0xFFFFB347)],
          onTap: () => context.push('/home/recent'),
        ),
      ],
    );
  }
}
