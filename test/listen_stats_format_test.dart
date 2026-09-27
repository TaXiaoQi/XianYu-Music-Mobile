import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_music_mobile/src/home/home_providers.dart';

/// 统计卡与横屏封面轮播共用的时长文案。
///
/// 三列等宽，所以「21 小时 14 分钟」这种长文案会把别的列挤窄、窄屏还会折行，
/// 因此十小时以上收成小数小时。这里把分档边界钉住，防止以后改坏。
void main() {
  String fmt(int seconds) =>
      ListenStatsData(totalSeconds: seconds).totalDurationText;

  test('十小时以上收成小数小时', () {
    // 21 小时 14 分钟 → 21.2 小时（原先是九个字）
    expect(fmt(21 * 3600 + 14 * 60), '21.2 小时');
  });

  test('整小时不带多余小数', () {
    expect(fmt(12 * 3600), '12 小时');
  });

  test('一小时到十小时之间保留时分两级', () {
    expect(fmt(9 * 3600 + 30 * 60), '9 小时 30 分');
    expect(fmt(3600), '1 小时 0 分');
  });

  test('不足一小时只用分钟', () {
    expect(fmt(54 * 60), '54 分钟');
    expect(fmt(59), '0 分钟');
  });

  test('零值走空态文案', () {
    expect(fmt(0), '0 分钟');
  });
}
