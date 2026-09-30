import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../core/application_logger.dart';
import 'glass_settings.dart';

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
  bool _settleHold = false;
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
      _settleHold = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 无条件抓：首帧阻塞时 postFrame 会推迟到动画结束后才执行，
        // 若再叠加 _moving 条件快照将永远抓不到图（转场全程无保护）
        if (mounted) _capture();
      });
      return;
    }
    // 转场结束不立即移除快照：被快照完全遮挡的 live 层会被引擎剔除渲染，
    // 立即移除会让页面裸重渲染首帧玻璃采样黑。快照多保留一帧，
    // live 层先在快照底下完整渲染，下一帧移除时无缝接管
    final wasMoving = _moving;
    if (wasMoving && !_settleHold) {
      _settleHold = true;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _settleHold = false);
      });
      return;
    }
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
    final showImg =
        _enabled && (_moving || _settleHold) && img != null && size != null;
    // 同步快照就绪信号给玻璃层：showImg=true 时 backdrop 被快照图
    // （1.0 不透明）覆盖，转场中玻璃 shader 采样安全
    globalSnapshotReady.value = showImg;
    return RepaintBoundary(
      key: _boundaryKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 不用 Offstage：整树停绘后再还原时，重进绘制管线首帧全场景
          // backdrop 采样失效（顶栏/底栏/播放条/页面内玻璃齐黑一帧）。
          // live 层恒 1.0 完整渲染：转场开始到快照抓取完成之间的窗口里
          // （img 尚为 null）backdrop=完整页面内容，任何玻璃采样都不会黑；
          // 快照图就绪后盖在 live 层上方，视觉无差异。抓取只发生在
          // img==null（showImg=false）时，无抓废
          IgnorePointer(
            ignoring: showImg,
            child: widget.child,
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