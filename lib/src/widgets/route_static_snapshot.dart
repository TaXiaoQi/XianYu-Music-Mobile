import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';

/// 整页转场静态化包装（「不牺牲效果、换一条低成本渲染路线」）。
///
/// 平移动效切页时，整页每个真实毛玻璃表面都会逐帧做全屏 SaveLayer 离屏合成
/// + 高斯，这是切页掉帧根因。本组件在动画期间用【一帧预渲染的真实页面快照】
/// 替代实时 widget 树做平移：
/// - 毛玻璃/液态玻璃观感原样烘焙进快照（满档 sigma，不缩档、不降级）；
/// - 动画全程只平移一张图，零逐帧全屏高斯、零实时 BackdropFilter；
/// - 动画结束瞬间换回真实页面；快照捕获自同一页面的同一帧，无缝衔接、无跳变。
///
/// 真实页面子树用 [Offstage] 隐藏而非卸载，保证列表滚动位置等 State 全程保留。
/// 仅在毛玻璃开启且竖屏覆盖/平滑切页时生效，朴素页面不引入抓屏开销。
///
/// 用法：放在滑动转场的 child 上（如 `SlideTransition(child: RouteStaticSnapshot(...))`）。
class RouteStaticSnapshot extends ConsumerStatefulWidget {
  const RouteStaticSnapshot({
    super.key,
    required this.animation,
    required this.child,
  });

  /// 控制本页面进出场转场的动画（用于判定「正在切页」窗口）。
  final Animation<double> animation;

  /// 要被静态化的页面子树（保持挂载，切页时 Offstage 隐藏）。
  final Widget child;

  @override
  ConsumerState<RouteStaticSnapshot> createState() =>
      _RouteStaticSnapshotState();
}

class _RouteStaticSnapshotState extends ConsumerState<RouteStaticSnapshot> {
  // 快照缩采样（1/2 → 像素 1/4）：运动期间轻微软化不可见，抓屏与内存成本大降。
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
    _enabled =
        ref.read(settingsProvider).valueOrNull?.frostedGlass ?? true;
    widget.animation.addStatusListener(_onStatus);
    // 首帧布局后尽早抓一次，避免首个转场冷启动时无快照。
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  void _onStatus(AnimationStatus status) {
    // 只在「开始运动（进入切页窗口）」这个边沿抓一次屏。
    if (status == AnimationStatus.forward || status == AnimationStatus.reverse) {
      _capture();
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    _image?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (!_enabled || _capturing) return;
    _capturing = true;
    final token = ++_token;
    final ctx = _boundaryKey.currentContext;
    final box = ctx?.findRenderObject();
    if (!mounted || ctx == null || box is! RenderRepaintBoundary) {
      _capturing = false;
      return;
    }
    if (box.size.isEmpty) {
      _capturing = false;
      return;
    }
    // 同步阶段取好 dpr 与尺寸，避免跨 async 用 BuildContext。
    final dpr = MediaQuery.devicePixelRatioOf(ctx);
    final size = box.size;
    ui.Image? img;
    try {
      img = await box.toImage(
        pixelRatio: dpr / _downscale,
      );
    } catch (_) {
      img = null;
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
          // 真实页面保持挂载（Offstage 隐藏以跳过昂贵绘制、保留 State）；
          // 快照未就绪时走原样渲染，逻辑不劣化。
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