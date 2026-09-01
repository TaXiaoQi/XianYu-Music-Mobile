import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/i18n.dart';
import 'glass_settings.dart';

/// 首页/我的页共用搜索框扩展区（PreferredSizeWidget 以便 GlassTopBar 计算
/// height）。样式以首页版为准：实色胶囊 + 右侧听歌识曲话筒入口。
class PageSearchBarBottom extends StatelessWidget implements PreferredSizeWidget {
  const PageSearchBarBottom({
    super.key,
    required this.onTap,
    this.onRecognize,
  });

  final VoidCallback onTap;

  /// 听歌识曲入口回调；为 null 时不显示话筒。
  final VoidCallback? onRecognize;

  @override
  Size get preferredSize => const Size.fromHeight(58);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
      child: PageSearchBar(onTap: onTap, onRecognize: onRecognize),
    );
  }
}

/// 顶部搜索条：点击进入搜索页；右侧带听歌识曲（仅话筒图标）入口。
class PageSearchBar extends ConsumerWidget {
  const PageSearchBar({super.key, required this.onTap, this.onRecognize});

  final VoidCallback onTap;

  /// 听歌识曲入口回调；为 null 时不显示话筒。
  final VoidCallback? onRecognize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 固定对比色实色胶囊：带一点透明、不随毛玻璃开关变化，与玻璃顶栏形成对比；
    // 壁纸模式下为全透明（让壁纸透出）。
    return Material(
      color: searchBoxFill(context, ref),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 44,
          padding: const EdgeInsets.fromLTRB(18, 0, 6, 0),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('搜索歌曲、歌手、专辑'),
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
              if (onRecognize != null) ...[
                const SizedBox(width: 8),
                // 听歌识曲入口：搜索框内右侧（仅话筒图标标识）
                GestureDetector(
                  onTap: onRecognize,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC4141).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.mic_none,
                        size: 17, color: Color(0xFFEC4141)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
