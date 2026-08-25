import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';

/// 列表大小对应的中文名（外观设置弹窗展示）。
String listSizeLabel(ListSize v) => switch (v) {
      ListSize.compact => '最小',
      ListSize.medium => '中等',
      ListSize.large => '最大',
    };

/// 歌曲/歌手/专辑/歌单列表项的统一尺度。
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

  /// 手/歌手列表等非圆形圆角曲与专辑共用 songRadius；圆形头像半径外部计算。
  static ListMetrics of(ListSize size) => switch (size) {
        // 最小 = 早期紧凑样式。
        ListSize.compact => const ListMetrics(
            songCover: 44,
            artistCover: 48,
            playCover: 44,
            songRadius: 8,
            titleSize: 14.5,
            subtitleSize: 12,
            vPad: 6,
          ),
        // 中等 = 最小与最大之间的折中。
        ListSize.medium => const ListMetrics(
            songCover: 58,
            artistCover: 68,
            playCover: 58,
            songRadius: 10,
            titleSize: 15.5,
            subtitleSize: 12.5,
            vPad: 7,
          ),
        // 最大 = 当前本地库大图样式。
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

  /// 从设置读取当前列表大小并映射为一组尺度。
  static ListMetrics ofRef(WidgetRef ref) => ListMetrics.of(
        ref.watch(settingsProvider
            .select((s) => s.valueOrNull?.listSize ?? ListSize.medium)),
      );
}