import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../core/application_logger.dart';

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
    if (status == AnimationStatus.forward || status == AnimationStatus.reverse) {
      // 状态监听在帧中途同步触发，此时树可能刚标脏未 paint，
      // 直接 toImage 会撞 !debugNeedsPaint 断言；推到帧末再截。
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
    _token++; // 作废在途截图，防止完成后误 setState / 误用旧图
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
    // detached 后 toImage 会炸（native peer collected）：pop 拆树窗口
    // 里 boundary 可能已被卸载，必须先挡掉。未绘制首帧的 layer! 空断言
    // 无法提前判断（layer 是 protected），由下方 try/catch 兜底。
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
      // 帧中标脏（新路由首帧、Offstage 切换、动画 tick）会让 toImage 撞
      // !debugNeedsPaint 断言；推迟一帧重试最多两次，覆盖所有时序。
      if (e.toString().contains('debugNeedsPaint') && attempt < 2 && mounted) {
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
          Offstage(offstage: showImg, child: widget.child),
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