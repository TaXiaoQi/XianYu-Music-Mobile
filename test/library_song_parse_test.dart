import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_music_mobile/src/library/library_provider.dart';

/// P1「质量指示」的数据源：曲库 JSON → Song 的字段映射。
///
/// 这层一旦键名写错，徽标只会安静地退化成「未知」，不会报错，
/// 所以用测试把 snake_case 键与回落值钉住。
void main() {
  test('接上 Rust 序列化出来的 snake_case 字段', () {
    final s = Song.fromJson(const {
      'path': '/music/a.flac',
      'title': 'A',
      'artist': 'B',
      'album': 'C',
      'album_key': 'C|B',
      'duration': 200,
      'format': 'flac',
      'cover_thumb_path': null,
      'sample_rate': 96000,
      'bit_depth': 24,
      'codec': 'flac',
    });
    expect(s.sampleRate, 96000);
    expect(s.bitDepth, 24);
    expect(s.codec, 'flac');
  });

  test('位深为 null 的有损格式不炸', () {
    final s = Song.fromJson(const {
      'path': '/music/a.mp3',
      'title': 'A',
      'duration': 100,
      'format': 'mp3',
      'sample_rate': 44100,
      'bit_depth': null,
      'codec': 'mp3',
    });
    expect(s.sampleRate, 44100);
    expect(s.bitDepth, isNull);
  });

  test('缺字段回落默认值（老数据/在线曲目）', () {
    final s = Song.fromJson(const {
      'path': '/x.mp3',
      'title': 'x',
      'duration': 1,
    });
    expect(s.sampleRate, 0, reason: '0 = 未知，徽标据此退化为不显示采样率');
    expect(s.bitDepth, isNull);
    expect(s.codec, isNull);
    expect(s.format, '');
  });
}
