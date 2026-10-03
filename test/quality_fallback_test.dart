import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/plugin/plugin_engine.dart';

void main() {
  group('isUnsupportedQualityError', () {
    test('识别常见「不支持音质」表述', () {
      expect(isUnsupportedQualityError('不支持的音质: 192k'), isTrue);
      expect(isUnsupportedQualityError('该歌曲不支持 192k 音质'), isTrue);
      expect(isUnsupportedQualityError('quality not supported'), isTrue);
      expect(isUnsupportedQualityError('播放地址解析失败'), isFalse);
    });
  });

  group('parseSupportedQualities', () {
    test('解析 HYW 风格的可用档位清单', () {
      // 日志原样：HYWmusic_beta 对 192k 的拒绝响应
      const msg =
          '不支持的音质: 192k，支持的音质: 128k, 320k, flac, flac24bit, hires, atmos, atmos_plus, master';
      final got = parseSupportedQualities(msg);
      expect(
        got,
        ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'atmos_plus', 'master'],
      );
    });

    test('忽略清单里不属于梯形档位的噪声词', () {
      const msg = '支持的音质: 128k, 320k, standard, 未知档位';
      expect(parseSupportedQualities(msg), ['128k', '320k']);
    });

    test('无支持清单时返回空', () {
      expect(parseSupportedQualities('不支持 192k 音质'), isEmpty);
      expect(parseSupportedQualities('播放地址解析失败'), isEmpty);
    });

    test('去重且保序', () {
      const msg = '支持的音质: 320k, 128k, 320k';
      expect(parseSupportedQualities(msg), ['320k', '128k']);
    });
  });

  group('pickSupportedQuality', () {
    const supported = ['128k', '320k', 'flac', 'master'];

    test('lower：偏好 192k 时降到低于它的最高可用档', () {
      expect(pickSupportedQuality('192k', 'lower', supported), '128k');
    });

    test('higher：偏好 192k 时升到高于它的最低可用档', () {
      expect(pickSupportedQuality('192k', 'higher', supported), '320k');
    });

    test('偏好档位本身可用时保持不高于偏好语义（lower 取更低的）', () {
      expect(pickSupportedQuality('320k', 'lower', supported), '128k');
    });

    test('偏好方向无可用档位时退到最高可用档，保证能出声', () {
      // 偏好已是最低档 128k，再降无可降
      expect(pickSupportedQuality('128k', 'lower', supported), 'master');
    });

    test('偏好不在梯形内时取最高可用档', () {
      expect(pickSupportedQuality('unknown', 'lower', supported), 'master');
    });

    test('空清单返回 null', () {
      expect(pickSupportedQuality('192k', 'lower', const []), isNull);
    });
  });
}
