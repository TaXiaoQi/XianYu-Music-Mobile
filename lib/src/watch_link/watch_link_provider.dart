import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../auth/auth_provider.dart';
import '../backup/app_backup.dart';
import '../core/platform_caps.dart';
import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../i18n/i18n.dart';
import '../library/saf_channel.dart';
import '../lyrics/lyrics_repository.dart';
import '../navigation/routes.dart';
import '../online/cover_proxy.dart';
import '../player/player_provider.dart';
import '../widgets/modern_dialog.dart';
import '../widgets/predictive_dialog_route.dart';
import 'cloud_channel.dart';
import 'protocol.dart';
import 'watch_link_channel.dart';

const String kWatchCloudRelayUrl = 'wss://api.xianyumusic.cn/watch-relay';

class WatchLinkController {
  WatchLinkController(this._container);

  final ProviderContainer _container;
  final WatchLinkChannel _channel = WatchLinkChannel();
  final WatchCloudChannel _cloud = WatchCloudChannel();
  FrameDecoder _decoder = FrameDecoder();

  final FrameDecoder _cloudDecoder = FrameDecoder();
  final int Function() _nextSeq = makeSeqGenerator();

  final List<StreamSubscription<dynamic>> _subs = [];
  final List<ProviderSubscription<dynamic>> _providerSubs = [];

  bool _running = false;
  bool _connected = false;
  String _connectedName = '';

  // ---- 云端兜底通道状态 ----

  bool _cloudRunning = false;

  bool _cloudWatchOnline = false;

  String _cloudWatchName = '';

  Timer? _cloudReconnect;
  Duration _cloudBackoff = const Duration(seconds: 5);

  bool _transferActive = false;

  bool _sessionDenied = false;

  Future<void>? _askInFlight;

  bool _backupDialogActive = false;

  bool _logDialogActive = false;

  String get connectedName => _connectedName;

  String? _songKey;

  final Map<String, String> _coverDataCache = {};

  String? _lyricSentSongId;

  final Set<String> _precachedPaths = {};
  bool _lastPlaying = false;
  LinkPlayMode _lastMode = LinkPlayMode.order;
  bool _lastLiked = false;
  DateTime _lastPosPush = DateTime.fromMillisecondsSinceEpoch(0);

  void init() {
    if (!PlatformCaps.isAndroid) return;
    _channel.bind();
    beforePlayGate = _playGate;
    _subs.add(_channel.onRaw.listen(_onRaw));
    _subs.add(_channel.onConnection.listen(_onConnection));
    _subs.add(_channel.onPermission.listen(_onPermission));
    _subs.add(_cloud.onRaw.listen(_onCloudRaw));
    _subs.add(_cloud.onEvent.listen(_onCloudEvent));

    _providerSubs.add(_container.listen<AsyncValue<AppSettings>>(
      settingsProvider,
      (prev, next) {
        final s = next.valueOrNull;
        if (s != null) _applyLinkSettings(s);
      },
      fireImmediately: true,
    ));

    _providerSubs.add(_container.listen<PlaybackState>(
      playerProvider,
      (_, st) => _onPlayback(st),
    ));

    _providerSubs.add(_container.listen<FavoritesState>(
      favoritesProvider,
      (_, _) => _pushState(),
    ));

    _providerSubs.add(_container.listen<AsyncValue<AppSettings>>(
      settingsProvider,
      (prev, next) {
        if (next.hasValue && _connected) _pushState();
      },
    ));
  }

  void dispose() {
    beforePlayGate = null;
    for (final s in _subs) {
      s.cancel();
    }
    for (final s in _providerSubs) {
      s.close();
    }
    _cloudReconnect?.cancel();
    _cloud.close();
    _channel.stop();
  }

  // ---- 开关与权限 ----

  void _applyLinkSettings(AppSettings s) {
    _applyEnabled(s.watchLinkageEnabled);
    _applyCloud(
      PlatformCaps.isAndroid &&
          s.watchLinkageEnabled &&
          s.watchLinkCloudEnabled,
    );
  }

