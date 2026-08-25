import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../online/online_search_provider.dart';
import '../player/player_provider.dart';
import '../core/app_logger.dart';

/// xianyu:// 深链处理。
///
/// Android 端由 MainActivity 通过 MethodChannel('xianyu/deeplink') 把 intent 的
/// xianyu://song?... 深链透传到这里：解析歌名/歌手后，调用在线搜索定位歌曲并播放，
/// 再跳转到播放页。这样落地页点「在弦予音乐中打开」就能拉起 App 并播放分享曲。
class XianYuDeepLink {
  static const MethodChannel _channel = MethodChannel('xianyu/deeplink');

  static bool _initialized = false;

  static void init(ProviderContainer container, GoRouter router) {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDeepLink') {
        final raw = call.arguments as String?;
        if (raw != null && raw.isNotEmpty) {
          _handle(container, router, raw);
        }
      }
      return null;
    });

    // 冷启动：创建时可能已有一枚深链暂存在原生侧，主动取一次。
    _channel
        .invokeMethod<String>('getInitialDeepLink')
        .then((raw) {
          if (raw != null && raw.isNotEmpty) {
            _handle(container, router, raw);
          }
        })
        .catchError((Object _) {});
  }

  static void _handle(
    ProviderContainer container,
    GoRouter router,
    String raw,
  ) {
    final p = _parseSong(raw);
    final name = p['name'] ?? '';
    if (name.isEmpty) return;
    AppLogger.instance.log('deeplink', '收到分享深链: $raw');
    _playBySearch(container, router, name, p['artist'] ?? '', p['source'] ?? '');
  }

  static Map<String, String> _parseSong(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return const {};
    final q = uri.queryParameters;
    return {
      'id': q['id'] ?? '',
      'hash': q['hash'] ?? '',
      'name': q['name'] ?? '',
      'artist': q['artist'] ?? '',
      'duration': q['duration'] ?? '0',
      'source': q['source'] ?? '',
    };
  }

  static Future<void> _playBySearch(
    ProviderContainer container,
    GoRouter router,
    String name,
    String artist,
    String source,
  ) async {
    final searchNotifier = container.read(onlineSearchProvider.notifier);
    // 来源感知：分享链接带音源 key（kw/wy/kg/tx/mg）时优先用该音源搜索，
    // 命中率更高；'local' 或未知来源则回到默认音源。
    final src = kOnlineSources.any((s) => s.id == source) ? source : 'kw';
    await searchNotifier.setSource(src);

    // 用「歌名 + 歌手」搜索提高命中率；空歌手则仅歌名。
    final keyword = artist.isEmpty ? name : '$name $artist';
    try {
      await searchNotifier.search(keyword);
    } catch (e) {
      AppLogger.instance.log('deeplink', '分享歌曲在线搜索失败: $e');
      return;
    }

    final results = container.read(onlineSearchProvider).results;
    if (results.isEmpty) return;

    final index = _bestMatch(results, name, artist);
    final track = results[index];
    final playerNotifier = container.read(playerProvider.notifier);
    // 浅层播放分享曲：只入队最佳匹配这一首（不连播整个搜索结果）。
    // 播放失败行为由 player 侧按「分享链接播放失败行为」设置处理：
    // pause → 停止并显示错误；replace → 走插件索引换源重播。
    try {
      await playerNotifier.playQueue(
        [track.toQueueItem()],
        startIndex: 0,
        shareLinkPlayback: true,
      );
      router.go('/player');
    } catch (e) {
      AppLogger.instance.log('deeplink', '播放分享歌曲失败: $e');
      router.go('/player');
    }
  }

  /// 优先最接近的歌名，再叠加歌手匹配；都无则默认第一条。
  static int _bestMatch(
    List<OnlineTrack> results,
    String name,
    String artist,
  ) {
    final ln = name.trim().toLowerCase();
    int best = 0;
    int bestScore = -1;
    for (var i = 0; i < results.length; i++) {
      final t = results[i];
      var score = 0;
      final tn = t.title.trim().toLowerCase();
      if (tn == ln) {
        score += 3;
      } else if (tn.contains(ln)) {
        score += 2;
      } else if (ln.contains(tn)) {
        score += 1;
      }
      if (artist.isNotEmpty &&
          t.artist.trim().toLowerCase().contains(artist.trim().toLowerCase())) {
        score += 2;
      }
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
  }
}