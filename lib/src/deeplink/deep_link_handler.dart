// ignore_for_file: use_build_context_synchronously

import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../library/library_provider.dart';
import '../navigation/routes.dart' show appNavigatorKey;
import '../online/online_search_provider.dart';
import '../player/player_provider.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../plugin/plugin_search.dart';
import '../core/app_logger.dart';
import '../core/application_logger.dart';
import '../core/rust_init.dart';
import '../widgets/app_toast.dart';
import 'share_link_dialog.dart';
import '../i18n/i18n.dart';

class XianYuDeepLink {
  static const MethodChannel _channel = MethodChannel('xianyu/deeplink');

  static bool _initialized = false;

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
    final playUri = Uri.tryParse(raw);
    if (playUri != null && playUri.host == 'play') {
      final action = playUri.path.replaceFirst('/', '');
      final notifier = container.read(playerProvider.notifier);
      switch (action) {
        case 'toggle':
          notifier.toggle();
        case 'previous':
          notifier.previous();
        case 'next':
          notifier.next();
      }
      return;
    }
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

  static Future<BuildContext?> _waitNavigatorContext() async {
    for (var i = 0; i < 20; i++) {
      final ctx = appNavigatorKey.currentContext;
      if (ctx != null && ctx.mounted) return ctx;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  static Future<void> _run(
    ProviderContainer container,
    GoRouter router,
    String raw,
  ) async {
    try {
      final openUri = Uri.tryParse(raw);
      if (openUri != null && openUri.host == 'open') {
        if (openUri.queryParameters['target'] == 'file') {
          final file = openUri.queryParameters['file'] ?? '';
          final name = openUri.queryParameters['name'] ?? '';
          if (file.isNotEmpty) {
            await _playOpenedFile(container, router, file, name);
          }
          return;
        }
        if (openUri.queryParameters['target'] == 'plugin') {
          final file = openUri.queryParameters['file'] ?? '';
          final name = openUri.queryParameters['name'] ?? '';
          if (file.isNotEmpty) {
            await _importOpenedPlugin(container, router, file, name);
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

      final ready = await _ensureReady(container);
      if (!ready) {
        AppLogger.instance.log('deeplink', 'Rust 引擎初始化失败，无法播放分享歌曲');
        return;
      }
      final localSong = _tryLocalMatch(container, name, artist, durationSec);
      final isLocalShare = source == 'local' || source.isEmpty;

      final ctx = await _waitNavigatorContext();
      if (ctx == null) {
        AppLogger.instance.log('deeplink', '等待导航上下文超时，跳过分享预览窗');
        return;
      }
      final overlay = appNavigatorKey.currentState?.overlay;
      if (overlay == null) {
        AppLogger.instance.log('deeplink', '根 Overlay 未就绪，跳过分享预览窗');
        return;
      }

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

      if (isLocalShare) {
        final online = await _searchOnlineShare(
            container, name, artist, source, durationSec);
        if (online != null) {
          final action = await showShareLinkPreviewDialog(
            context: ctx,
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

        final action = await showShareLinkPreviewDialog(
          context: ctx,
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

      final ability = _resolveShareAbility(container, source);

      if (ability.specified) {
        final action = await showShareLinkPreviewDialog(
          context: ctx,
          name: name,
          artist: artist,
          sourceLabel: _sourceLabel(container, source),
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
      AppLog.error('deeplink', '深链处理异常: $e');
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

  static PluginSource? _matchPlugin(
    ProviderContainer container,
    String source,
  ) {
    if (source.isEmpty) return null;
    for (final p in container.read(pluginManagerProvider).sources) {
      if (!p.enabled) continue;
      if (p.id == source || p.name == source || p.sources.contains(source)) {
        return p;
      }
    }
    return null;
  }

  static String _sourceLabel(ProviderContainer container, String source) {
    if (source == 'local') return tr('本地音乐');
    for (final s in kOnlineSources) {
      if (s.id == source) return s.label;
    }
    final plugin = _matchPlugin(container, source);
    if (plugin != null) return plugin.name;
    if (source.isNotEmpty) return source;
    return tr('在线搜索');
  }

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
      final matchedPlugin = _matchPlugin(container, source);
      if (matchedPlugin != null) {
        final item = await _searchViaPlugin(
            container, matchedPlugin, name, artist);
        if (item != null) {
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
          return;
        }
      }

      final src = kOnlineSources.any((s) => s.id == source) ? source : 'kw';
      await searchNotifier.setSource(src);

      final keyword = artist.isEmpty ? name : '$name $artist';
      try {
        await searchNotifier.search(keyword);
      } catch (e) {
        AppLogger.instance.log('deeplink', '分享歌曲在线搜索失败: $e');
        return;
      }

      final results = container.read(onlineSearchProvider).results;
      if (results.isEmpty) return;

      final index =
          _bestMatch([for (final t in results) (t.title, t.artist)], name, artist);
      final track = results[index];
      final playerNotifier = container.read(playerProvider.notifier);
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
      AppLogger.instance.log('deeplink', '分享深链处理异常: $e\n$st');
    }
  }

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
      if (localSong != null) {
        AppLogger.instance.log('deeplink', '本地匹配命中分享曲(下一首): ${localSong.path}');
        await playerNotifier.playNextShare(localSong.toQueueItem());
        showXianYuToastByOverlay(overlay, tr('已添加至下一首播放'));
        return;
      }

      final matchedPlugin = _matchPlugin(container, source);
      if (matchedPlugin != null) {
        final item =
            await _searchViaPlugin(container, matchedPlugin, name, artist);
        if (item != null) {
          await playerNotifier.playNextShare(item);
          showXianYuToastByOverlay(overlay, tr('已添加至下一首播放'));
          return;
        }
      }

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
      final index =
          _bestMatch([for (final t in results) (t.title, t.artist)], name, artist);
      final track = results[index];
      await playerNotifier.playNextShare(track.toQueueItem());
      showXianYuToastByOverlay(overlay, tr('已添加至下一首播放'));
    } catch (e, st) {
      AppLogger.instance.log('deeplink', '添加到下一首播放异常: $e\n$st');
    }
  }

  static void _openPlayerOnce(GoRouter router) {
    if (router.routerDelegate.currentConfiguration.uri.toString() == '/player') {
      return;
    }
    router.push('/player');
  }

  static Future<void> _importOpenedPlugin(
    ProviderContainer container,
    GoRouter router,
    String filePath,
    String rawName,
  ) async {
    AppLogger.instance.log('deeplink', '系统打开插件脚本: $filePath');
    try {
      final bytes = await File(filePath).readAsBytes();
      final script = utf8.decode(bytes, allowMalformed: true);
      final fileName = rawName.trim().isNotEmpty
          ? rawName.trim()
          : filePath.replaceAll('\\', '/').split('/').last;
      final source = await container
          .read(pluginManagerProvider.notifier)
          .installFromScript(script, fileName: fileName);
      await _waitNavigatorContext();
      final overlay = appNavigatorKey.currentState?.overlay;
      if (overlay != null) {
        showXianYuToastByOverlay(
            overlay, tr('插件已导入：{name}', {'name': source.name}));
      }
      if (router.routerDelegate.currentConfiguration.uri.toString() != '/plugin') {
        router.push('/plugin');
      }
    } catch (e, st) {
      AppLogger.instance.log('deeplink', '导入系统打开的插件脚本失败: $e\n$st');
      final overlay = appNavigatorKey.currentState?.overlay;
      if (overlay != null) {
        final where = st
            .toString()
            .split('\n')
            .take(2)
            .join('  ');
        showXianYuToastByOverlay(overlay, '${tr('插件导入失败')}: $e\n$where');
      }
    }
  }

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

  static Future<QueueItem?> _searchOnlineShare(
    ProviderContainer container,
    String name,
    String artist,
    String source,
    int durationSec,
  ) async {
    final keyword = artist.isEmpty ? name : '$name $artist';

    final searchNotifier = container.read(onlineSearchProvider.notifier);
    final src = kOnlineSources.any((s) => s.id == source) ? source : 'kw';
    try {
      await searchNotifier.setSource(src);
      await searchNotifier.search(keyword);
    } catch (_) {
    }
    final results = container.read(onlineSearchProvider).results;
    if (results.isNotEmpty) {
      return results[_bestMatch(
              [for (final t in results) (t.title, t.artist)], name, artist)]
          .toQueueItem();
    }

    try {
      final manager = container.read(pluginManagerProvider);
      final engine = await container.read(pluginEngineProvider.future);
      final service = PluginSearchService(engine, manager.sources);
      final all = await service.searchAll(keyword, limit: 30);
      for (final (ps, items) in all) {
        if (items.isNotEmpty) return service.toQueueItem(ps, items.first);
      }
    } catch (_) {
    }
    return null;
  }

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

  static Future<QueueItem?> _searchViaPlugin(
    ProviderContainer container,
    PluginSource plugin,
    String name,
    String artist,
  ) async {
    try {
      final engine = await container.read(pluginEngineProvider.future);
      final service = PluginSearchService(engine, [plugin]);
      final keyword = artist.isEmpty ? name : '$name $artist';
      final all = await service.searchAll(keyword, limit: 30);
      for (final (_, items) in all) {
        if (items.isEmpty) continue;
        final idx = _bestMatch(
          [for (final r in items) (r.name, r.singer)],
          name,
          artist,
        );
        return service.toQueueItem(plugin, items[idx]);
      }
    } catch (e) {
      AppLogger.instance.log('deeplink', '插件搜索分享曲失败: $e');
    }
    return null;
  }

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

  static int _bestMatch(
    List<(String, String)> results,
    String name,
    String artist,
  ) {
    final ln = name.trim().toLowerCase();
    int best = 0;
    int bestScore = -1;
    for (var i = 0; i < results.length; i++) {
      final tn = results[i].$1.trim().toLowerCase();
      final ta = results[i].$2.trim().toLowerCase();
      var score = 0;
      if (tn == ln) {
        score += 3;
      } else if (tn.contains(ln)) {
        score += 2;
      } else if (ln.contains(tn)) {
        score += 1;
      }
      if (artist.isNotEmpty && ta.contains(artist.trim().toLowerCase())) {
        score += 2;
      }
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
  }

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
