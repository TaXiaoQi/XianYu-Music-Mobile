import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform_caps.dart';
import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../i18n/i18n.dart';
import '../navigation/routes.dart';
import '../player/player_provider.dart';
import '../widgets/modern_dialog.dart';
import '../widgets/predictive_dialog_route.dart';
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

  /// 当前播放会话是否已获准推送（起播经确认/记住选择后置 true，暂停或停止后清空）。
  bool _transferActive = false;

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
    _container.read(watchLinkConnectedNameProvider.notifier).state = evt.name;
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
  ///
  /// 传递确认门控（对齐高德「投到腕上」）：每次播放会话起播先评估
  /// 是否获准推送——`ask` 模式弹窗询问，`remember` 模式按记住的选择
  /// 直接放行或拒绝；未获准的会话不推任何帧（含切歌/进度/状态）。
  void _onPlayback(PlaybackState st) {
    if (!_connected) return;
    final item = st.current;
    final key = item == null
        ? null
        : '${item.path}|${item.title}|${item.artist}|${item.durationMs}';
    final wasPlaying = _lastPlaying;
    final isPlaying = st.isPlaying;
    _lastPlaying = isPlaying;
    _songKey = key;

    if (isPlaying && !wasPlaying) {
      // 起播：已获准的会话恢复直接全量同步；否则走确认评估。
      if (_transferActive) {
        _pushSnapshot();
      } else {
        _onPlaybackStart();
      }
      return;
    }
    if (!isPlaying && wasPlaying && _transferActive) {
      // 暂停/停止：先同步状态给手表，再关闭本次会话授权（下次起播重新确认）。
      _pushState();
      _transferActive = false;
      return;
    }
    // 未获准的会话不推任何帧（内部状态已同步，防重复判定）。
    if (!_transferActive) return;

    if (key != _songKey) {
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

  /// 播放会话起播：按设置评估是否推送（ask 弹窗 / remember 直接放行或拒绝）。
  void _onPlaybackStart() {
    final s = _container.read(settingsProvider).valueOrNull;
    final mode = s?.watchLinkTransferMode ?? 'ask';
    if (mode == 'remember') {
      if (s?.watchLinkAutoTransfer == true) {
        _transferActive = true;
        _pushSnapshot();
      }
      // 记住「不传递」：本次会话不推，也不弹窗。
      return;
    }
    _askTransfer();
  }

  /// ask 模式弹窗：确定才推送给腕上设备；勾选「默认传递」后落库为
  /// remember+自动传递（下次起播直接推，不再弹窗）。
  Future<void> _askTransfer() async {
    final context = appNavigatorKey.currentContext;
    // 无导航宿主（如首帧前）：不弹窗也不传递，保守降级。
    if (context == null || !context.mounted) return;
    final result = await showPredictiveDialog<(bool, bool)>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _TransferConfirmDialog(watchName: _connectedName),
    );
    if (result == null) return; // 点外部/系统返回关闭：本次不传、不记。
    final (send, remember) = result;
    if (remember) {
      // 勾选「默认传递」：记住本次选择（含取消→记住不传递）。
      await _container
          .read(settingsProvider.notifier)
          .setWatchLinkTransferRemembered(autoTransfer: send);
    }
    if (send) {
      _transferActive = true;
      _pushSnapshot();
    }
  }

  /// 独立 state 推送（收藏变化等触发）。未获准的播放会话不推。
  void _pushState() {
    if (!_connected || !_transferActive) return;
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
  /// 记住「不传递」时整个链路不推任何帧（含握手快照），保持语义一致。
  void _pushSnapshot() {
    if (!_connected) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if (s?.watchLinkTransferMode == 'remember' &&
        s?.watchLinkAutoTransfer != true) {
      return;
    }
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

/// 当前已连接的手表名（设置页副标题展示，连接变化实时刷新）。
final watchLinkConnectedNameProvider = StateProvider<String>((ref) => '');

/// 传递确认弹窗：问「要不要传递给腕上设备」，带「默认传递（下次不再询问）」勾选。
/// 返回 `(是否传递, 是否记住选择)`。
class _TransferConfirmDialog extends StatefulWidget {
  const _TransferConfirmDialog({required this.watchName});

  final String watchName;

  @override
  State<_TransferConfirmDialog> createState() => _TransferConfirmDialogState();
}

class _TransferConfirmDialogState extends State<_TransferConfirmDialog> {
  bool _remember = false;

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
                'name': widget.watchName.isEmpty ? tr('腕上设备') : widget.watchName,
              }),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              visualDensity: VisualDensity.compact,
              value: _remember,
              onChanged: (v) => setState(() => _remember = v ?? false),
              title: Text(
                tr('默认传递（下次不再询问）'),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop((false, _remember)),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(tr('取消')),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop((true, _remember)),
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: scheme.onPrimary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(tr('传递')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
