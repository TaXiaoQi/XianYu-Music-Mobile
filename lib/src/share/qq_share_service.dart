import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tencent_kit/tencent_kit.dart';
import '../auth/auth_provider.dart';
import '../core/application_logger.dart';
import '../i18n/i18n.dart';

enum QqShareResult { success, canceled, failed, notInstalled }

final qqShareServiceProvider =
    Provider<QqShareService>((ref) => QqShareService(ref));

class QqShareService {
  QqShareService(this._ref);

  final Ref _ref;

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

  /// 鸿蒙 QQ 开放平台分享：shareJson 由服务端用互联 AppKey 签名组装
  /// （HMAC-SHA1），客户端只透传；好友分享为 ark 图文（鸿蒙 SDK 无音乐卡片）。
  Future<QqShareResult> shareHarmony({
    required int scene,
    required String title,
    required String summary,
    required String targetUrl,
    required String coverUrl,
  }) async {
    if (!await _ensureInit()) {
      AppLog.debug('qq', 'shareHarmony: init 失败，直接 failed');
      return QqShareResult.failed;
    }

    final prev = _pending;
    if (prev != null && !prev.isCompleted) prev.complete(QqShareResult.failed);
    final completer = Completer<QqShareResult>();
    _pending = completer;

    try {
      final data = await _ref.read(authProvider.notifier).requestAction(
        'qq_share_sign',
        {
          'scene': scene == TencentScene.kScene_QZone ? 'qzone' : 'qq',
          'title': title,
          'summary': summary,
          'url': targetUrl,
          'picture_url': coverUrl,
        },
        fetchTimeoutMs: 15000,
      );
      final shareJson = (data['share_json'] ?? '').toString();
      final sign = (data['share_json_sign'] ?? '').toString();
      AppLog.debug('qq', 'shareHarmony: 签名响应 share_json=${shareJson.length}'
          'B sign=${sign.length}B ts=${data['timestamp']} nonce=${data['nonce']}');
      await TencentKitPlatform.instance.shareArk(
        scene: scene,
        shareJson: shareJson,
        timestamp: int.tryParse('${data['timestamp'] ?? ''}') ?? 0,
        nonce: int.tryParse('${data['nonce'] ?? ''}') ?? 0,
        sign: sign,
      );
      AppLog.debug('qq', 'shareHarmony: shareArk 已调用，等待回执');
    } catch (e) {
      AppLog.debug('qq', 'shareHarmony: 失败 $e');
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
    } catch (e) {
      AppLog.debug('qq', 'ensureInit 失败: $e');
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
      AppLog.debug('qq', 'onShareResp ret=${resp.ret} msg=${resp.msg}');
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