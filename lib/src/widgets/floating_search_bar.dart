import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../i18n/i18n.dart';
import 'bilipai_glass.dart';
import 'blur_budget.dart';
import 'glass_settings.dart';

/// 首页/我的页「悬浮搜索框」：独立悬浮胶囊，固定悬浮在顶栏下方，不随内容滚动。
///
/// 材质跟随全局玻璃设置：
/// - 液态玻璃开启 → 中/高档走 [AdaptiveGlass]（shader 折射 + 高光，与底栏/迷你条
///   同一套参数），低档走伪液态毛玻璃（不跑 shader）；
/// - 液态玻璃关闭 → 毛玻璃（透明磨砂）/ 纯色回退，口径同底栏 `_frostedGlass`。
class FloatingSearchBar extends ConsumerWidget {
  const FloatingSearchBar({super.key, required this.onTap, this.onRecognize});

  final VoidCallback onTap;

  /// 听歌识曲入口（可选：首页带话筒，我的页不带）。
  final VoidCallback? onRecognize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            false) &&
            !lowPerf;
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.header));

    final content = Material(
      color: Colors.transparent,
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
              if (onRecognize != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onRecognize,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC4141).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.mic_none,
                      size: 17,
                      color: Color(0xFFEC4141),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (liquid) {
      // 液态玻璃低档：不跑 shader，用伪液态毛玻璃伪造（透明底 + 淡模糊）。
      if (liquidUseFrosted(ref)) {
        return pseudoLiquidSurface(
          context: context,
          ref: ref,
          radius: 999,
          child: content,
          lowPerf: lowPerf,
          surfaceType: BlurSurfaceType.header,
          budget: budget,
        );
      }
      // 高 44，圆角取一半成胶囊，与底栏/迷你条同一套 BiliPai 液态玻璃参数。
      final quality = liquidGlassQualitySetting(ref);
      return glassBorder(
        context: context,
        radius: 22,
        child: BiliPaiGlass(
          radius: 22,
          refract: bilipaiRefractOf(quality),
          chroma: bilipaiChromaOf(quality),
          blurSigma: surfaceBlurSigma(
            base: 1.5,
            budget: budget,
            type: BlurSurfaceType.header,
          ),
          backgroundColor: bilipaiGlassTint(isDark),
          specular: bilipaiSpecularOf(quality),
          child: content,
        ),
      );
    }
    // 液态玻璃关闭：毛玻璃/纯色回退，复用伪液态表面口径（透明底 + 淡模糊）。
    // 悬浮搜索框是毛玻璃表面，模糊强度跟随毛玻璃档位（frostedBlurScale）。
    return pseudoLiquidSurface(
      context: context,
      ref: ref,
      radius: 999,
      child: content,
      lowPerf: lowPerf,
      surfaceType: BlurSurfaceType.header,
      budget: budget,
      frostedScale: frostedBlurScale(ref),
    );
  }
}
