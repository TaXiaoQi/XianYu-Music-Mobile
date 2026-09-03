import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../library/library_provider.dart';
import '../navigation/routes.dart' show appNavigatorKey;
import '../online/online_search_provider.dart';
import '../player/player_provider.dart';
import '../plugin/plugin_provider.dart';
import '../plugin/plugin_search.dart';
import '../core/app_logger.dart';
import '../core/rust_init.dart';
import '../widgets/app_toast.dart';
import 'share_link_dialog.dart';
import '../i18n/i18n.dart';

/// xianyu:// 深链处理。
///
/// Android 端由 MainActivity 通过 MethodChannel('xianyu/deeplink') 把 intent 的
/// xianyu://song?... 深链透传到这里：解析歌名/歌手/时长/封面后，先弹「分享预览窗」
/// （封面/歌名/歌手/来源 + 播放/下一首播放/取消），用户点「播放」才进入播放，
/// 点「下一首播放」插入当前曲目之后（不自动起播）。播放/插队优先在本地曲库按
/// 「标题|歌手」(±5s 时长容差) 匹配——命中直接用本地文件；未命中再按来源走在线
/// 搜索定位。最后（仅播放）跳转播放页（push 而非 go，保证能返回首页）。
/// 这样落地页点「在弦予音乐中打开」就能拉起 App 并播放分享曲。
///
/// 防重复：`_busy` 保证同一时刻只处理一枚深链；`_openPlayerOnce` 保证播放页
/// 不重复压栈，杜绝「卡出 2 个播放器页面」。
class XianYuDeepLink {
  static const MethodChannel _channel = MethodChannel('xianyu/deeplink');

  static bool _initialized = false;

  /// 同一时刻只处理一枚深链：防止冷/热启同链被二次派发时重复弹分享预览窗、
  /// 重复压栈播放页（表现为「卡出 2 个播放器页面」）。
  static bool _busy = false;

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

