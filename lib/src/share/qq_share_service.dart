// QQ 互联分享服务（移动端，基于 tencent_kit 插件）。
//
// - 惰性初始化：首次分享时调用 registerApp 并订阅分享结果流，避免侵入启动流程。
// - 分享以「网页卡片」形式发送落地页链接（歌名 + 歌手 + 封面 + 分享深链），
//   接收方点开落地页再拉起 App 播放；QQ 好友与 QQ 空间均支持网页分享。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tencent_kit/tencent_kit.dart';
import '../i18n/i18n.dart';

/// QQ 分享可能的结果。
enum QqShareResult { success, canceled, failed, notInstalled }

final qqShareServiceProvider = Provider<QqShareService>((_) => QqShareService());

class QqShareService {
  /// QQ 互联 APP_ID。必须与 pubspec.yaml 顶层 `tencent_kit.app_id` 保持一致。
  static const String appId = '1905495962';

  bool _inited = false;

  /// 当前一次分享的回调接收器（respStream 异步回传结果）。
  Completer<QqShareResult>? _pending;

  /// 发起一次分享（网页卡片）。失败时返回 failed，由调用方展示结果并兜底复制链接。
  ///
  /// [coverPath] 为本地封面文件路径（QQ SDK 无法可靠拉取带防盗链的远程 CDN
  /// 封面，卡片缩略图需本地文件），为空则卡片不带封面。
  Future<QqShareResult> share({
    required int scene,
    required String title,
    required String summary,
    required String targetUrl,
    String? coverPath,
  }) async {
    if (!await _ensureInit()) return QqShareResult.failed;

    // 清理上一个还未完成的回调，避免阻塞当前分享。
    final prev = _pending;
    if (prev != null && !prev.isCompleted) prev.complete(QqShareResult.failed);
    final completer = Completer<QqShareResult>();
    _pending = completer;

    try {
      // 本地路径转 file:// URI，插件侧取 path 写入 QQ 分享参数。
      final path = coverPath ?? '';
      final imageUri = path.isEmpty ? null : Uri.file(path);
      await TencentKitPlatform.instance.shareWebpage(
        scene: scene,
        title: title,
        summary: summary,
        imageUri: imageUri,
        targetUrl: targetUrl,
        appName: tr('弦予音乐'),
      );
    } catch (_) {
      if (!completer.isCompleted) completer.complete(QqShareResult.failed);
    }

    // 超时兜底，避免播放页 await 卡死。
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => QqShareResult.failed,
    );
  }

  /// QQ 客户端是否已安装（未安装时走网页分享可能失败，调用方应提示并兜底复制链接）。
  ///
  /// 原生实现的 `isQQInstalled` 依赖 `tencent != null`（须先 registerApp 创建实例），
  /// 若在首次分享前直接查询会因实例未创建而恒判「未安装」，故先走惰性初始化。
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
      // 3.1.0 之后必须先授予设备信息权限（隐私合规）。
      await TencentKitPlatform.instance.setIsPermissionGranted(granted: true);
      await TencentKitPlatform.instance.registerApp(appId: appId);
      TencentKitPlatform.instance.respStream().listen(_onResp);
      _inited = true;
      return true;
    } catch (_) {
      _inited = false;
      return false;
    }
  }

  void _onResp(TencentResp resp) {
    if (resp is TencentShareMsgResp) {
      final pending = _pending;
      if (pending != null && !pending.isCompleted) {
        final result = switch (resp.ret) {
          0 => QqShareResult.success,
          -4 => QqShareResult.canceled,
          _ => QqShareResult.failed,
        };
        pending.complete(result);
      }
    }
  }
}