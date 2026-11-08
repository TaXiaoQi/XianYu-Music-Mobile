// filterCachedAudio 纯函数测试：搜索 cache-first 链路的本地过滤判据
// （非目录、音频、文件名 contains 忽略大小写）与桌面端
// cloudScopedQuery.test.ts 的 filterCachedAudio 用例对齐。
// scopedSearchAudioDetailed / cloudKeywordSearchAudio 涉及 SecureStore
// 与网络 provider，不在此覆盖（MethodChannel mock 成本高，桌面端已同构覆盖）。

import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/cloud/cloud_scoped_query.dart';
import 'package:xianyu_music_mobile/src/cloud/cloud_types.dart';

void main() {
  group('filterCachedAudio', () {
    test('大小写不敏感且排除目录/非音频', () {
      final files = [
        const CloudFile(id: 'a', name: 'Song One.mp3'),
        const CloudFile(id: 'b', name: 'song two.FLAC'),
        const CloudFile(id: 'c', name: 'song dir', isDir: true),
        const CloudFile(id: 'd', name: 'note.txt'),
        const CloudFile(id: 'e', name: 'unrelated.mp3'),
      ];
      final out = filterCachedAudio(files, 'SONG');
      expect(out.map((f) => f.id).toList()..sort(), ['a', 'b']);
    });

    test('关键词为空返回空', () {
      final files = [const CloudFile(id: 'a', name: 'song.mp3')];
      expect(filterCachedAudio(files, '  '), isEmpty);
    });
  });
}
