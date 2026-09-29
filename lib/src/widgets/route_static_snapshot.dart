import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../core/application_logger.dart';

// #region debug-point Z:report
// 调试会话 liquid-glass-page-flash 临时插桩，验证后整体清理
final HttpClient _dbgClient = HttpClient()
  ..connectionTimeout = const Duration(milliseconds: 500);

void _dbgReport(String hyp, String event, Map<String, Object?> data) {
  try {
    debugPrint('[DBG][$hyp] $event $data');
    _dbgClient
        .openUrl('POST', Uri.parse('http://192.168.3.32:7777/event'))
        .then((rq) {
      rq.headers.contentType = ContentType.json;
      rq.write(jsonEncode({
        'sessionId': 'liquid-glass-page-flash',
        'runId': 'pre',
        'hypothesisId': hyp,
        'location': 'route_static_snapshot.dart',
        'msg': '[DEBUG] $event',
        'data': data,
      }));
      return rq.close();
    }).then((_) {}).catchError((_) {});
  } catch (_) {}
}
// #endregion

class RouteStaticSnapshot extends ConsumerStatefulWidget {
  const RouteStaticSnapshot({
    super.key,
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;

  final Widget child;

  @override
  ConsumerState<RouteStaticSnapshot> createState() =>
      _RouteStaticSnapshotState();
}

class _RouteStaticSnapshotState extends ConsumerState<RouteStaticSnapshot> {
  static const int _downscale = 2;

  final GlobalKey _boundaryKey = GlobalKey();
  ui.Image? _image;
  Size? _size;
  bool _enabled = true;
  bool _capturing = false;
  int _token = 0;

  bool get _moving {
    final s = widget.animation.status;
    return s == AnimationStatus.forward || s == AnimationStatus.reverse;
  }

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider).valueOrNull;
    _enabled = (s?.frostedGlass ?? false) || (s?.liquidGlass ?? false);
    widget.animation.addStatusListener(_onStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  void _onStatus(AnimationStatus status) {
    // #region debug-point A:snap-status
    _dbgReport('A', 'snap-status', {
      'status': status.name,
      'moving': _moving,
      'hasImg': _image != null,
    });
    // #endregion
    if (status == AnimationStatus.forward || status == AnimationStatus.reverse) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _moving) _capture();
      });
      return;
    }
    final wasMoving = _moving;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !wasMoving) setState(() {});
    });
  }

  @override
  void dispose() {
    _token++;
    widget.animation.removeStatusListener(_onStatus);
    _image?.dispose();
    _image = null;
    _size = null;
    super.dispose();
  }

  Future<void> _capture({int attempt = 0}) async {
    if (!_enabled || _capturing) return;
    _capturing = true;
    final token = ++_token;
    final ctx = _boundaryKey.currentContext;
    final box = ctx?.findRenderObject();
    if (!mounted || ctx == null || box is! RenderRepaintBoundary) {
      _capturing = false;
      return;
    }
    if (box.size.isEmpty || !box.attached) {
      _capturing = false;
      return;
    }
    final dpr = MediaQuery.devicePixelRatioOf(ctx);
    final size = box.size;
    ui.Image? img;
    try {
      img = await box.toImage(
        pixelRatio: dpr / _downscale,
      );
    } catch (e) {
      img = null;
      if (attempt < 2 && mounted) {
        // push 后首帧图层未就绪时 toImage 可能抛空断言，不只 debugNeedsPaint 一种
        _capturing = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _capture(attempt: attempt + 1);
        });
        return;
      }
      AppLog.warn('route-snapshot', 'capture toImage failed: $e');
    }
    _capturing = false;
    if (!mounted || token != _token) {
      img?.dispose();
      return;
    }
    // #region debug-point A:snap-capture
    _dbgReport('A', 'snap-capture', {
      'ok': img != null,
      'attempt': attempt,
      'w': img?.width,
      'h': img?.height,
    });
    // #endregion
    setState(() {
      _image?.dispose();
      _image = img;
      _size = size;
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    final size = _size;
    final moving = _enabled && _moving;
    final showImg = moving && img != null && size != null;
    return RepaintBoundary(
      key: _boundaryKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 不用 Offstage：整树停绘后再还原时，重进绘制管线首帧全场景
          // backdrop 采样失效（顶栏/底栏/播放条/页面内玻璃齐黑一帧）。
          // 0.01 保底持续绘制让采样始终有效；live 层被顶层快照完全遮住，
          // 视觉无差异。抓取只发生在 img==null（showImg=false）时，无抓废
          IgnorePointer(
            ignoring: showImg,
            child: Opacity(
              opacity: showImg ? 0.01 : 1.0,
              child: widget.child,
            ),
          ),
          if (img != null && size != null && moving)
            Positioned.fill(
              child: RawImage(
                image: img,
                width: size.width,
                height: size.height,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
              ),
            ),
        ],
      ),
    );
  }
}