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
import '../core/application_logger.dart';
import '../core/platform_caps.dart';
import '../core/settings.dart';
import '../desktop_link/desktop_link_provider.dart';
import '../effects/sound_effect_provider.dart';
import '../favorites/favorites_provider.dart';
import '../i18n/i18n.dart';
import '../library/saf_channel.dart';
import '../lyrics/lyrics_repository.dart';
import '../navigation/routes.dart';
import '../online/cover_proxy.dart';
import '../player/mv_provider.dart';
import '../player/player_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/modern_dialog.dart';
import '../widgets/predictive_dialog_route.dart';
import 'cloud_channel.dart';
import 'protocol.dart';
import 'watch_link_channel.dart';


part 'watch_link_provider_connection.dart';
part 'watch_link_provider_dialogs.dart';
part 'watch_link_provider_messages.dart';
part 'watch_link_provider_playback.dart';
part 'watch_link_provider_sync.dart';
part 'watch_link_provider_transport.dart';
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

  Timer? _fxPushTimer;

  Timer? _mvPushTimer;

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
  bool _lastSeenPlaying = false;
  LinkPlayMode _lastMode = LinkPlayMode.order;
  bool _lastLiked = false;
  DateTime _lastPosPush = DateTime.fromMillisecondsSinceEpoch(0);

  // ---- 起播自动唤起 ----

  bool _wakeInFlight = false;
  DateTime _lastWakeAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _wakeRetryGap = Duration(seconds: 60);

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

    _providerSubs.add(_container.listen<SoundEffectState>(
      soundEffectProvider,
      (_, _) => _pushEffectsDebounced(),
    ));

    _providerSubs.add(_container.listen<MvState>(
      mvProvider,
      (_, _) => _pushMvPhaseDebounced(),
    ));
  }

  void dispose() {
    beforePlayGate = null;
    _fxPushTimer?.cancel();
    _mvPushTimer?.cancel();
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

  // ---- 帧发送队列（背压） ----

  final List<(Uint8List, bool)> _txQueue = [];

  final List<(Uint8List, bool)> _txLowQueue = [];

  bool _txDraining = false;

  int _txGen = 0;

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

Future<String?> showTransferConfirmDialog(
  BuildContext context, {
  String? watchName,
}) {
  return showPredictiveDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _TransferConfirmDialog(
      watchName: watchName ?? tr('测试手表'),
    ),
  );
}
