import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tencent_kit/tencent_kit.dart';
import '../i18n/i18n.dart';

enum QqShareResult { success, canceled, failed, notInstalled }

final qqShareServiceProvider = Provider<QqShareService>((_) => QqShareService());

class QqShareService {
  static const String appId = '1905495962';

  static const String universalLink =
      'https://api.xianyumusic.cn/qq_conn/1905495962/';

  bool _inited = false;

  AppLifecycleListener? _lifecycle;

  Completer<QqShareResult>? _pending;

  Future<QqShareResult> share({
    required int scene,
    required String title,
    required String summary,
    required String targetUrl,
    String? coverPath,
    String? musicUrl,
  }) async {
    if (!await _ensureInit()) return QqShareResult.failed;

    final prev = _pending;
    if (prev != null && !prev.isCompleted) prev.complete(QqShareResult.failed);
    final completer = Completer<QqShareResult>();
    _pending = completer;

    try {
      final path = coverPath ?? '';
      final imageUri = path.isEmpty ? null : Uri.file(path);
      final useMusicCard = musicUrl != null && musicUrl.isNotEmpty;
      if (useMusicCard) {
        await TencentKitPlatform.instance.shareMusic(
          scene: scene,
          title: title,
          summary: summary,
          imageUri: imageUri,
          musicUrl: musicUrl,
          targetUrl: targetUrl,
          appName: tr('弦予音乐'),
        );
      } else {
        await TencentKitPlatform.instance.shareWebpage(
          scene: scene,
          title: title,
          summary: summary,
          imageUri: imageUri,
          targetUrl: targetUrl,
          appName: tr('弦予音乐'),
        );
      }
    } catch (_) {
      if (!completer.isCompleted) completer.complete(QqShareResult.failed);
    }

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => QqShareResult.success,
    );
  }

  Future<bool> isQQInstalled() async {
    if (!await _ensureInit()) return false;
    try {
      return await TencentKitPlatform.instance.isQQInstalled();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ensureInit() async {
    if (_inited) return true;
    try {
      await TencentKitPlatform.instance.setIsPermissionGranted(granted: true);
      await TencentKitPlatform.instance
          .registerApp(appId: appId, universalLink: universalLink);
      TencentKitPlatform.instance.respStream().listen(_onResp);
      _lifecycle ??= AppLifecycleListener(onResume: _completePendingSuccess);
      _inited = true;
      return true;
    } catch (_) {
      _inited = false;
      return false;
    }
  }

  void _completePendingSuccess() {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.complete(QqShareResult.success);
    }
  }

  void _onResp(TencentResp resp) {
    if (resp is TencentShareMsgResp) {
      final pending = _pending;
      if (pending != null && !pending.isCompleted) {
        final result = switch (resp.ret) {
          TencentResp.kRetSuccess => QqShareResult.success,
          TencentResp.kRetUserCancel => QqShareResult.canceled,
          _ => QqShareResult.failed,
        };
        pending.complete(result);
      }
    }
  }
}