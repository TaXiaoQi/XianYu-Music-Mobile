import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../library/library_provider.dart';
import '../online/online_search_provider.dart';
import '../player/player_provider.dart';
import '../core/app_logger.dart';
import '../core/rust_init.dart';

/// xianyu:// 深链处理。
///
/// Android 端由 MainActivity 通过 MethodChannel('xianyu/deeplink') 把 intent 的
/// xianyu://song?... 深链透传到这里：解析歌名/歌手/时长后，优先在本地曲库按
/// 「标题|歌手」(±5s 时长容差) 匹配——命中则直接播放本地文件；未命中再走在线
/// 搜索定位歌曲并播放。最后跳转到播放页（push 而非 go，保证能返回首页）。
/// 这样落地页点「在弦予音乐中打开」就能拉起 App 并播放分享曲。
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
    try {
      final p = _parseSong(raw);
      final name = p['name'] ?? '';
      if (name.isEmpty) return;
      AppLogger.instance.log('deeplink', '收到分享深链: $raw');
      _playBySearch(
        container,
        router,
        name,
        p['artist'] ?? '',
        p['source'] ?? '',
        int.tryParse(p['duration'] ?? '') ?? 0,
      );
    } catch (e, st) {
      AppLogger.instance.log('deeplink', '分享深链解析异常: $e\n$st');
    }
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
    int durationSec,
  ) async {
    try {
      // 冷启动深链可能早于 Rust 引擎就绪：先等待初始化完成，避免搜索/解析
      // 在引擎未就绪时静默失败（表现为「点了打开却没反应」）。
      try {
        await container.read(rustInitProvider.future);
      } catch (_) {
        AppLogger.instance.log('deeplink', 'Rust 引擎初始化失败，无法播放分享歌曲');
        return;
      }

      // 优先本地匹配：移动端若本地曲库有同名同歌手的歌曲（±5s 时长容差），
      // 直接播放本地文件，避免在线搜索/解析失败导致「分享曲打不开」。
      // 对齐 sync_provider._resolveLocalPath 的匹配规则，保证两端一致。
      if (container.read(libraryProvider).songs.isEmpty) {
        await container.read(libraryProvider.notifier).load();
      }
      final localSong = _tryLocalMatch(container, name, artist, durationSec);
      if (localSong != null) {
        AppLogger.instance.log('deeplink', '本地匹配命中分享曲: ${localSong.path}');
        final playerNotifier = container.read(playerProvider.notifier);
        try {
          await playerNotifier.playQueue(
            [localSong.toQueueItem()],
            startIndex: 0,
          );
        } catch (e) {
          AppLogger.instance.log('deeplink', '本地播放分享曲失败: $e');
        }
        router.push('/player');
        return;
      }

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
        router.push('/player');
      } catch (e) {
        AppLogger.instance.log('deeplink', '播放分享歌曲失败: $e');
        router.push('/player');
      }
    } catch (e, st) {
      // 兜底：任何未预期的异常都记录日志，避免变成未捕获异步错误导致整页报错。
      AppLogger.instance.log('deeplink', '分享深链处理异常: $e\n$st');
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

  /// 在本地曲库中按「标题|歌手」（±5s 时长容差）匹配分享歌曲。
  /// 命中则返回本地 Song，直接播放本地文件，避免在线搜索/解析失败。
  /// 匹配规则与 sync_provider._resolveLocalPath 保持一致：
  /// 唯一命中直接采用；多候选时用时长消歧（±5s）。
  static Song? _tryLocalMatch(
    ProviderContainer container,
    String name,
    String artist,
    int durationSec,
  ) {
    final library = container.read(libraryProvider);
    if (library.songs.isEmpty) return null;
    final key = '${_normMeta(name)}|${_normMeta(artist)}';
    final candidates = <Song>[];
    for (final s in library.songs) {
      if ('${_normMeta(s.title)}|${_normMeta(s.artist)}' == key) {
        candidates.add(s);
      }
    }
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;
    if (durationSec <= 0) return candidates.first;
    Song? best;
    var bestDiff = 5;
    for (final c in candidates) {
      final diff = (c.duration - durationSec).abs();
      if (diff <= bestDiff) {
        bestDiff = diff;
        best = c;
      }
    }
    return best;
  }

  static String _normMeta(String s) => s.trim().toLowerCase();
}