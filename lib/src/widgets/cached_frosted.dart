import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'glass_settings.dart';
import 'blur_budget.dart' show globalIsScrolling;

/// 离线缓存毛玻璃表面（替代滚动中每帧全分辨率高斯的 `BackdropFilter`）。
///
/// 核心思路（“切换即固定，回退直接复用”）：
/// - 把页面内容放进一个 `RepaintBoundary`（挂 `backdropKey`），本组件在
///   静止时把这块内容**抓一次屏**，再在低分辨率上跑一遍高斯模糊，缓存成
///   `ui.Image`；
/// - 之后（包括被二级页盖住、弹回时）只是把这张模糊图按“本玻璃矩形相对
///   内容原点的子矩形”对齐 blit——每帧零高斯、零全屏抓屏；
/// - 只有“玻璃固定、内容在其下滚动”这种真相对运动时，才回退到实时
///   [`BackdropFilter`]，由原有 blur 预算降级扛住；滚动停止后再重新抓屏刷新
///   缓存。
///
/// 适配场景：顶栏/底栏压在页面内容之上（首页顶栏）。**不要**用于背板为纯色
/// 的面（如设置页顶栏下方无内容），那种面直接纯色或实时 BackdropFilter 即可。
class CachedFrosted extends StatefulWidget {
  const CachedFrosted({
    super.key,
    required this.backdropKey,
    required this.sigma,
    required this.fill,
    required this.child,
    this.radius = 0,
    this.downscale = 4,
  });

  /// 被缓存内容的 `RepaintBoundary` 的 GlobalKey（必须已被布局）。
  final GlobalKey backdropKey;

  /// 等效逻辑高斯 sigma（与实时 BackdropFilter 观感一致）。
  final double sigma;

  /// 半透明铺底（压暗/提亮，保证可读性）。
  final Color fill;

  /// 本玻璃表面要渲染的内容（顶栏/底栏控件）。
  final Widget child;

  /// 圆角。
  final double radius;

  /// 抓屏缩采样倍数（4 → 图片像素为 1/16，模糊一次即缓存）。
  final int downscale;

  @override
  State<CachedFrosted> createState() => _CachedFrostedState();
}

class _CachedFrostedState extends State<CachedFrosted> {
  /// 缓存的模糊小图（像素尺寸 = 内容逻辑尺寸 ÷ [widget.downscale]）。
  ui.Image? _blurred;

  /// 抓屏时“本玻璃矩形”相对内容原点的偏移（逻辑坐标）。
  Offset _regionOrigin = Offset.zero;

  /// 抓屏时的内容逻辑尺寸。
  Size _backdropLogicalSize = Size.zero;

  /// 内容缩放系数：`_blurred` 每像素代表 `_scale` 逻辑像素（=1/downscale）。
  double get _scale =>
      _backdropLogicalSize.width <= 0 ? 1.0 : 1.0 / widget.downscale;

  bool _scrolling = globalIsScrolling.value;
  bool _disposed = false;
  int _captureToken = 0;

