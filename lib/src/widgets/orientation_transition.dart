import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/shell.dart';
import '../core/app_colors.dart';

/// 横竖屏形态切换的「摘要色淡出→淡入」转场蒙层。
///
/// 竖屏路由与横屏容器是两套独立形态，旋转一瞬形态 provider 切向新朝向、而
/// 系统窗口仍处于旋转过渡，中间会有 1~2 帧把旧布局拉伸到新尺寸（「一帧
/// 拉升」）。本组件监听 [isLandscapeProvider]，在形态翻转时播：先快速淡出
/// 到一个与当前背景接近的摘要色蒙层盖满全屏（遮住新旧切换的拉伸帧），等新
/// 形态稳定后淡入，最后自动卸载。蒙层 IgnorePointer，不参与交互；不播放时
/// 是一个空盒，零渲染开销。
///
/// 节奏刻意做得快（out ≈ 110ms / in ≈ 200ms）——只为「演出」这一次形态切换，
/// 不拖累日常旋转手感；快速连续翻转用代数守卫丢弃过期回调，避免动画串扰。
class OrientationTransitionOverlay extends ConsumerStatefulWidget {
  const OrientationTransitionOverlay({super.key});

  @override
  ConsumerState<OrientationTransitionOverlay> createState() =>
      _OrientationTransitionOverlayState();
}

class _OrientationTransitionOverlayState
    extends ConsumerState<OrientationTransitionOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _opacity;

  /// 是否正在播放转场（决定蒙层是否挂载）。
  bool _active = false;

  /// 代数守卫：连续翻转丢弃过期回调。
  int _gen = 0;

  static const _ease = Cubic(0.16, 1.0, 0.3, 1.0);
  static const _outDuration = Duration(milliseconds: 110);
  static const _inDuration = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: _outDuration);
    _opacity = CurvedAnimation(parent: _c, curve: _ease);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    ref.listen(isLandscapeProvider, (prev, next) {
      if (prev == null || prev == next) return;
      _run();
    });
  }

  /// 触发一次形态切换转场：淡出 → 等新形态一帧 → 淡入 → 卸载。
  Future<void> _run() async {
    final gen = ++_gen;
    setState(() => _active = true);
    // 淡出到摘要色。
    await _c.forward().orCancel;
    if (!mounted || gen != _gen) return;
    // 关键：等一帧，确保切换后的新形态已完成 build/布局，再淡入。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || gen != _gen) return;
    // 淡入。
    _c.duration = _inDuration;
    final inGen = gen;
    await _c.reverse().orCancel;
    if (!mounted || inGen != _gen) return;
    setState(() {
      _active = false;
    });
  }

  Color _summaryColor(BuildContext context) => appSurfaceBg(context);

  @override
  Widget build(BuildContext context) {
    if (!_active) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) =>
              Opacity(opacity: _opacity.value, child: child),
          child: ColoredBox(color: _summaryColor(context)),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }
}