  static Future<void> _handle(
    ProviderContainer container,
    GoRouter router,
    String raw,
  ) async {
    if (_busy) {
      AppLogger.instance.log('deeplink', '忽略重复的分享深链: $raw');
      return;
    }
    _busy = true;
    try {
      await _run(container, router, raw);
    } catch (e, st) {
      AppLogger.instance.log('deeplink', '分享深链解析异常: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  static Future<void> _run(
    ProviderContainer container,
    GoRouter router,
    String raw,
  ) async {
    try {
      // 组件/内部跳转链接：xianyu://open?target=xxx → 直接路由到对应页面。
      // 目前支持 recognize（桌面组件右上识曲钮）。
      final openUri = Uri.tryParse(raw);
      if (openUri != null && openUri.host == 'open') {
        // 系统文件管理器/分享面板把本地音频文件交给本应用打开：原生侧已把
        // content/file URI 物化为真实路径并封装成 target=file，这里直接播本地文件。
        if (openUri.queryParameters['target'] == 'file') {
          final file = openUri.queryParameters['file'] ?? '';
          final name = openUri.queryParameters['name'] ?? '';
          if (file.isNotEmpty) {
            await _playOpenedFile(container, router, file, name);
          }
          return;
        }
        final target = openUri.queryParameters['target'] ?? '';
        if (target == 'recognize' &&
            router.routerDelegate.currentConfiguration.uri.toString() != '/recognize') {
          router.push('/recognize');
          return;
        }
        if (target == 'share') {
          // 打开当前歌曲分享菜单（经瞬时桥接页提供 WidgetRef）。
          if (router.routerDelegate.currentConfiguration.uri.toString() !=
              '/shareBridge') {
            router.push('/shareBridge');
          }
          return;
        }
        return;
      }

      final p = _parseSong(raw);
      final name = p['name'] ?? '';
      if (name.isEmpty) return;
      AppLogger.instance.log('deeplink', '收到分享深链: $raw');

      final artist = p['artist'] ?? '';
      final source = p['source'] ?? '';
      final durationSec = int.tryParse(p['duration'] ?? '') ?? 0;
      final cover = p['cover'] ?? '';

      // 等待引擎与本地曲库就绪后再判定来源（本地命中显示「本地音乐」）
      final ready = await _ensureReady(container);
      if (!ready) {
        AppLogger.instance.log('deeplink', 'Rust 引擎初始化失败，无法播放分享歌曲');
        return;
      }
      final localSong = _tryLocalMatch(container, name, artist, durationSec);
      final isLocalShare = source == 'local' || source.isEmpty;

      // 分享预览窗：不同形态渲染不同按钮
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) {
        AppLogger.instance.log('deeplink', '无可用的导航上下文，跳过分享预览窗');
        return;
      }
      final overlay = Overlay.of(ctx, rootOverlay: true);

      // 本地命中 → 现有「本地方案」：播放 / 下一首播放 / 取消
      if (localSong != null) {
        final action = await showShareLinkPreviewDialog(
          context: ctx,
          name: name,
          artist: artist,
          sourceLabel: tr('本地音乐'),
          cover: cover,
        );
        if (action == ShareLinkPreviewAction.cancel) return;

        if (action == ShareLinkPreviewAction.playNext) {
          await _playNext(container, overlay, name, artist, source, durationSec,
              localSong);
          return;
        }
        await _playBySearch(container, router, name, artist, source, durationSec,
            localSong);
        return;
      }

      // 本地音乐分享（source 为 local 或空）且本地库没有 → 在线预判：
      // 在线可播放 → 「取消 + 本地无音源，前往在线播放」；在线也没有 → 「取消 + 前往导入音源」
      if (isLocalShare) {
        final online = await _searchOnlineShare(
            container, name, artist, source, durationSec);
        if (online != null) {
          final dctx = appNavigatorKey.currentContext;
          if (dctx == null || !dctx.mounted) return;
          final action = await showShareLinkPreviewDialog(
            context: dctx,
            name: name,
            artist: artist,
            sourceLabel: tr('本地无音源'),
            cover: cover,
            mode: ShareLinkDialogMode.online,
          );
          if (action == ShareLinkPreviewAction.cancel) return;

          if (action == ShareLinkPreviewAction.playNext) {
            await container
                .read(playerProvider.notifier)
                .playNextShare(online);
            showXianYuToastByOverlay(overlay, tr('已添加至下一首播放'));
            return;
          }
          await _playOnlineOnce(container, router, online);
          return;
        }

        final dctx = appNavigatorKey.currentContext;
        if (dctx == null || !dctx.mounted) return;
        final action = await showShareLinkPreviewDialog(
          context: dctx,
          name: name,
          artist: artist,
          sourceLabel: tr('未找到在线音源'),
          cover: cover,
          mode: ShareLinkDialogMode.import,
        );
        if (action == ShareLinkPreviewAction.cancel) return;
        if (action == ShareLinkPreviewAction.import) router.push('/plugin');
        return;
      }

      // 在线音源/插件来源分享：按 source 标签判断本地是否能播该音源，三态展示
      final ability = _resolveShareAbility(container, source);

      // A：本地有能播该 source 的插件 → 原样「播放 / 下一首播放 / 取消」
      if (ability.specified) {
        final action = await showShareLinkPreviewDialog(
          context: ctx,
          name: name,
          artist: artist,
          sourceLabel: _sourceLabel(source),
          cover: cover,
        );
        if (action == ShareLinkPreviewAction.cancel) return;
        if (action == ShareLinkPreviewAction.playNext) {
          await _playNext(container, overlay, name, artist, source, durationSec,
              localSong);
          return;
        }
        await _playBySearch(container, router, name, artist, source, durationSec,
            localSong);
        return;
      }

      // B：无对应标签音源但本地有其他音源插件 → 「取消 / 无指定音源，前往在线播放」（用其他可用源在线播放）
      if (ability.any) {
        final action = await showShareLinkPreviewDialog(
          context: ctx,
          name: name,
          artist: artist,
          sourceLabel: tr('无指定音源'),
          cover: cover,
          mode: ShareLinkDialogMode.online,
          onlineActionLabel: tr('无指定音源，前往在线播放'),
        );
        if (action == ShareLinkPreviewAction.cancel) return;
        await _playFallback(container, router, name, artist, source,
            durationSec);
        return;
      }

      // C：本地完全没有音源插件 → 「取消 / 前往导入音源」
      final action = await showShareLinkPreviewDialog(
        context: ctx,
        name: name,
        artist: artist,
        sourceLabel: tr('无可用音源'),
        cover: cover,
        mode: ShareLinkDialogMode.import,
      );
      if (action == ShareLinkPreviewAction.cancel) return;
      if (action == ShareLinkPreviewAction.import) router.push('/plugin');
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
      'cover': q['cover'] ?? '',
    };
  }

  /// 分享来源展示名：本地 → 本地音乐；lx 音源 → 平台名；
  /// 插件来源（深链携带插件名/id，如「酷我音乐」）→ 直接展示；其余 → 在线搜索。
  static String _sourceLabel(String source) {
    if (source == 'local') return tr('本地音乐');
    for (final s in kOnlineSources) {
      if (s.id == source) return s.label;
    }
    if (source.isNotEmpty) return source;
    return tr('在线搜索');
  }

  /// 等待 Rust 引擎就绪并确保本地曲库已加载（空曲库时主动加载一次）。
  /// 返回 false 表示引擎初始化失败，后续播放无法进行。
  static Future<bool> _ensureReady(ProviderContainer container) async {
    try {
      await container.read(rustInitProvider.future);
    } catch (_) {
      return false;
    }
    if (container.read(libraryProvider).songs.isEmpty) {
      try {
        await container.read(libraryProvider.notifier).load();
      } catch (_) {
        // 曲库加载失败不阻塞分享播放，走在线搜索兜底
      }
    }
    return true;
  }

  static Future<void> _playBySearch(
    ProviderContainer container,
    GoRouter router,
    String name,
    String artist,
    String source,
    int durationSec,
    Song? localSong,
  ) async {
    try {
      // 本地匹配命中：直接播放本地文件，避免在线搜索/解析失败导致「分享曲打不开」。
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
        _openPlayerOnce(router);
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
        _openPlayerOnce(router);
      } catch (e) {
        AppLogger.instance.log('deeplink', '播放分享歌曲失败: $e');
        _openPlayerOnce(router);
      }
    } catch (e, st) {
      // 兜底：任何未预期的异常都记录日志，避免变成未捕获异步错误导致整页报错。
      AppLogger.instance.log('deeplink', '分享深链处理异常: $e\n$st');
    }
  }

