import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../i18n/i18n.dart';

String listSizeLabel(ListSize v) => switch (v) {
      ListSize.compact => tr('最小'),
      ListSize.medium => tr('中等'),
      ListSize.large => tr('最大'),
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
        ListSize.medium => const ListMetrics(
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

  static ListMetrics ofRef(WidgetRef ref) => ListMetrics.of(
        ref.watch(settingsProvider
            .select((s) => s.valueOrNull?.listSize ?? ListSize.medium)),
      );
}