  @override
  void initState() {
    super.initState();
    globalIsScrolling.addListener(_onScrollChanged);
    // 首次布局结束后抓一次（内容可见时）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  @override
  void didUpdateWidget(CachedFrosted oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 尺寸/圆角等变化不想重抓；仅当 backdrop 换了才重抓。
    if (oldWidget.backdropKey != widget.backdropKey ||
        oldWidget.downscale != widget.downscale) {
      _capture();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    globalIsScrolling.removeListener(_onScrollChanged);
    _blurred?.dispose();
    super.dispose();
  }

  void _onScrollChanged() {
    final sc = globalIsScrolling.value;
    if (sc == _scrolling) return;
    _scrolling = sc;
    if (!sc) {
      // 滚动停止：重新抓屏刷新缓存（延迟到本帧后，确保内容已静止）。
      WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
    }
    if (mounted) setState(() {});
  }

  /// 抓屏：内容 → 低分辨率 → 高斯模糊 → 缓存为 `_blurred`。
  Future<void> _capture() async {
    final token = ++_captureToken;
    final ctx = widget.backdropKey.currentContext;
    if (ctx == null || !mounted) return;
    final box = ctx.findRenderObject();
    if (box is! RenderRepaintBoundary) return;
    final boundary = box;
    // 本玻璃相对内容原点的偏移。
    final myBox = context.findRenderObject();
    if (myBox is! RenderBox) return;
    final boundaryRoot = boundary.localToGlobal(Offset.zero);
    final myGlobal = myBox.localToGlobal(Offset.zero);
    final regionOrigin = (myGlobal - boundaryRoot);
    final backdropLogical = boundary.size;

    // 抓屏前取好 dpr，避免跨 async 用 BuildContext。
    final dpr = MediaQuery.devicePixelRatioOf(context);

    final ui.Image src;
    try {
      src = await boundary.toImage(pixelRatio: 1.0 / widget.downscale);
    } catch (_) {
      return;
    }
    if (_disposed || token != _captureToken) {
      src.dispose();
      return;
    }

    // 低分辨率画布上做一次高斯模糊（等价全分辨率 sigma=widget.sigma）。
    final sigma = widget.sigma / widget.downscale * dpr;
    final sw = math.max(1, (backdropLogical.width / widget.downscale).round());
    final sh = math.max(1, (backdropLogical.height / widget.downscale).round());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.saveLayer(
      Offset.zero & Size(sw.toDouble(), sh.toDouble()),
      Paint()..imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.clamp,
      ),
    );
    canvas.drawImageRect(
      src,
      Offset.zero & Size(src.width.toDouble(), src.height.toDouble()),
      Rect.fromLTWH(0, 0, sw.toDouble(), sh.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    final picture = recorder.endRecording();
    final blurred = await picture.toImage(sw, sh);
    picture.dispose();
    src.dispose();
    if (_disposed || token != _captureToken) {
      blurred.dispose();
      return;
    }
    setState(() {
      _blurred?.dispose();
      _blurred = blurred;
      _regionOrigin = regionOrigin;
      _backdropLogicalSize = backdropLogical;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 内容在滚动 → 存在真相对运动 → 回退实时 BackdropFilter（由预算降级扛）。
    if (_scrolling || _blurred == null) {
      return ClipRect(
        child: BackdropFilter(
          filter: cheapBackdropBlur(widget.sigma),
          child: Container(color: widget.fill, child: widget.child),
        ),
      );
    }
    // 静止 → 直接 blit 缓存模糊图，零逐帧高斯。
    return Container(
      decoration: BoxDecoration(
        color: widget.fill,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      child: CustomPaint(
        painter: _CachedBlurPainter(
          image: _blurred!,
          regionOrigin: _regionOrigin,
          backdropLogicalSize: _backdropLogicalSize,
          scale: _scale,
        ),
        child: widget.child,
      ),
    );
  }
}

/// 把缓存模糊图按玻璃矩形相对内容原点的子矩形，对齐 blit 到玻璃表面。
class _CachedBlurPainter extends CustomPainter {
  _CachedBlurPainter({
    required this.image,
    required this.regionOrigin,
    required this.backdropLogicalSize,
    required this.scale,
  });

  final ui.Image image;
  final Offset regionOrigin;
  final Size backdropLogicalSize;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    if (image.width <= 0 || image.height <= 0) return;
    // 玻璃矩形在内容坐标系里（逻辑）→ 换算到模糊小图像素坐标系。
    final srcLeft =
        (regionOrigin.dx * scale).clamp(0.0, image.width.toDouble()).toDouble();
    final srcTop = (regionOrigin.dy * scale)
        .clamp(0.0, image.height.toDouble())
        .toDouble();
    // 玻璃高度可能超出内容区域（如状态栏之上无内容），封到内容高度。
    final availH = backdropLogicalSize.height - regionOrigin.dy;
    final availW = backdropLogicalSize.width - regionOrigin.dx;
    final paintH = math.min(size.height, math.max(0.0, availH));
    final paintW = math.min(size.width, math.max(0.0, availW));
    if (paintW <= 0 || paintH <= 0) return;
    final srcRect = Rect.fromLTWH(
      srcLeft,
      srcTop,
      (paintW * scale)
          .clamp(0.0, image.width.toDouble())
          .toDouble(),
      (paintH * scale)
          .clamp(0.0, image.height.toDouble())
          .toDouble(),
    );
    final dstRect = Rect.fromLTWH(0, 0, paintW, paintH);
    canvas.drawImageRect(
      image,
      srcRect,
      dstRect,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_CachedBlurPainter old) =>
      old.image != image ||
      old.regionOrigin != regionOrigin ||
      old.backdropLogicalSize != backdropLogicalSize ||
      old.scale != scale;
}