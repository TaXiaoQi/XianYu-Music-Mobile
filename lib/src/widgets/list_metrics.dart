import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../i18n/i18n.dart';

String listSizeLabel(ListSize v) => switch (v) {
      ListSize.compact => tr('最小'),
      ListSize.medium => tr('标准'),
      ListSize.large => tr('最大'),
      ListSize.followSystem => tr('跟随系统'),
    };

class ListMetrics {
  final double songCover;
  final double artistCover;
  final double playCover;
  final double songRadius;
  final double titleSize;
  final double subtitleSize;
  final double vPad;

  const ListMetrics({
    required this.songCover,
    required this.artistCover,
    required this.playCover,
    required this.songRadius,
    required this.titleSize,
    required this.subtitleSize,
    required this.vPad,
  });

  static ListMetrics of(ListSize size) => switch (size) {
        ListSize.compact => const ListMetrics(
            songCover: 44,
            artistCover: 48,
            playCover: 44,
            songRadius: 8,
            titleSize: 14.5,
            subtitleSize: 12,
            vPad: 6,
          ),
        // followSystem 由 ofRef 先换算成标准档×系统缩放，直落标准基准兜底
        ListSize.medium || ListSize.followSystem => const ListMetrics(
            songCover: 58,
            artistCover: 68,
            playCover: 58,
            songRadius: 10,
            titleSize: 15.5,
            subtitleSize: 12.5,
            vPad: 7,
          ),
        ListSize.large => const ListMetrics(
            songCover: 80,
            artistCover: 88,
            playCover: 80,
            songRadius: 12,
            titleSize: 17,
            subtitleSize: 14,
            vPad: 7,
          ),
      };

  /// 系统字体缩放因子（app.dart 每帧从 MediaQuery 记录），
  /// 供「跟随系统」档换算列表尺寸；默认 1.0 兜底
  static double systemTextScale = 1.0;

  static ListMetrics ofRef(WidgetRef ref) {
    final size = ref.watch(settingsProvider
        .select((s) => s.valueOrNull?.listSize ?? ListSize.medium));
    if (size == ListSize.followSystem) {
      // 跟随系统：标准档基准整体乘系统缩放；行内文字已在 CoverRow
      // 锁定 noScaling，由 metrics 携带缩放，避免二次叠加
      return ListMetrics.of(ListSize.medium).scaled(systemTextScale);
    }
    return ListMetrics.of(size);
  }

  /// 全字段等比缩放（跟随系统档用）
  ListMetrics scaled(double k) => ListMetrics(
        songCover: songCover * k,
        artistCover: artistCover * k,
        playCover: playCover * k,
        songRadius: songRadius * k,
        titleSize: titleSize * k,
        subtitleSize: subtitleSize * k,
        vPad: vPad * k,
      );
}