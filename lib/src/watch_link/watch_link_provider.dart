import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform_caps.dart';
import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../player/player_provider.dart';
import 'protocol.dart';
import 'watch_link_channel.dart';

/// 手表联动编排层（手机端）。
///
/// 职责：
/// - 按设置 `watchLinkageEnabled` 启停 RFCOMM 服务端（权限缺失时先申请）；
/// - 播放状态变化 → 推送 state / now_playing / position（进度 1s 节流）；
/// - 手表 cmd → 转调 PlayerNotifier（播放暂停/上下首/喜欢/切模式/seek）；
/// - 握手：收到手表 hello 后回 hello 并立即推 now_playing+state 快照；
///   收到 ping 回 pong（保活由手表侧发起，手机只被动应答）。
///
/// 与腕上端 `XianYu-Music-Watch/lib/src/link/link_provider.dart` 为同一协议的
/// 对端实现，消息方向约定见 protocol.dart 头注释。
class WatchLinkController {
  WatchLinkController(this._container);

  final ProviderContainer _container;
  final WatchLinkChannel _channel = WatchLinkChannel();
  FrameDecoder _decoder = FrameDecoder();
  final int Function() _nextSeq = makeSeqGenerator();

  final List<StreamSubscription<dynamic>> _subs = [];
  final List<ProviderSubscription<dynamic>> _providerSubs = [];

  /// 服务端是否已 start（Kotlin 侧幂等，这里只做去重与状态记忆）。
  bool _running = false;
  bool _connected = false;
  String _connectedName = '';

  /// 当前已连接的手表名（调试/设置页展示用）。
  String get connectedName => _connectedName;

  /// 当前已推送歌曲 key（切歌检测）。
  String? _songKey;
  bool _lastPlaying = false;
  LinkPlayMode _lastMode = LinkPlayMode.order;
  bool _lastLiked = false;
  DateTime _lastPosPush = DateTime.fromMillisecondsSinceEpoch(0);

