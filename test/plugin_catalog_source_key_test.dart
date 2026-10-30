import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/player/player_provider.dart';
import 'package:xianyu_music_mobile/src/plugin/plugin_catalog.dart';
import 'package:xianyu_music_mobile/src/plugin/plugin_models.dart';

// 回归：酷狗歌单导入的歌曲播放报「无支持的音乐平台」——
// toQueueItem 此前不写 songJson 顶层 source，LX 聚合源取链依赖平台键
PluginSource _lxSource({List<String> sources = const []}) => PluginSource(
      id: 'pid-lx',
      name: 'Hei Music聚合源',
      format: PluginFormat.lx,
      importedAt: 1,
      sources: sources,
    );

PluginSource _mfSource() => PluginSource(
      id: 'pid-mf',
      name: '某MF插件',
      format: PluginFormat.musicfree,
      importedAt: 1,
    );

PluginSearchResult _track({String? platform, String? source}) =>
    PluginSearchResult(
      name: '测试歌',
      singer: '测试歌手',
      albumName: '测试专辑',
      songmid: '797485',
      source: source ?? platform ?? '',
    );

Map<String, dynamic> _songJsonOf(QueueItem item) =>
    jsonDecode(item.onlineSongJson!) as Map<String, dynamic>;

void main() {
  test('宿主导入曲目带 platform=kg 时写入顶层 source=kg', () {
    final item = PluginCatalogService.toQueueItem(
      _lxSource(sources: ['kg', 'kw']),
      _track(platform: 'kg'),
    );
    expect(_songJsonOf(item)['source'], 'kg');
  });

  test('中文平台显示名归一化为 lx 平台键', () {
    final item = PluginCatalogService.toQueueItem(
      _lxSource(sources: ['kg']),
      _track(platform: '酷狗音乐'),
    );
    expect(_songJsonOf(item)['source'], 'kg');
  });

  test('曲目缺平台信息时回退插件唯一声明平台', () {
    final item = PluginCatalogService.toQueueItem(
      _lxSource(sources: ['kg']),
      _track(),
    );
    expect(_songJsonOf(item)['source'], 'kg');
  });

  test('多平台插件且曲目缺平台信息时不写猜测值', () {
    final item = PluginCatalogService.toQueueItem(
      _lxSource(sources: ['kg', 'kw', 'wy']),
      _track(),
    );
    expect(_songJsonOf(item).containsKey('source'), isFalse);
  });

  test('MF 格式插件保持原样不写 source', () {
    final item = PluginCatalogService.toQueueItem(
      _mfSource(),
      _track(platform: 'bilibili'),
    );
    final json = _songJsonOf(item);
    expect(json.containsKey('source'), isFalse);
    expect(json['pluginId'], 'pid-mf');
    expect(json['format'], 'musicfree');
  });
}