  Future<void> _applyEnabled(bool enabled) async {
    if (!enabled) {
      await _channel.stop();
      _running = false;
      return;
    }
    if (_running) return;
    final granted = await _channel.hasPermission();
    if (granted) {
      await _channel.start();
      _running = true;
    } else {
      await _channel.requestPermission();
    }
  }

  void _onPermission(bool granted) {
    if (!granted || _running) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if (s?.watchLinkageEnabled != true) return;
    _channel.start().then((_) => _running = true);
  }

  // ---- 云端兜底通道（P4） ----

  Future<void> _applyCloud(bool desired) async {
    if (!desired) {
      _cloudRunning = false;
      _cloudWatchOnline = false;
      _container.read(watchLinkCloudOnlineProvider.notifier).state = false;
      _cloudReconnect?.cancel();
      await _cloud.close();
      return;
    }
    if (_cloudRunning) return;
    _cloudRunning = true;
    final key = await _ensureCloudKey();
    if (_cloudRunning && key.isNotEmpty) _connectCloud();
  }

  Future<String> _ensureCloudKey() async {
    final s = _container.read(settingsProvider).valueOrNull;
    final existing = s?.watchLinkCloudKey ?? '';
    if (existing.isNotEmpty) return existing;
    final rnd = Random.secure();
    final key = List.generate(32, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await _container.read(settingsProvider.notifier).setWatchLinkCloudKey(key);
    return key;
  }

  void _connectCloud() {
    _cloudReconnect?.cancel();
    _cloudWatchOnline = false;
    _container.read(watchLinkCloudOnlineProvider.notifier).state = false;
    _cloud.connect(url: kWatchCloudRelayUrl, key: _cloudKeyOf());
  }

  String _cloudKeyOf() =>
      _container.read(settingsProvider).valueOrNull?.watchLinkCloudKey ?? '';

  void _onCloudRaw(Uint8List bytes) {
    for (final msg in _cloudDecoder.feed(bytes)) {
      _onMessage(msg, fromCloud: true);
    }
  }

  void _onCloudEvent(CloudLinkEvent evt) {
    switch (evt.kind) {
      case CloudLinkEvent.ready:
        _cloudWatchOnline = true;
        _container.read(watchLinkCloudOnlineProvider.notifier).state = true;
        _cloudBackoff = const Duration(seconds: 5);
      case CloudLinkEvent.peerLost:
        _cloudWatchOnline = false;
        _container.read(watchLinkCloudOnlineProvider.notifier).state = false;
      case CloudLinkEvent.replaced:
      case CloudLinkEvent.closed:
        _cloudWatchOnline = false;
        _container.read(watchLinkCloudOnlineProvider.notifier).state = false;
        if (_cloudRunning) {
          _cloudReconnect?.cancel();
          _cloudReconnect = Timer(_cloudBackoff, () {
            _cloudBackoff = _cloudBackoff * 2 > const Duration(seconds: 60)
                ? const Duration(seconds: 60)
                : _cloudBackoff * 2;
            _connectCloud();
          });
        }
    }
  }

  // ---- 连接事件 ----

  void _onConnection(WatchLinkConnection evt) {
    _connected = evt.connected;
    _connectedName = evt.name;
    _container.read(watchLinkConnectedNameProvider.notifier).state = evt.name;
    _songKey = null;
    _precachedPaths.clear();
    _decoder = FrameDecoder();
  }

  // ---- 设备管理（设置页） ----

  Future<List<WatchBondedDevice>> loadPairedDevices() =>
      _channel.pairedDevices();

  Future<bool> connectToWatch(String address) async {
    if (_connected) return true;
    if (!await _channel.hasPermission()) {
      await _channel.requestPermission();
      return false;
    }
    _channel.connect(address);
    return true;
  }

  Future<void> disconnectWatch() async {
    await _channel.disconnect();
    if (_cloudRunning) {
      _cloudReconnect?.cancel();
      await _cloud.close();
      _cloudReconnect = Timer(const Duration(seconds: 3), _connectCloud);
    }
  }

  // ---- 字节入口与消息分发 ----

  void _onRaw(Uint8List bytes) {
    for (final msg in _decoder.feed(bytes)) {
      _onMessage(msg);
    }
  }

  void _onMessage(LinkMessage msg, {bool fromCloud = false}) {
    switch (msg.type) {
      case LinkMsgType.hello:
        if (fromCloud) {
          _cloudWatchName = (msg.payload['name'] as String?) ?? '';
          _send(LinkMessage.hello(
            ver: kLinkProtocolVersion,
            role: 'phone',
            name: '弦予音乐',
          ), cloud: true);
          _pushSnapshot(cloud: true);
          _maybeAskOnHandshake();
        } else {
          _send(LinkMessage.hello(
            ver: kLinkProtocolVersion,
            role: 'phone',
            name: '弦予音乐',
          ));
          _pushSnapshot();
          _maybePushCloudBind();
          _maybeAskOnHandshake();
        }
      case LinkMsgType.ping:
        _send(LinkMessage(LinkMsgType.pong, {
          't': msg.payload['t'],
        }), cloud: fromCloud);
      case LinkMsgType.bye:
        break;
      case LinkMsgType.cmd:
        _onCmd(msg);
      case LinkMsgType.backupFile:
        _handleIncomingBackup(msg);
      case LinkMsgType.watchLogFile:
        _handleIncomingLog(msg, fromCloud: fromCloud);
      default:
        break;
    }
  }

  void _maybePushCloudBind() {
    final s = _container.read(settingsProvider).valueOrNull;
    if (s?.watchLinkCloudEnabled != true) return;
    final key = s?.watchLinkCloudKey ?? '';
    if (key.isEmpty) return;
    _send(LinkMessage.cloudBind(key: key, url: kWatchCloudRelayUrl));
  }

  Future<void> _onCmd(LinkMessage msg) async {
    final notifier = _container.read(playerProvider.notifier);
    switch (msg.action()) {
      case LinkCmdAction.toggle:
        await notifier.toggle();
      case LinkCmdAction.next:
        await notifier.next();
      case LinkCmdAction.prev:
        await notifier.previous();
      case LinkCmdAction.like:
        await notifier.toggleFavoriteFromSystem();
      case LinkCmdAction.dislike:
        await _dislikeAndSkip();
      case LinkCmdAction.mode:
        await notifier.cyclePlayMode();
      case LinkCmdAction.seek:
        final arg = msg.payload['arg'];
        final pos = arg is Map ? (arg['pos'] as num?)?.toDouble() : null;
        if (pos != null) await notifier.seek(pos);
      case LinkCmdAction.volume:
        final arg = msg.payload['arg'];
        final v = arg is Map ? (arg['v'] as num?)?.toDouble() : null;
        if (v != null) {
          await _container
              .read(settingsProvider.notifier)
              .setVolume(v.clamp(0.0, 1.0));
          _pushState();
        }
      default:
        break;
    }
  }

  Future<void> _dislikeAndSkip() async {
    final item = _container.read(playerProvider).current;
    if (item == null) return;
    final ciyuanxiId =
        _container.read(authProvider).user?.ciyuanxiId?.trim() ?? '';
    if (ciyuanxiId.isNotEmpty) {
      try {
        await _container.read(authProvider.notifier).requestAction(
          'report_daily_dislike',
          {
            'ciyuanxi_id': ciyuanxiId,
            'song_name': item.title,
            'singer': item.artist,
          },
        );
      } catch (_) {}
    }
    await _container.read(playerProvider.notifier).next();
  }

  /// 收到腕上推送的备份文件：弹窗（禁止点击空白关闭），按结果回执给腕上。
  Future<void> _handleIncomingBackup(LinkMessage msg) async {
    if (_backupDialogActive) {
      _send(LinkMessage.backupAck(result: 'cancelled'));
      return;
    }
    final content = msg.payload['backup'] as String? ?? '';
    if (content.isEmpty) {
      _send(LinkMessage.backupAck(result: 'cancelled'));
      return;
    }
    final name = (msg.payload['name'] as String? ?? '').trim();
    _backupDialogActive = true;
    try {
      final context = appNavigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      final result = await showPredictiveDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _IncomingBackupDialog(
          fileName: name.isEmpty ? backupFileName() : name,
          content: content,
        ),
      );
      _send(LinkMessage.backupAck(
        result: result == 'saved' ? 'saved' : 'cancelled',
      ));
    } finally {
      _backupDialogActive = false;
    }
  }