  /// 挂载全部监听（main 启动时调用一次）。
  void init() {
    if (!PlatformCaps.isAndroid) return;
    _channel.bind();
    _subs.add(_channel.onRaw.listen(_onRaw));
    _subs.add(_channel.onConnection.listen(_onConnection));
    _subs.add(_channel.onPermission.listen(_onPermission));

    // 设置开关驱动启停；首次读取按当前值应用。
    _providerSubs.add(_container.listen<AsyncValue<AppSettings>>(
      settingsProvider,
      (prev, next) {
        final s = next.valueOrNull;
        if (s != null) _applyEnabled(s.watchLinkageEnabled);
      },
      fireImmediately: true,
    ));

    // 播放状态变化 → 增量推送。
    _providerSubs.add(_container.listen<PlaybackState>(
      playerProvider,
      (_, st) => _onPlayback(st),
    ));

    // 收藏变化 → 喜欢状态推送（liked 不经过 playerProvider）。
    _providerSubs.add(_container.listen<FavoritesState>(
      favoritesProvider,
      (_, _) => _pushState(),
    ));

    // 设置变化（含表冠调回的音量）→ state 推送（帧很小，低频可接受）。
    _providerSubs.add(_container.listen<AsyncValue<AppSettings>>(
      settingsProvider,
      (prev, next) {
        if (next.hasValue && _connected) _pushState();
      },
    ));
  }

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    for (final s in _providerSubs) {
      s.close();
    }
    _channel.stop();
  }

  // ---- 开关与权限 ----

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
      // 结果经 onPermission 回调继续。
      await _channel.requestPermission();
    }
  }

  void _onPermission(bool granted) {
    if (!granted || _running) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if (s?.watchLinkageEnabled != true) return;
    _channel.start().then((_) => _running = true);
  }

  // ---- 连接事件 ----

  void _onConnection(WatchLinkConnection evt) {
    _connected = evt.connected;
    _connectedName = evt.name;
    _songKey = null; // 重连后由 hello 重新推快照。
    // 连接切换：丢弃旧连接残留的分片会话与半包缓冲。
    _decoder = FrameDecoder();
  }

  // ---- 字节入口与消息分发 ----

  void _onRaw(Uint8List bytes) {
    for (final msg in _decoder.feed(bytes)) {
      _onMessage(msg);
    }
  }

  void _onMessage(LinkMessage msg) {
    switch (msg.type) {
      case LinkMsgType.hello:
        // 互换握手：回 hello + 立即推快照。
        _send(LinkMessage.hello(
          ver: kLinkProtocolVersion,
          role: 'phone',
          name: '弦予音乐',
        ));
        _pushSnapshot();
      case LinkMsgType.ping:
        _send(LinkMessage(LinkMsgType.pong, {
          't': msg.payload['t'],
        }));
      case LinkMsgType.bye:
        // 手表主动告别，等 Kotlin 上报断连。
        break;
      case LinkMsgType.cmd:
        _onCmd(msg);
      default:
        break;
    }
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
      case LinkCmdAction.mode:
        await notifier.cyclePlayMode();
      case LinkCmdAction.seek:
        final arg = msg.payload['arg'];
        final pos = arg is Map ? (arg['pos'] as num?)?.toDouble() : null;
        if (pos != null) await notifier.seek(pos);
      case LinkCmdAction.volume:
        // 表冠调音量：arg {v: 0..1}，写设置即联动播放引擎（volumeProvider 链）。
        final arg = msg.payload['arg'];
        final v = arg is Map ? (arg['v'] as num?)?.toDouble() : null;
        if (v != null) {
          await _container
              .read(settingsProvider.notifier)
              .setVolume(v.clamp(0.0, 1.0));
        }
      default:
        break;
    }
  }

  // ---- 状态推送 ----

  /// 增量推送：切歌 → now_playing + state；其余状态变化 → state；进度 1s 节流。
  void _onPlayback(PlaybackState st) {
    if (!_connected) return;
    final item = st.current;
    final key = item == null
        ? null
        : '${item.path}|${item.title}|${item.artist}|${item.durationMs}';
    if (key != _songKey) {
      _songKey = key;
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
      ));
      _send(LinkMessage.state(
        isPlaying: st.isPlaying,
        playMode: _lastMode,
        liked: _lastLiked,
        volume: _volumeOf(),
      ));
      _lastPosPush = DateTime.now();
      _send(LinkMessage.position(pos: st.position, duration: st.duration));
      return;
    }
    final mode = linkPlayModeFromInt(st.playMode);
    if (st.isPlaying != _lastPlaying ||
        mode != _lastMode ||
        _likedOf(item) != _lastLiked) {
      _lastPlaying = st.isPlaying;
      _lastMode = mode;
      _lastLiked = _likedOf(item);
      _pushState();
    }
    if (st.isPlaying) {
      final now = DateTime.now();
      if (now.difference(_lastPosPush) >= const Duration(milliseconds: 900)) {
        _lastPosPush = now;
        _send(LinkMessage.position(pos: st.position, duration: st.duration));
      }
    }
  }

  /// 独立 state 推送（收藏变化等触发）。
  void _pushState() {
    if (!_connected) return;
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

  /// 全量快照（握手后立即同步当前播放现场）。
  void _pushSnapshot() {
    if (!_connected) return;
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
    ));
    _send(LinkMessage.state(
      isPlaying: st.isPlaying,
      playMode: _lastMode,
      liked: _lastLiked,
      volume: _volumeOf(),
    ));
    _lastPosPush = DateTime.now();
    _send(LinkMessage.position(pos: st.position, duration: st.duration));
  }

  bool _likedOf(QueueItem? item) {
    if (item == null) return false;
    try {
      return _container.read(favoritesProvider).contains(item.path);
    } catch (_) {
      return false;
    }
  }

  /// 当前音量（0..1，与手机播放引擎同源）。
  double _volumeOf() => _container.read(volumeProvider);

  /// 封面：在线歌曲给 http(s) URL，本地歌曲给文件路径（手表端按前缀区分渲染）。
  String? _coverOf(QueueItem? item) {
    if (item == null) return null;
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) return url;
    final path = item.coverPath;
    if (path != null &&
        path.isNotEmpty &&
        !path.startsWith('http') &&
        !path.startsWith('lx://')) {
      return path;
    }
    return null;
  }

  void _send(LinkMessage msg) {
    try {
      for (final frame in encodeFrames(msg, nextSeq: _nextSeq)) {
        _channel.send(frame);
      }
    } catch (_) {
      // 发送失败静默：断连由读线程统一上报。
    }
  }
}

/// 手表联动控制器 provider：首次读取时创建（监听由 main 显式 init）。
final watchLinkControllerProvider = Provider<WatchLinkController>((ref) {
  final controller = WatchLinkController(ref.container);
  ref.onDispose(controller.dispose);
  return controller;
});
