import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../core/platform_caps.dart';
import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../i18n/i18n.dart';
import '../lyrics/lyrics_repository.dart';
import '../navigation/routes.dart';
import '../online/cover_proxy.dart';
import '../player/player_provider.dart';
import '../widgets/modern_dialog.dart';
import '../widgets/predictive_dialog_route.dart';
import 'cloud_channel.dart';
import 'protocol.dart';
import 'watch_link_channel.dart';

/// 云端中继默认地址（服务端 `/watch-relay`，与手表端默认一致）。
const String kWatchCloudRelayUrl = 'wss://api.xianyumusic.cn/watch-relay';

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
  final WatchCloudChannel _cloud = WatchCloudChannel();
  FrameDecoder _decoder = FrameDecoder();

  /// 云通道独立解码器（与蓝牙字节流隔离，防半包串流）。
  final FrameDecoder _cloudDecoder = FrameDecoder();
  final int Function() _nextSeq = makeSeqGenerator();

  final List<StreamSubscription<dynamic>> _subs = [];
  final List<ProviderSubscription<dynamic>> _providerSubs = [];

  /// 服务端是否已 start（Kotlin 侧幂等，这里只做去重与状态记忆）。
  bool _running = false;
  bool _connected = false;
  String _connectedName = '';

  // ---- 云端兜底通道状态 ----

  /// 云通道应保持运行（联动开 + 云兜底开）。
  bool _cloudRunning = false;

  /// 手表当前是否经云端在线。
  bool _cloudWatchOnline = false;

  /// 手表经 hello 上报的名字（控制命令来源展示用）。
  String _cloudWatchName = '';

  Timer? _cloudReconnect;
  Duration _cloudBackoff = const Duration(seconds: 5);

  /// 当前播放会话是否已获准推送（起播经确认/记住选择后置 true，暂停或停止后清空）。
  bool _transferActive = false;

  /// 当前播放会话是否已拒绝（弹窗被关闭未回答时置 true：本会话不再询问、
  /// 不推送；暂停或停止后清空，与 [_transferActive] 同生命周期）。
  bool _sessionDenied = false;

  /// 进行中的授权弹窗（单飞：门控/握手同时触发复用同一次弹窗）。
  Future<void>? _askInFlight;

  /// 当前已连接的手表名（调试/设置页展示用）。
  String get connectedName => _connectedName;

  /// 当前已推送歌曲 key（切歌检测）。
  String? _songKey;

  /// 联动封面 base64 缓存（key = 本地封面文件路径，上限 16 条防膨胀）。
  final Map<String, String> _coverDataCache = {};

  /// 已推送歌词的歌曲 id（同曲只发一次；快照推送时置空强制重发）。
  String? _lyricSentSongId;

  /// 已完成下一首预载推送的歌曲路径（同一首只推一次；重连后置空重推，
  /// 手表可能刚启动丢了落盘缓存）。
  String? _precachedNextPath;
  bool _lastPlaying = false;
  LinkPlayMode _lastMode = LinkPlayMode.order;
  bool _lastLiked = false;
  DateTime _lastPosPush = DateTime.fromMillisecondsSinceEpoch(0);

  /// 挂载全部监听（main 启动时调用一次）。
  void init() {
    if (!PlatformCaps.isAndroid) return;
    _channel.bind();
    // 起播门控：有腕上设备且 ask 模式当天未决时，先弹授权确认再放行起播。
    beforePlayGate = _playGate;
    _subs.add(_channel.onRaw.listen(_onRaw));
    _subs.add(_channel.onConnection.listen(_onConnection));
    _subs.add(_channel.onPermission.listen(_onPermission));
    _subs.add(_cloud.onRaw.listen(_onCloudRaw));
    _subs.add(_cloud.onEvent.listen(_onCloudEvent));

    // 设置开关驱动启停；首次读取按当前值应用。
    _providerSubs.add(_container.listen<AsyncValue<AppSettings>>(
      settingsProvider,
      (prev, next) {
        final s = next.valueOrNull;
        if (s != null) _applyLinkSettings(s);
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

  /// 按设置应用联动启停（蓝牙服务 + 云端兜底通道）。
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

  // ---- 云端兜底通道（P4） ----

  /// 按设置启停云通道（幂等）：断线 5s→60s 指数退避重连。
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

  /// 读取云端凭据，空则懒生成 32 字节随机 hex（仅生成一次并落库）。
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
          // 断线退避重连（ready 时复位）。
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
    _songKey = null; // 重连后由 hello 重新推快照。
    _precachedNextPath = null; // 重连后重推下一首预载（手表可能刚启动）。
    // 连接切换：丢弃旧连接残留的分片会话与半包缓冲。
    _decoder = FrameDecoder();
  }

  // ---- 设备管理（设置页） ----

  /// 已配对蓝牙设备列表（手机端主动连接手表的选择列表）。
  Future<List<WatchBondedDevice>> loadPairedDevices() =>
      _channel.pairedDevices();

  /// 手机端主动连接手表（反向配对）：连入手表侧服务端，手表端弹
  /// 「允许/拒绝」确认。返回 false 表示缺蓝牙权限（已代为发起授权）。
  Future<bool> connectToWatch(String address) async {
    if (_connected) return true;
    if (!await _channel.hasPermission()) {
      await _channel.requestPermission();
      return false;
    }
    _channel.connect(address);
    return true;
  }

  /// 手动断开当前手表：蓝牙踢下线（服务端继续监听，手表可重连）+ 云端通道
  /// 暂离（3s 后自动重连中继）。授权与绑定状态不变。
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
          // 云端握手：手表经中继上线，回 hello + 快照（同通道回帧）。
          _cloudWatchName = (msg.payload['name'] as String?) ?? '';
          _send(LinkMessage.hello(
            ver: kLinkProtocolVersion,
            role: 'phone',
            name: '弦予音乐',
          ), cloud: true);
          _pushSnapshot(cloud: true);
          _maybeAskOnHandshake();
        } else {
          // 蓝牙握手：回 hello + 立即推快照，并下发云端兜底绑定凭据。
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
        // 手表主动告别，等 Kotlin 上报断连。
        break;
      case LinkMsgType.cmd:
        _onCmd(msg);
      default:
        break;
    }
  }

  /// 蓝牙握手后向手表下发云端兜底凭据（联动开 + 云兜底开 + 凭据已生成）。
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
          // 回推 state：手表 UI 音量与手机实际音量保持同源。
          _pushState();
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
      _sessionDenied = false;
      return;
    }
    // 未获准的会话不推任何帧（内部状态已同步，防重复判定）。
    if (!_transferActive) return;

    // 切歌检测：与上一帧的 key 比较（prevKey 先于赋值捕获，自动接续
    // isPlaying 不翻转时也能推 now_playing）。
    if (key != prevKey) {
      _send(LinkMessage.nowPlaying(
        id: item?.path ?? '',
        title: item?.title ?? '',
        artist: item?.artist ?? '',
        album: item?.album ?? '',
        cover: _coverOf(item),
        duration: st.duration,
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

  /// 播放会话起播：按设置评估是否推送。
  ///
  /// `remember` 模式按记住的选择直接放行或拒绝；`ask` 模式按天隔离——
  /// 当天已有决定（弹窗选过）则静默应用。起播前的弹窗询问由 [_playGate]
  /// 在 play() 内完成（先弹窗后起播），这里只兜底漏网场景。
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
    // ask 模式：当天决定直接应用；会话已拒绝（弹窗被关）不再问；其余兜底弹窗。
    switch (_dayGrantOf(s)) {
      case true:
        _transferActive = true;
        _pushSnapshot();
      case false:
        break; // 今天已拒绝：不推也不弹。
      case null:
        if (_needsAsk(s)) _askTransfer();
    }
  }

  /// 本地日期 `yyyy-MM-dd`（按天隔离的 key，跨天重置询问）。
  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  /// ask 模式今天的决定：null=今天还没问过（可弹窗）；true/false=今天已授准/拒绝。
  bool? _dayGrantOf(AppSettings? s) {
    if (s == null || s.watchLinkAskDate != _today()) return null;
    return s.watchLinkAskGranted;
  }

  /// 是否需要弹窗询问：会话未决（未授准也未拒绝）且今天还没问过。
  bool _needsAsk(AppSettings? s) =>
      !_transferActive && !_sessionDenied && _dayGrantOf(s) == null;

  /// 起播门控（player_provider 的 beforePlayGate 钩子）：任意 play() 真正出声
  /// 前调用。腕上设备在线且 ask 模式当天未决时，先弹授权确认再放行——
  /// 保证「优先弹窗、后进播放」；其余情况直通。无论作何选择（含关闭），
  /// 播放都放行，弹窗只决定是否向腕上推送。
  Future<void> _playGate() async {
    if (!_connected && !_cloudWatchOnline) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if ((s?.watchLinkTransferMode ?? 'ask') != 'ask') return;
    if (!_needsAsk(s)) return;
    await _askTransfer();
  }

  /// 授权弹窗（三选一）：
  /// - 允许该设备：永久记住（升级为 remember+自动传递，不再询问）；
  /// - 允许本次：仅当前播放会话推送，会话结束（暂停/停止）后下次再问；
  /// - 不允许：按天隔离落库，当天不再询问、不推送，跨天重置。
  /// 点外部/返回键关闭视为未回答：本会话不再问也不推，不落库。
  /// 单飞：门控与握手同时触发时复用同一次弹窗，防叠加。
  Future<void> _askTransfer() async {
    if (_askInFlight != null) return _askInFlight;
    final context = appNavigatorKey.currentContext;
    // 无导航宿主（如首帧前）：不弹窗也不传递，保守降级。
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
        // 允许该设备：永久记住（含后续跨天），本会话立即生效。
        await _container
            .read(settingsProvider.notifier)
            .setWatchLinkTransferRemembered(autoTransfer: true);
        _transferActive = true;
        _pushSnapshot();
      case 'once':
        // 允许本次：仅当前播放会话，不落库。
        _transferActive = true;
        _pushSnapshot();
      case 'never':
        // 不允许：按天隔离落库，当天静默不推不问。
        await _container
            .read(settingsProvider.notifier)
            .setWatchLinkAskChoice(date: _today(), granted: false);
      default:
        // 关闭未回答：本会话不再询问、不推送。
        _sessionDenied = true;
    }
  }

  /// 独立 state 推送（收藏变化等触发）。未获准的播放会话不推。
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

  /// 全量快照（握手后立即同步当前播放现场）。
  ///
  /// 授权门（堵住「弹窗未决手表先收到数据」的泄漏）：任何路径推送快照前
  /// 必须通过 [_snapshotAllowed]——remember 记住传递、ask 当天已授准、或
  /// 本次会话已获准（[_transferActive]）三者其一；其余情况整个链路不推
  /// 任何帧（含握手快照）。
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
    // 握手快照强制重发歌词（手表可能在切歌瞬间掉线错过上一条）。
    _lyricSentSongId = null;
    _maybePushLyric(cloud: cloud);
    _maybePrecacheNext(cloud: cloud);
  }

  /// 快照授权门：remember 记住传递 / ask 当天已授准 / 会话已获准。
  bool _snapshotAllowed() {
    final s = _container.read(settingsProvider).valueOrNull;
    final mode = s?.watchLinkTransferMode ?? 'ask';
    if (mode == 'remember') return s?.watchLinkAutoTransfer == true;
    return _transferActive || _dayGrantOf(s) == true;
  }

  /// 握手后补询问：连接瞬间已在播放（起播门控早已错过）且当天未询问过时
  /// 立即弹确认，否则手表要静默到下一次起播才被询问。快照推送本身已被
  /// [_snapshotAllowed] 拦住，这里只负责把弹窗时机提前到连接时刻。
  void _maybeAskOnHandshake() {
    final st = _container.read(playerProvider);
    if (!st.isPlaying) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if ((s?.watchLinkTransferMode ?? 'ask') != 'ask') return;
    if (!_needsAsk(s)) return;
    _askTransfer();
  }

  /// 异步推送当前歌歌词（结构化 payload JSON，帧层自动分片）。
  ///
  /// 同曲只发一次（快照时由调用方置空强制重发）；歌词获取失败静默跳过，
  /// 手表端显示「暂无歌词」。发送前复检链路与会话授权，防止异步窗口内状态失效。
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

  // ---- 下一首预载（联动预缓存） ----

  /// 下一首预载推送：复用在线预缓存管线，把队列下一首的封面字节与歌词
  /// payload 提前推给手表（precache 帧，手表静默落盘/缓存不改 UI）。真正
  /// 切歌的 now_playing 到达时手表直接命中本地缓存——在线封面免手表二次
  /// 拉 URL、歌词免等待，联动切换不再有几秒丢封面/状态。
  ///
  /// 定位与播放器 `_precacheNextCover` 同款：顺序/列表循环取 index+1；
  /// 随机模式仅在已压入预知栈时可预知（栈顶）；单曲循环无下一首。
  /// 同一首只预载一次；推送前/发送前复检链路与会话授权（未获准零推送）。
  void _maybePrecacheNext({bool cloud = false}) {
    if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
    final next = _container.read(playerProvider.notifier).peekNextItem();
    if (next == null || next.path == _precachedNextPath) return;
    _precachedNextPath = next.path;
    // 延迟 3s：让当前歌的 now_playing/封面/歌词帧先走完链路，避免挤兑带宽。
    Future.delayed(const Duration(seconds: 3), () async {
      if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
      if (_container.read(playerProvider).current?.path == next.path) {
        return; // 期间已切到这首歌，切歌推送自带全量数据。
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
        final payload =
            await _container.read(lyricsRepositoryProvider).fetchPayloadJson(next);
        if (payload.isNotEmpty && payload != 'null') lyricPayload = payload;
      } catch (_) {}
      if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
      if (coverData == null && lyricPayload == null) return;
      _send(LinkMessage.precache(
        id: next.path,
        coverData: coverData,
        lyricPayload: lyricPayload,
      ), cloud: cloud);
    });
  }

  /// 下一首封面字节：在线歌走代理缓存（在线预缓存已播种，未命中兜底拉
  /// 一次），本地歌走联动封面解析链（与通知栏封面同源，含内嵌封面兜底）。
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

  /// 异步补发本地歌封面（512px JPEG base64，帧层自动分片；在线歌走 URL 不发）。
  ///
  /// 封面来源优先 coverPath；本地歌常见无封面字段（内嵌封面走缩略图链路），
  /// 这里复用播放器的缩略图解析兜底，否则切歌时手表会一直挂着上一首的封面。
  /// 结果按最终封面路径缓存。补发的 now_playing 只多带 coverData 字段，
  /// 手表按歌曲 id 守卫落盘，标题先到封面随后跟上。
  Future<void> _maybePushCoverData(QueueItem? item, {bool cloud = false}) async {
    if (item == null) return;
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) return;
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
      if (resolved == null) return; // 无封面：手表保持默认底色
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

  /// 发送带 coverData 的 now_playing（复检链路/授权/切歌）。
  void _sendCoverData(QueueItem item, String data, {bool cloud = false}) {
    if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
    final st = _container.read(playerProvider);
    if (st.current?.path != item.path) return; // 编码期间已切歌
    _send(LinkMessage.nowPlaying(
      id: item.path,
      title: item.title,
      artist: item.artist,
      album: item.album,
      cover: _coverOf(item),
      coverData: data,
      duration: st.duration,
    ), cloud: cloud);
  }

  /// 发送消息：显式 [cloud]=true 走云端；否则蓝牙优先、蓝牙未连且手表云在线时走云。
  void _send(LinkMessage msg, {bool cloud = false}) {
    final useCloud = cloud || (!_connected && _cloudWatchOnline);
    try {
      for (final frame in encodeFrames(msg, nextSeq: _nextSeq)) {
        if (useCloud) {
          _cloud.send(frame);
        } else {
          _channel.send(frame);
        }
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

/// 云端通道是否在线（ready 后 true；断开/关闭时 false），设置页设备管理展示用。
final watchLinkCloudOnlineProvider = StateProvider<bool>((ref) => false);

/// 隔离池内编码联动封面：读文件 → 解码 → 512px 等比缩放 → JPEG(78) → base64。
/// image 包解码较重，避免卡主线程；失败返回 null（静默无封面）。
Future<String?> _encodeLinkCoverData(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    return await _encodeLinkCoverBytes(await f.readAsBytes());
  } catch (_) {
    return null;
  }
}

/// 字节版联动封面编码（预缓存的代理封面字节走同一管线）。
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

/// 传递授权弹窗（三选一）：允许该设备 / 允许本次 / 不允许。
/// 返回 `'device'` / `'once'` / `'never'`；点外部或系统返回关闭返回 null。
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
            // 三选一：主推「允许该设备」，其次「允许本次」，弱化「不允许」。
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