  /// 收到腕上推送的运行日志：弹窗提供系统分享（与「导出日志文件」一致），
  /// 分享/留存后回执 saved，放弃回执 cancelled。
  Future<void> _handleIncomingLog(
    LinkMessage msg, {
    bool fromCloud = false,
  }) async {
    if (_logDialogActive) {
      _send(LinkMessage.backupAck(result: 'cancelled'), cloud: fromCloud);
      return;
    }
    final content = msg.payload['log'] as String? ?? '';
    if (content.isEmpty) {
      _send(LinkMessage.backupAck(result: 'cancelled'), cloud: fromCloud);
      return;
    }
    final name = (msg.payload['name'] as String? ?? '').trim();
    _logDialogActive = true;
    try {
      final context = appNavigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      final result = await showPredictiveDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _IncomingLogDialog(
          fileName: name.isEmpty ? 'xianyu-watch-log.txt' : name,
          content: content,
        ),
      );
      _send(
        LinkMessage.backupAck(
          result: result == 'saved' ? 'saved' : 'cancelled',
        ),
        cloud: fromCloud,
      );
    } finally {
      _logDialogActive = false;
    }
  }

  // ---- 状态推送 ----

  void _onPlayback(PlaybackState st) {
    if (!_connected && !_cloudWatchOnline) return;
    final item = st.current;
    final key = item == null
        ? null
        : '${item.path}|${item.title}|${item.artist}|${item.durationMs}';
    final wasPlaying = _lastPlaying;
    final isPlaying = st.isPlaying;
    final prevKey = _songKey;
    _lastPlaying = isPlaying;
    _songKey = key;

    if (isPlaying && !wasPlaying) {
      if (_transferActive) {
        _pushSnapshot();
      } else {
        _onPlaybackStart();
      }
      return;
    }
    if (!isPlaying && wasPlaying && _transferActive) {
      _pushState();
      if (key != prevKey && item != null) {
        _pushNowPlayingBlock(st, item);
      }
      _transferActive = false;
      _sessionDenied = false;
      return;
    }
    if (!_transferActive) return;

    if (key != prevKey) {
      if (item != null) _pushNowPlayingBlock(st, item);
      return;
    }
    final mode = linkPlayModeFromInt(st.playMode);
    if (isPlaying != wasPlaying ||
        mode != _lastMode ||
        _likedOf(item) != _lastLiked) {
      _lastMode = mode;
      _lastLiked = _likedOf(item);
      _pushState();
    }
    if (isPlaying) {
      final now = DateTime.now();
      if (now.difference(_lastPosPush) >= const Duration(milliseconds: 900)) {
        _lastPosPush = now;
        _send(LinkMessage.position(pos: st.position, duration: st.duration));
      }
    }
  }

  void _pushNowPlayingBlock(PlaybackState st, QueueItem item) {
    _send(LinkMessage.nowPlaying(
      id: item.path,
      title: item.title,
      artist: item.artist,
      album: item.album,
      cover: _coverOf(item),
      duration: st.duration,
      daily: item.fromDailyRecommend,
    ));
    _maybePushCoverData(item);
    _send(LinkMessage.state(
      isPlaying: st.isPlaying,
      playMode: _lastMode,
      liked: _lastLiked,
      volume: _volumeOf(),
    ));
    _lastPosPush = DateTime.now();
    _send(LinkMessage.position(pos: st.position, duration: st.duration));
    _maybePushLyric();
    _maybePrecacheNext();
  }

  void _onPlaybackStart() {
    final s = _container.read(settingsProvider).valueOrNull;
    final mode = s?.watchLinkTransferMode ?? 'ask';
    if (mode == 'remember') {
      if (s?.watchLinkAutoTransfer == true) {
        _transferActive = true;
        _pushSnapshot();
      }
      return;
    }
    switch (_dayGrantOf(s)) {
      case true:
        _transferActive = true;
        _pushSnapshot();
      case false:
        break;
      case null:
        if (_needsAsk(s)) _askTransfer();
    }
  }

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  bool? _dayGrantOf(AppSettings? s) {
    if (s == null || s.watchLinkAskDate != _today()) return null;
    return s.watchLinkAskGranted;
  }

  bool _needsAsk(AppSettings? s) =>
      !_transferActive && !_sessionDenied && _dayGrantOf(s) == null;

  Future<void> _playGate() async {
    if (!_connected && !_cloudWatchOnline) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if ((s?.watchLinkTransferMode ?? 'ask') != 'ask') return;
    if (!_needsAsk(s)) return;
    await _askTransfer();
  }

  Future<void> _askTransfer() async {
    if (_askInFlight != null) return _askInFlight;
    final context = appNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final task = _doAskTransfer();
    _askInFlight = task;
    try {
      await task;
    } finally {
      _askInFlight = null;
    }
  }

  Future<void> _doAskTransfer() async {
    final context = appNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final result = await showPredictiveDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _TransferConfirmDialog(
        watchName: _connectedName.isNotEmpty ? _connectedName : _cloudWatchName,
      ),
    );
    switch (result) {
      case 'device':
        await _container
            .read(settingsProvider.notifier)
            .setWatchLinkTransferRemembered(autoTransfer: true);
        _transferActive = true;
        _pushSnapshot();
      case 'once':
        _transferActive = true;
        _pushSnapshot();
      case 'never':
        await _container
            .read(settingsProvider.notifier)
            .setWatchLinkAskChoice(date: _today(), granted: false);
      default:
        _sessionDenied = true;
    }
  }

  void _pushState() {
    if ((!_connected && !_cloudWatchOnline) || !_transferActive) return;
    final st = _container.read(playerProvider);
    final item = st.current;
    _lastPlaying = st.isPlaying;
    _lastMode = linkPlayModeFromInt(st.playMode);
    _lastLiked = _likedOf(item);
    _send(LinkMessage.state(
      isPlaying: st.isPlaying,
      playMode: _lastMode,
      liked: _lastLiked,
      volume: _volumeOf(),
    ));
  }

  void _pushSnapshot({bool cloud = false}) {
    if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
    final st = _container.read(playerProvider);
    final item = st.current;
    _songKey = item == null
        ? null
        : '${item.path}|${item.title}|${item.artist}|${item.durationMs}';
    _lastPlaying = st.isPlaying;
    _lastMode = linkPlayModeFromInt(st.playMode);
    _lastLiked = _likedOf(item);
    _send(LinkMessage.nowPlaying(
      id: item?.path ?? '',
      title: item?.title ?? '',
      artist: item?.artist ?? '',
      album: item?.album ?? '',
      cover: _coverOf(item),
      duration: st.duration,
      daily: item?.fromDailyRecommend ?? false,
    ), cloud: cloud);
    _maybePushCoverData(item, cloud: cloud);
    _send(LinkMessage.state(
      isPlaying: st.isPlaying,
      playMode: _lastMode,
      liked: _lastLiked,
      volume: _volumeOf(),
    ), cloud: cloud);
    _lastPosPush = DateTime.now();
    _send(LinkMessage.position(pos: st.position, duration: st.duration),
        cloud: cloud);
    _lyricSentSongId = null;
    _maybePushLyric(cloud: cloud);
    _maybePrecacheNext(cloud: cloud);
  }

  bool _snapshotAllowed() {
    final s = _container.read(settingsProvider).valueOrNull;
    final mode = s?.watchLinkTransferMode ?? 'ask';
    if (mode == 'remember') return s?.watchLinkAutoTransfer == true;
    return _transferActive || _dayGrantOf(s) == true;
  }

  void _maybeAskOnHandshake() {
    final st = _container.read(playerProvider);
    if (!st.isPlaying) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if ((s?.watchLinkTransferMode ?? 'ask') != 'ask') return;
    if (!_needsAsk(s)) return;
    _askTransfer();
  }

  Future<void> _maybePushLyric({bool cloud = false}) async {
    if ((!_connected && !_cloudWatchOnline) || !_transferActive) return;
    final item = _container.read(playerProvider).current;
    final id = item?.path ?? '';
    if (item == null || id.isEmpty || id == _lyricSentSongId) return;
    _lyricSentSongId = id;
    try {
      final payload =
          await _container.read(lyricsRepositoryProvider).fetchPayloadJson(item);
      if (payload.isEmpty || payload == 'null') return;
      if ((!_connected && !_cloudWatchOnline) || !_transferActive) return;
      _send(LinkMessage.lyric(id: id, payload: payload), cloud: cloud);
    } catch (_) {}
  }

  // ---- 接下来五首批量预载（联动预缓存） ----

  void _maybePrecacheNext({bool cloud = false}) {
    if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
    final upcoming =
        _container.read(playerProvider.notifier).peekUpcomingItems(5);
    if (upcoming.isEmpty) return;
    final todo = upcoming
        .where((e) => !_precachedPaths.contains(e.path))
        .toList(growable: false);
    if (todo.isEmpty) return;
    if (_precachedPaths.length > 64) _precachedPaths.clear();
    Future.delayed(const Duration(seconds: 3), () async {
      for (final next in todo) {
        if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
        if (_precachedPaths.contains(next.path)) continue;
        _precachedPaths.add(next.path);
        if (_container.read(playerProvider).current?.path == next.path) {
          continue;
        }
        String? coverData;
        try {
          final bytes = await _nextCoverBytes(next);
          if (bytes != null && bytes.isNotEmpty) {
            coverData = await compute(_encodeLinkCoverBytes, bytes);
          }
        } catch (_) {}
        String? lyricPayload;
        try {
          final payload = await _container
              .read(lyricsRepositoryProvider)
              .fetchPayloadJson(next);
          if (payload.isNotEmpty && payload != 'null') lyricPayload = payload;
        } catch (_) {}
        if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
        if (coverData == null && lyricPayload == null) continue;
        _send(LinkMessage.precache(
          id: next.path,
          coverData: coverData,
          lyricPayload: lyricPayload,
        ), cloud: cloud, low: true);
        await Future.delayed(const Duration(milliseconds: 800));
      }
    });
  }

  Future<Uint8List?> _nextCoverBytes(QueueItem item) async {
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty && !url.startsWith('lx://')) {
      return CoverProxy.cached(url) ?? await CoverProxy.fetch(url);
    }
    final path = await _container
        .read(playerProvider.notifier)
        .resolveLinkCoverPath(item);
    if (path == null || path.isEmpty) return null;
    final f = File(path);
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  bool _likedOf(QueueItem? item) {
    if (item == null) return false;
    try {
      return _container.read(favoritesProvider).contains(item.path);
    } catch (_) {
      return false;
    }
  }

  double _volumeOf() => _container.read(volumeProvider);

  String? _coverOf(QueueItem? item) {
    if (item == null) return null;
    final path = item.coverPath;
    if (path != null &&
        path.isNotEmpty &&
        !path.startsWith('http') &&
        !path.startsWith('lx://')) {
      return path;
    }
    return null;
  }

  Future<void> _maybePushCoverData(QueueItem? item, {bool cloud = false}) async {
    if (item == null) return;
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) {
      if (url.startsWith('lx://')) return;
      final cached = _coverDataCache[url];
      if (cached != null) {
        _sendCoverData(item, cached, cloud: cloud);
        return;
      }
      try {
        final bytes = await _nextCoverBytes(item);
        if (bytes == null || bytes.isEmpty) return;
        final data = await compute(_encodeLinkCoverBytes, bytes);
        if (data == null || data.isEmpty) return;
        if (_coverDataCache.length > 16) _coverDataCache.clear();
        _coverDataCache[url] = data;
        _sendCoverData(item, data, cloud: cloud);
      } catch (_) {}
      return;
    }
    var path = item.coverPath;
    final live = path != null &&
        path.isNotEmpty &&
        !path.startsWith('http') &&
        !path.startsWith('lx://') &&
        File(path).existsSync();
    if (!live) {
      final resolved = await _container
          .read(playerProvider.notifier)
          .resolveLinkCoverPath(item);
      if (resolved == null) return;
      path = resolved;
      item = item.copyWith(coverPath: resolved);
    }
    final cached = _coverDataCache[path];
    if (cached != null) {
      _sendCoverData(item, cached, cloud: cloud);
      return;
    }
    final target = item;
    final coverPath = path;
    compute(_encodeLinkCoverData, coverPath).then((data) {
      if (data == null || data.isEmpty) return;
      if (_coverDataCache.length > 16) _coverDataCache.clear();
      _coverDataCache[coverPath] = data;
      _sendCoverData(target, data, cloud: cloud);
    }).catchError((_) {});
  }

  void _sendCoverData(QueueItem item, String data, {bool cloud = false}) {
    if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
    final st = _container.read(playerProvider);
    if (st.current?.path != item.path) return;
    _send(LinkMessage.nowPlaying(
      id: item.path,
      title: item.title,
      artist: item.artist,
      album: item.album,
      cover: _coverOf(item),
      coverData: data,
      duration: st.duration,
      daily: item.fromDailyRecommend,
    ), cloud: cloud);
  }

  // ---- 帧发送队列（背压） ----

  final List<(Uint8List, bool)> _txQueue = [];

  final List<(Uint8List, bool)> _txLowQueue = [];

  bool _txDraining = false;

  void _send(LinkMessage msg, {bool cloud = false, bool low = false}) {
    final useCloud = cloud || (!_connected && _cloudWatchOnline);
    try {
      final q = low ? _txLowQueue : _txQueue;
      for (final frame in encodeFrames(msg, nextSeq: _nextSeq)) {
        q.add((frame, useCloud));
      }
      _drainTx();
    } catch (_) {
    }
  }

  Future<void> _drainTx() async {
    if (_txDraining) return;
    _txDraining = true;
    try {
      while (true) {
        if (!_connected && !_cloudWatchOnline) {
          _txQueue.clear();
          _txLowQueue.clear();
          return;
        }
        final q = _txQueue.isNotEmpty ? _txQueue : _txLowQueue;
        if (q.isEmpty) return;
        final (frame, useCloud) = q.first;
        if (useCloud) {
          await _cloud.send(frame);
        } else {
          await _channel.send(frame);
        }
        q.removeAt(0);
      }
    } catch (_) {
      _txQueue.clear();
      _txLowQueue.clear();
    } finally {
      _txDraining = false;
    }
  }
}

