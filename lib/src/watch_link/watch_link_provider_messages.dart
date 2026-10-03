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
        if (fromCloud) {
          _cloudWatchName = (msg.payload['name'] as String?) ?? '';
          _send(LinkMessage.hello(
            ver: kLinkProtocolVersion,
            role: 'phone',
            name: '弦予音乐',
          ), cloud: true);
          _pushSnapshot(cloud: true);
          _sendEffects();
          _maybeAskOnHandshake();
        } else {
          _send(LinkMessage.hello(
            ver: kLinkProtocolVersion,
            role: 'phone',
            name: '弦予音乐',
          ));
          _pushSnapshot();
          _sendEffects();
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
    // 桌面联动已连接：腕表指令转发给桌面端遥控，不再控本机
    if (_container.read(desktopLinkProvider).phase ==
            DesktopLinkPhase.connected &&
        _container.read(desktopLinkProvider.notifier).relayCmd(msg)) {
      return;
    }
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