  /// 「下一首播放」：解析分享歌曲并插入到当前曲目之后，不自动起播、不打开播放页。
  /// 解析顺序与播放一致：本地曲库匹配 → 在线搜索最佳匹配。
  static Future<void> _playNext(
    ProviderContainer container,
    OverlayState overlay,
    String name,
    String artist,
    String source,
    int durationSec,
    Song? localSong,
  ) async {
    try {
      final playerNotifier = container.read(playerProvider.notifier);
      // 本地匹配命中：直接插队，避免在线搜索/解析失败。
      if (localSong != null) {
        AppLogger.instance.log('deeplink', '本地匹配命中分享曲(下一首): ${localSong.path}');
        await playerNotifier.playNextShare(localSong.toQueueItem());
        showXianYuToastByOverlay(overlay, tr('已添加至下一首播放'));
        return;
      }

      // 来源感知：带音源 key（kw/wy/kg/tx/mg）优先用该音源搜索。
      final searchNotifier = container.read(onlineSearchProvider.notifier);
      final src = kOnlineSources.any((s) => s.id == source) ? source : 'kw';
      await searchNotifier.setSource(src);
      final keyword = artist.isEmpty ? name : '$name $artist';
      try {
        await searchNotifier.search(keyword);
      } catch (e) {
        AppLogger.instance.log('deeplink', '分享歌曲在线搜索失败: $e');
        showXianYuToastByOverlay(overlay, tr('未找到分享的歌曲'));
        return;
      }
      final results = container.read(onlineSearchProvider).results;
      if (results.isEmpty) {
        showXianYuToastByOverlay(overlay, tr('未找到分享的歌曲'));
        return;
      }
      final index = _bestMatch(results, name, artist);
      final track = results[index];
      await playerNotifier.playNextShare(track.toQueueItem());
      showXianYuToastByOverlay(overlay, tr('已添加至下一首播放'));
    } catch (e, st) {
      AppLogger.instance.log('deeplink', '添加到下一首播放异常: $e\n$st');
    }
  }

  /// 「播放」跳转播放页：仅当播放页不在栈顶时才压入，避免重复压栈成 2 个播放页。
  static void _openPlayerOnce(GoRouter router) {
    if (router.routerDelegate.currentConfiguration.uri.toString() == '/player') {
      return;
    }
    router.push('/player');
  }