final watchLinkControllerProvider = Provider<WatchLinkController>((ref) {
  final controller = WatchLinkController(ref.container);
  ref.onDispose(controller.dispose);
  return controller;
});

final watchLinkConnectedNameProvider = StateProvider<String>((ref) => '');

final watchLinkCloudOnlineProvider = StateProvider<bool>((ref) => false);

Future<String?> _encodeLinkCoverData(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    return await _encodeLinkCoverBytes(await f.readAsBytes());
  } catch (_) {
    return null;
  }
}

Future<String?> _encodeLinkCoverBytes(List<int> raw) async {
  try {
    final decoded = img.decodeImage(Uint8List.fromList(raw));
    if (decoded == null) return null;
    final resized = img.copyResize(
      decoded,
      width: decoded.width <= 512 ? decoded.width : 512,
    );
    final jpg = img.encodeJpg(resized, quality: 78);
    if (jpg.isEmpty) return null;
    return base64Encode(jpg);
  } catch (_) {
    return null;
  }
}

class _TransferConfirmDialog extends StatelessWidget {
  const _TransferConfirmDialog({required this.watchName});

  final String watchName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    return ModernDialogCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.watch_outlined, color: accent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    tr('传递给腕上设备'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              tr('是否将当前播放传递给 {name}？', {
                'name': watchName.isEmpty ? tr('腕上设备') : watchName,
              }),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop('device'),
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: Text(tr('允许该设备')),
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: scheme.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop('once'),
                icon: const Icon(Icons.schedule, size: 18),
                label: Text(tr('允许本次')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: accent,
                  side: BorderSide(color: accent.withValues(alpha: 0.45)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop('never'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(tr('不允许')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IncomingBackupDialog extends StatefulWidget {
  const _IncomingBackupDialog({
    required this.fileName,
    required this.content,
  });

  final String fileName;
  final String content;

  @override
  State<_IncomingBackupDialog> createState() => _IncomingBackupDialogState();
}

class _IncomingBackupDialogState extends State<_IncomingBackupDialog> {
  bool _saving = false;

  bool _sharing = false;

  String? _error;

  bool get _busy => _saving || _sharing;

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      String? saved;
      if (SafChannel.isSupported) {
        // 安卓：可自选保存位置
        final treeUri = await SafChannel.chooseFolderTree(persist: false);
        if (treeUri == null) return; // 用户在系统选择器中放弃：保持弹窗
        final docId = await SafChannel.createTreeFile(
            treeUri, widget.fileName, widget.content);
        saved = docId.isEmpty ? null : widget.fileName;
      } else {
        // 鸿蒙 / iOS：直接保存到私有备份目录
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/backups');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final path = '${dir.path}${Platform.pathSeparator}${widget.fileName}';
        await File(path).writeAsString(widget.content, flush: true);
        saved = widget.fileName;
      }
      if (saved != null) {
        if (mounted) Navigator.of(context).pop('saved');
        return;
      }
      setState(() => _error = tr('无法写入所选文件夹'));
    } catch (e) {
      setState(() => _error = tr('保存失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 一键分享：写临时文件后直接调系统分享面板，与日志弹窗同一链路。
  Future<void> _share() async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}${widget.fileName}');
      await file.writeAsString(widget.content, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: tr('弦予音乐腕上端备份')),
      );
      if (mounted) Navigator.of(context).pop('saved');
    } catch (e) {
      setState(() => _error = tr('分享失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _cancel() => Navigator.of(context).pop('cancelled');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    final sizeKb = (utf8.encode(widget.content).length / 1024).truncate();
    return ModernDialogCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.settings_backup_restore_rounded,
                      color: accent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    tr('收到腕上备份'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              tr('腕上设备推送了一份应用备份，可保存到手机或一键分享。'),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.insert_drive_file_outlined,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (sizeKb > 0) ...[
              const SizedBox(height: 4),
              Text(
                tr('约 {kb} KB', {'kb': sizeKb}),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 12.5, color: scheme.error),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: _saving
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: scheme.onPrimary))
                        : const Icon(Icons.save_alt, size: 18),
                    label: Text(_saving ? tr('保存中…') : tr('保存文件')),
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: scheme.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _share,
                    icon: _sharing
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.share_outlined, size: 18),
                    label: Text(_sharing ? tr('分享中…') : tr('一键分享')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: accent,
                      side: BorderSide(color: accent.withValues(alpha: 0.5)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _busy ? null : _cancel,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(tr('取消')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 收到腕上运行日志的弹窗：主按钮直接调系统分享面板分发日志文件，
/// 与设置页「导出日志文件」的分享链路一致。
class _IncomingLogDialog extends StatefulWidget {
  const _IncomingLogDialog({
    required this.fileName,
    required this.content,
  });

  final String fileName;

  final String content;

  @override
  State<_IncomingLogDialog> createState() => _IncomingLogDialogState();
}

class _IncomingLogDialogState extends State<_IncomingLogDialog> {
  bool _sharing = false;

  String? _error;

  Future<void> _share() async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}${widget.fileName}');
      await file.writeAsString(widget.content, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: tr('弦予音乐腕上端日志')),
      );
      if (mounted) Navigator.of(context).pop('saved');
    } catch (e) {
      setState(() => _error = tr('分享失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _cancel() => Navigator.of(context).pop('cancelled');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    final sizeKb = (utf8.encode(widget.content).length / 1024).truncate();
    return ModernDialogCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.article_outlined, color: accent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    tr('收到腕上日志'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              tr('腕上设备推送了一份运行日志，可直接通过系统分享面板发给开发者或自行留存。'),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.insert_drive_file_outlined,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (sizeKb > 0) ...[
              const SizedBox(height: 4),
              Text(
                tr('约 {kb} KB', {'kb': sizeKb}),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 12.5, color: scheme.error),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _sharing ? null : _share,
                icon: _sharing
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: scheme.onPrimary))
                    : const Icon(Icons.share_outlined, size: 18),
                label: Text(_sharing ? tr('分享中…') : tr('分享日志')),
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: scheme.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _sharing ? null : _cancel,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(tr('取消')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
