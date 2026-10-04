part of 'watch_link_provider.dart';

extension WatchLinkControllerMessages on WatchLinkController {
  // ---- 字节入口与消息分发 ----

  void _onRaw(Uint8List bytes) {
    for (final msg in _decoder.feed(bytes)) {
      _onMessage(msg);
    }
  }

  void _onMessage(LinkMessage msg, {bool fromCloud = false}) {
    switch (msg.type) {
      case LinkMsgType.hello:
        final ver = msg.payload['ver'] as int?;
        if (ver != null && ver < kLinkProtocolVersion) {
          // 仅告警：旧腕端收不到推迟后的业务推送，需升级腕上端
          AppLog.warn('watch', '腕端协议版本过低（$ver），无法完成应用层鉴权');
        }
        _resetAuth();
        if (fromCloud) {
          _cloudWatchName = (msg.payload['name'] as String?) ?? '';
          _send(LinkMessage.hello(
            ver: kLinkProtocolVersion,
            role: 'phone',
            name: '弦予音乐',
          ), cloud: true);
        } else {
          _send(LinkMessage.hello(
            ver: kLinkProtocolVersion,
            role: 'phone',
            name: '弦予音乐',
          ));
        }
        _startAuth(fromCloud: fromCloud);
      case LinkMsgType.authChallenge:
        _onAuthChallenge(msg, fromCloud: fromCloud);
      case LinkMsgType.authProof:
        _onAuthProof(msg, fromCloud: fromCloud);
      case LinkMsgType.ping:
        _send(LinkMessage(LinkMsgType.pong, {
          't': msg.payload['t'],
        }), cloud: fromCloud);
      case LinkMsgType.bye:
        break;
      case LinkMsgType.cmd:
        if (!_requireAuthed(msg.type)) break;
        _onCmd(msg);
      case LinkMsgType.backupFile:
        if (!_requireAuthed(msg.type)) break;
        _handleIncomingBackup(msg);
      case LinkMsgType.watchLogFile:
        if (!_requireAuthed(msg.type)) break;
        _handleIncomingLog(msg, fromCloud: fromCloud);
      default:
        break;
    }
  }

  // ---- 链路鉴权（HMAC-SHA256 挑战-应答，详见 link_auth.dart） ----

  void _resetAuth() {
    _authTimer?.cancel();
    _authTimer = null;
    _peerAuthed = false;
    _myAuthNonce = null;
  }

  bool _requireAuthed(int type) {
    if (_peerAuthed) return true;
    AppLog.debug('watch', '未鉴权丢弃业务帧: 0x${type.toRadixString(16)}');
    return false;
  }

  /// 回完 hello 后发起己方质询（有密钥才发）；业务推送推迟到鉴权通过。
  Future<void> _startAuth({required bool fromCloud}) async {
    _authTimer?.cancel();
    _authTimer = Timer(kLinkAuthTimeout, () {
      if (!_peerAuthed) {
        AppLog.warn('watch', '链路鉴权未在超时内完成（腕端版本过低或链路异常）');
      }
    });
    if (_pairSecret == null) {
      try {
        _pairSecret = await readPairSecret();
      } catch (e) {
        AppLog.warn('watch', '读取配对密钥失败: $e');
        return;
      }
    }
    final secret = _pairSecret;
    if (secret == null) return;
    final nonce = randomNonceHex();
    _myAuthNonce = nonce;
    _send(LinkMessage.authChallenge(nonce: nonce), cloud: fromCloud);
  }

  Future<void> _onAuthChallenge(
    LinkMessage msg, {
    required bool fromCloud,
  }) async {
    final nonce = msg.payload['nonce'] as String? ?? '';
    if (nonce.isEmpty) return;
    final grant = msg.payload['grant'] as String?;
    if (grant != null && grant.isNotEmpty) {
      // 密钥授予仅出现在用户手动配对路径（手表端接受配对/重选设备后）
      try {
        if (base64Decode(grant).length != 32) {
          throw FormatException('密钥长度异常');
        }
        await writePairSecret(grant);
        _pairSecret = grant;
      } catch (e) {
        AppLog.warn('watch', '采纳配对密钥失败: $e');
        return;
      }
    }
    var secret = _pairSecret;
    if (secret == null) {
      try {
        secret = await readPairSecret();
        _pairSecret ??= secret;
      } catch (e) {
        AppLog.warn('watch', '读取配对密钥失败: $e');
      }
    }
    if (secret == null) {
      // 无密钥：请求授予（手表仅用户手动发起时才会授予）
      _send(LinkMessage.authProof(proof: '', request: true), cloud: fromCloud);
      return;
    }
    _send(LinkMessage.authProof(
      proof: authProofHex(nonceHex: nonce, secretBase64: secret),
    ), cloud: fromCloud);
    // 反向质询：验证手表确实持有同一密钥
    final myNonce = randomNonceHex();
    _myAuthNonce = myNonce;
    _send(LinkMessage.authChallenge(nonce: myNonce), cloud: fromCloud);
  }

  void _onAuthProof(LinkMessage msg, {required bool fromCloud}) {
    final proof = msg.payload['proof'] as String? ?? '';
    final nonce = _myAuthNonce;
    final secret = _pairSecret;
    if (nonce == null || secret == null) return;
    if (!verifyAuthProof(
      nonceHex: nonce,
      secretBase64: secret,
      proofHex: proof,
    )) {
      AppLog.warn('watch', '腕端配对密钥校验失败，忽略本次鉴权');
      return;
    }
    _onAuthed(fromCloud: fromCloud);
  }

  /// 鉴权通过：补发握手期推迟的业务推送（与旧 hello 直推时序等价）。
  void _onAuthed({required bool fromCloud}) {
    _authTimer?.cancel();
    _authTimer = null;
    _myAuthNonce = null;
    _peerAuthed = true;
    AppLog.debug('watch', '链路鉴权通过');
    if (fromCloud) {
      _pushSnapshot(cloud: true);
      _sendEffects();
      _maybeAskOnHandshake();
    } else {
      _pushSnapshot();
      _sendEffects();
      _maybePushCloudBind();
      _maybeAskOnHandshake();
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
    // 桌面联动已连接：腕表指令转发给桌面端遥控，不再控本机
    if (_container.read(desktopLinkProvider).phase ==
            DesktopLinkPhase.connected &&
        _container.read(desktopLinkProvider.notifier).relayCmd(msg)) {
      return;
    }
    final notifier = _container.read(playerProvider.notifier);
    switch (msg.action()) {
      case LinkCmdAction.toggle:
        await notifier.toggle(origin: 'watchLink');
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
      case LinkCmdAction.fx:
        _onFxCommand(msg);
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
      } catch (e) {
        AppLog.warn('watch', '上报不喜爱失败: $e');
      }
    }
    await _container.read(playerProvider.notifier).next();
  }

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

}
