import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/online/online_search_provider.dart';
import 'package:xianyu_music_mobile/src/player/player_provider.dart';

void main() {
  // 取自 lx_search 真实返回结构（snake_case）。
  Map<String, dynamic> sample() => {
        'name': '晴天',
        'singer': '周杰伦',
        'album_name': '叶惠美',
        'album_id': 1234,
        'songmid': '228908',
        'source': 'kw',
        'interval': '04:29',
        'img': 'https://img3.kuwo.cn/star/albumcover/x.jpg',
        'hash': null,
        'str_media_mid': null,
        'song_id': null,
        'album_mid': null,
        'copyright_id': null,
        'types': [],
        'lx_types': {
          '320k': {'size': '10MB', 'hash': 'abc'},
        },
      };

  group('OnlineTrack.fromJson', () {
    test('解析基础字段', () {
      final t = OnlineTrack.fromJson(sample());
      expect(t.title, '晴天');
      expect(t.artist, '周杰伦');
      expect(t.album, '叶惠美');
      expect(t.songmid, '228908');
      expect(t.source, 'kw');
      expect(t.interval, '04:29');
      expect(t.coverUrl, 'https://img3.kuwo.cn/star/albumcover/x.jpg');
    });

    test('缺失字段回退为空而不抛异常', () {
      final t = OnlineTrack.fromJson({'source': 'kw'});
      expect(t.title, '');
      expect(t.artist, '');
      expect(t.interval, '');
      expect(t.coverUrl, isNull);
      expect(t.durationSeconds, 0);
    });
  });

  group('durationSeconds', () {
    test('mm:ss 正确换算为秒', () {
      expect(OnlineTrack.fromJson(sample()).durationSeconds, 4 * 60 + 29);
    });

    test('超过一小时的 mm:ss 仍按分秒累加', () {
      final j = sample()..['interval'] = '75:30';
      expect(OnlineTrack.fromJson(j).durationSeconds, 75 * 60 + 30);
    });

    test('格式非法时返回 0', () {
      for (final bad in ['', '--:--', '3', '1:2:3', 'abc']) {
        final j = sample()..['interval'] = bad;
        expect(OnlineTrack.fromJson(j).durationSeconds, 0, reason: bad);
      }
    });
  });

  group('toQueueItem', () {
    test('生成 lx:// 路径并标记为在线', () {
      final item = OnlineTrack.fromJson(sample()).toQueueItem();
      expect(item.path, 'lx://kw/228908');
      expect(item.isOnline, isTrue);
      expect(item.source, 'kw');
      expect(item.durationMs, (4 * 60 + 29) * 1000);
      expect(item.coverUrl, isNotNull);
    });

    test('onlineInfoJson 使用 camelCase 以匹配 Rust LxUrlSongInfo', () {
      final item = OnlineTrack.fromJson(sample()).toQueueItem();
      final info = jsonDecode(item.onlineInfoJson!) as Map<String, dynamic>;
      // Rust 侧 #[serde(rename_all = "camelCase")]，键名必须是 camelCase。
      expect(info['songmid'], '228908');
      expect(info['source'], 'kw');
      expect(info['albumName'], '叶惠美');
      expect(info['albumId'], 1234);
      expect(info.containsKey('album_name'), isFalse);
      // 音质映射走 _types 这个特殊 rename。
      expect(info['_types'], isA<Map>());
      expect((info['_types'] as Map)['320k'], isA<Map>());
    });

    test('不带在线信息的条目判定为本地', () {
      // 对照本地曲目：library_provider 构造时不传 onlineInfoJson。
      const local = QueueItem(
        path: '/storage/music/a.flac',
        title: 'a',
        artist: 'b',
        album: 'c',
      );
      expect(local.isOnline, isFalse);
      expect(local.coverUrl, isNull);
    });
  });
}