  /// 播放系统打开/分享进来的本地音频文件。文件路径由原生侧物化到缓存目录，
  /// 标题取文件原名的去扩展名部分（artist/album 置空）。直接浅层入队单曲并跳播放页。
  static Future<void> _playOpenedFile(
    ProviderContainer container,
    GoRouter router,
    String filePath,
    String rawName,
  ) async {
    AppLogger.instance.log('deeplink', '系统打开本地音乐: $filePath');
    var title = rawName.trim();
    if (title.isEmpty) {
      final seg = filePath.replaceAll('\\', '/').split('/').last;
      title = seg;
    }
    final dot = title.lastIndexOf('.');
    if (dot > 0) title = title.substring(0, dot);
    if (title.isEmpty) title = tr('未知歌曲');

    final item = QueueItem(
      path: filePath,
      title: title,
      artist: '',
      album: '',
    );
    final playerNotifier = container.read(playerProvider.notifier);
    try {
      await playerNotifier.playQueue([item], startIndex: 0, shareLinkPlayback: true);
      _openPlayerOnce(router);
    } catch (e, st) {
      AppLogger.instance.log('deeplink', '播放系统打开的本地音乐失败: $e\n$st');
    }
  }

  /// 本地分享且本地无音源时在线定位：先 lx 在线音源（来源感知，默认 kw），
  /// 无结果再遍历所有已启用音源插件搜索。返回可播放 [QueueItem] 或 null（在线也没有）。
  static Future<QueueItem?> _searchOnlineShare(
    ProviderContainer container,
    String name,
    String artist,
    String source,
    int durationSec,
  ) async {
    final keyword = artist.isEmpty ? name : '$name $artist';

    // 1. lx 在线音源搜索
    final searchNotifier = container.read(onlineSearchProvider.notifier);
    final src = kOnlineSources.any((s) => s.id == source) ? source : 'kw';
    try {
      await searchNotifier.setSource(src);
      await searchNotifier.search(keyword);
    } catch (_) {
      // 音源搜索失败不阻塞插件搜索
    }
    final results = container.read(onlineSearchProvider).results;
    if (results.isNotEmpty) {
      return results[_bestMatch(results, name, artist)].toQueueItem();
    }

    // 2. 音源插件搜索
    try {
      final manager = container.read(pluginManagerProvider);
      final engine = await container.read(pluginEngineProvider.future);
      final service = PluginSearchService(engine, manager.sources);
      final all = await service.searchAll(keyword, limit: 30);
      for (final (ps, items) in all) {
        if (items.isNotEmpty) return service.toQueueItem(ps, items.first);
      }
    } catch (_) {
      // 插件未装/搜索异常视为在线无结果
    }
    return null;
  }

  /// 播放一个已解析好的在线 [QueueItem]（开关分享播放标记，浅层入队单曲并跳播放页）。
  static Future<void> _playOnlineOnce(
    ProviderContainer container,
    GoRouter router,
    QueueItem item,
  ) async {
    final playerNotifier = container.read(playerProvider.notifier);
    try {
      await playerNotifier.playQueue(
        [item],
        startIndex: 0,
        shareLinkPlayback: true,
      );
      _openPlayerOnce(router);
    } catch (e) {
      AppLogger.instance.log('deeplink', '播放分享歌曲失败: $e');
      _openPlayerOnce(router);
    }
  }

  /// 按分享携带的 source 标签判定本地能否播放该音源：
  /// - specified：存在能处理该 source 的已启用插件（插件名/id 匹配，或插件声明的 sources 含该 source）
  /// - any：存在任意已启用插件（可作为其他可用源）。无任何插件时两者皆 false。
  static ({bool specified, bool any}) _resolveShareAbility(
    ProviderContainer container,
    String source,
  ) {
    final plugins = container
        .read(pluginManagerProvider)
        .sources
        .where((p) => p.enabled)
        .toList();
    if (plugins.isEmpty) return (specified: false, any: false);
    var specified = false;
    if (source.isNotEmpty) {
      for (final p in plugins) {
        if (p.name == source || p.id == source || p.sources.contains(source)) {
          specified = true;
          break;
        }
      }
    }
    return (specified: specified, any: true);
  }

  /// 无指定音源时用其他可用源在线播放（lx + 全部已启用插件兜底）。
  static Future<void> _playFallback(
    ProviderContainer container,
    GoRouter router,
    String name,
    String artist,
    String source,
    int durationSec,
  ) async {
    final online = await _searchOnlineShare(
        container, name, artist, source, durationSec);
    if (online == null) return;
    await _playOnlineOnce(container, router, online);
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
