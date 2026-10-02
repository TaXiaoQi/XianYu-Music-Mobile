import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  final GlobalKey _boundaryKey = GlobalKey();
  ui.Image? _image;
  Size? _size;
  bool _enabled = true;
  bool _settleHold = false;

  bool get _moving {
    final s = widget.animation.status;
    return s == AnimationStatus.forward || s == AnimationStatus.reverse;
  }

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.forward || status == AnimationStatus.reverse) {
      _settleHold = false;
      // 上次转场残留的 _image 必须立即失效：status 翻转瞬间 moving=true，
      // showImg 会先于新抓帧（postFrame + toImage 异步）用旧图顶上——
      // 旧图是上次转场抓的页面画面，切过 tab 后是另一个 tab 的内容，
      // 表现为转场首帧闪一帧旧页面。清空后窗口内显示 live 层（恒 1.0
      // 完整渲染），新快照就绪后无缝接管
      final stale = _image;
      if (stale != null) {
        _image = null;
        _size = null;
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) => stale.dispose());
      }
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
    widget.animation.removeStatusListener(_onStatus);
    _image?.dispose();
    _image = null;
    _size = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 材质开关实时生效：毛玻璃/液态全关（含性能优先）时快照管线整体
    // 旁路——实底与纯壁纸色块的转场无 backdrop 采样，无需离屏缓存保护
    _enabled = glassMaterialActive(ref);
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
          // 快照接管已退役（不再抓帧，img 恒 null）：toImage 离屏烘焙里
          // BackdropFilter 采样失效，玻璃只剩 fill 读作实底白卡——pop 时
          // 页面已渲染好、抓帧 100ms 级就绪，快照在转场中段盖住 live 层，
          // 毛玻璃材质整体跳变（用户实测）；push 因首帧阻塞抓帧晚于转场
          // 就绪而从不显示，行为不对称。转场全程维持 live 层：玻璃
          // RepaintBoundary 保住旧帧、backdrop 背后是下页实时内容，
          // 观感与静置一致（液态玻璃已按同一原因放弃转场接管）
          IgnorePointer(
            ignoring: showImg,
            // 冻结窗口内静默 live 层：快照已完全遮挡页面，把子树 ticker
            // 静音停掉持续动画（shimmer/加载态/轮播等重绘源），返回/推入
            // 转场中当前页面不再产生任何更新，恒为最后一帧；恢复时 ticker
            // 原地续跑，配合 settle-hold 无缝接管
            child: TickerMode(
              enabled: !showImg,
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