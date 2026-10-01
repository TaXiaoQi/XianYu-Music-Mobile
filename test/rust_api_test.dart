import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xianyu_music_mobile/src/rust/api.dart';
import 'package:xianyu_music_mobile/src/rust/frb_generated.dart' show RustLib;

void main() {
  final dllPath = Platform.environment['XIANYU_DLL'] ??
      p.join('rust', 'target', 'debug', 'xianyu_core.dll');
  final hasDll = File(dllPath).existsSync();

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!hasDll) return;
    await RustLib.init(externalLibrary: ExternalLibrary.open(dllPath));
  });

  test('lx 搜索返回合法 JSON 数组结构', () async {
    if (!hasDll) return;
    final result = await lxSearch(source: 'kw', keyword: '测试', limit: 3);
    if (result != 'null') {
      final decoded = jsonDecode(result);
      expect(decoded, isA<List<dynamic>>(), reason: '搜索结果应为 JSON 数组');
    }
  });

  test('歌词解析返回 displayLines', () async {
    if (!hasDll) return;
    const raw = '[00:00.000]如果当时\n[00:03.000]人能顺着时光\n';
    final jsonStr = await parseLyrics(rawLyrics: raw);
    final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

    expect(decoded['displayLines'], isA<List<dynamic>>(),
        reason: '应包含 displayLines 展示行');
    final lines = decoded['displayLines'] as List<dynamic>;
    expect(lines, isNotEmpty, reason: 'LRC 应解析出至少一行');
    expect((lines.first as Map<String, dynamic>)['text'], isNotEmpty,
        reason: '首行应包含歌词文本');
  });

  test('歌词在线抓取对无效参数优雅失败', () async {
    if (!hasDll) return;
    await expectLater(
      fetchLyricFromSource(source: 'kg', songInfoJson: '{}'),
      throwsA(anything),
      reason: '无效歌曲信息应抛异常而非崩溃',
    );
  });

  test('播放会话保存-加载往返（播放记忆）', () async {
    if (!hasDll) return;
    final tmpDir =
        await Directory.systemTemp.createTemp('xianyu_session_test');
    final dbPath = p.join(tmpDir.path, 'library.db');
    addTearDown(() async {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    });

    final sessionJson = jsonEncode({
      'currentSongPath': 'lx://kw/12345',
      'playQueuePaths': ['lx://kw/12345', '/music/local.flac'],
      'sourceSongPaths': ['lx://kw/12345', '/music/local.flac'],
      'playMode': 2,
      'volume': 80.0,
      'currentPositionSecs': 95.5,
      'isPlaying': false,
      'sessionQualityOverride': null,
      'queueSongMeta': {
        'lx://kw/12345': {
          'path': 'lx://kw/12345',
          'title': '晴天',
          'artist': '周杰伦',
          'album': '叶惠美',
          'durationMs': 269000,
          'coverUrl': 'https://example.com/cover.jpg',
          'source': 'kw',
          'onlineInfoJson': '{"songmid":"12345"}',
        },
        '/music/local.flac': {
          'path': '/music/local.flac',
          'title': '本地歌',
          'artist': '歌手',
          'album': '专辑',
          'durationMs': 200000,
          'coverUrl': null,
          'source': null,
          'onlineInfoJson': null,
        },
      },
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });

    await savePlaybackSession(dbPath: dbPath, sessionJson: sessionJson);

    final loaded = await loadPlaybackSession(dbPath: dbPath);
    expect(loaded, isNot(anyOf('', 'null', '{}')),
        reason: '应加载出已保存的会话数据');

    final j = jsonDecode(loaded) as Map<String, dynamic>;
    expect(j['currentSongPath'], 'lx://kw/12345');
    expect((j['playQueuePaths'] as List).length, 2);
    expect(j['playMode'], 2);
    expect(j['currentPositionSecs'], 95.5);

    final meta = j['queueSongMeta'] as Map<String, dynamic>;
    expect(meta.length, 2, reason: '队列元数据应完整往返');
    expect((meta['lx://kw/12345'] as Map)['title'], '晴天');
  });
}
