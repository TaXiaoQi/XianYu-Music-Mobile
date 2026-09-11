import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/shell.dart';

/// 竖/横屏形态切换的「内容淡出→淡入」转场驱动值（1=正常，0=全透明）。
///
/// 翻转时壳层页面主体监听本值做 Opacity：旧形态淡出（盖掉旋转过渡期的
/// 拉伸帧）→ 等新形态完成一帧布局 → 新形态淡入。淡出到底透出的是壁纸/
/// 主题底色——不再使用纯色遮罩盖板（全屏色闪观感差）。
final orientationContentFade = ValueNotifier<double>(1.0);

/// 竖横屏形态切换转场的时序大脑：监听 [isLandscapeProvider]，翻转时把
/// [orientationContentFade] 从 1 压到 0 再回拉到 1。
///
/// 本组件自身不绘制任何内容（遮罩已移除），只承担时序与驱动；常驻挂在
/// 壳层最顶层。节奏刻意做得快（out ≈ 110ms / in ≈ 200ms）——只为「演出」
/// 这一次形态切换，不拖累日常旋转手感；快速连续翻转用代数守卫丢弃过期
/// 回调，避免动画串扰。
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

  /// 代数守卫：连续翻转丢弃过期回调。
  int _gen = 0;

  /// 是否已手动订阅朝向变化（didChangeDependencies 可能多次触发，只注册一次）。
  bool _listening = false;

  /// 手动订阅句柄（dispose 时关闭）。
  ProviderSubscription<bool>? _sub;

  static const _ease = Cubic(0.16, 1.0, 0.3, 1.0);
  static const _outDuration = Duration(milliseconds: 110);
  static const _inDuration = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: _outDuration);
    _opacity = CurvedAnimation(parent: _c, curve: _ease);
    // 控制器推进 → 同步内容透明度：out（0→1）映射内容 1→0，in（1→0）映射 0→1。
    _opacity.addListener(_syncFade);
  }

  void _syncFade() {
    orientationContentFade.value = 1.0 - _opacity.value;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_listening) return;
    _listening = true;
    // ref.listen 只允许在 build 中调用（riverpod 断言 debugDoingBuild），而本组件
    // 是常驻节点、首帧 didChangeDependencies 期间调用会抛断言并使 widget 树进入
    // 异常状态。用 listenManual 手动订阅，效果等价且不依赖 build 阶段。
    _sub = ref.listenManual(isLandscapeProvider, (prev, next) {
      if (prev == null || prev == next) return;
      _run();
    });
  }

  /// 触发一次形态切换转场：内容淡出 → 等新形态一帧 → 内容淡入。
  Future<void> _run() async {
    final gen = ++_gen;
    // 旧形态内容淡出（1 → 0）。
    await _c.forward().orCancel;
    if (!mounted || gen != _gen) return;
    // 关键：等一帧，确保切换后的新形态已完成 build/布局，再淡入。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || gen != _gen) return;
    // 新形态内容淡入（0 → 1）。
    _c.duration = _inDuration;
    final inGen = gen;
    await _c.reverse().orCancel;
    if (!mounted || inGen != _gen) return;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  void dispose() {
    _opacity.removeListener(_syncFade);
    // 兜底：若卸载时转场未完成，不把壳层内容留在半透明态。
    orientationContentFade.value = 1.0;
    _sub?.close();
    _c.dispose();
    super.dispose();
  }
}
