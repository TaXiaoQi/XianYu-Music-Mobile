import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cover_image.dart';
import 'flying_cover.dart';

/// 预测返回时的「封面回拨」：
///
/// 原版关闭播放页/二级播放列表页时，封面会倒飞回迷你播放条。但 Android 预测
/// 返回由系统接管滑动，Flutter 的 HeroController 不会在预测返回手势中飞行封面，
/// 只做整屏缩放。本服务让顶路由在预测返回手势中，叠加一张「正在飞回播放条」的
/// 封面，随手指进度从源封面位置缩向目标封面位置，把系统预测行程与原有封面回拨
/// 语义统一起来。
///
/// 源与目标分开注册，由不同的组件承担：
/// - 源（[registerSource]）：播放页大封面（[CoverReturnSource]）或二级页面的
///   页面迷你播放条封面（页面内嵌 MiniPlayerBar，内部定位模式）。
/// - 目标（[registerTarget]）：shell 迷你播放条封面（root 常驻，二级页面仍存活）。
class PredictiveCoverReturn {
  PredictiveCoverReturn._();
  static final PredictiveCoverReturn instance = PredictiveCoverReturn._();

  _ReturnSource? _source;
  Rect Function()? _targetProvider;

  /// 注册源封面（播放页大封面 / 页面迷你条封面）。
  void registerSource({
    String? songPath,
    String? networkUrl,
    String? thumbPath,
    required Rect Function() rectProvider,
  }) {
    final s = _source ??= _ReturnSource();
    s.rectProvider = rectProvider;
    s.songPath = songPath;
    s.networkUrl = networkUrl;
    s.thumbPath = thumbPath;
  }

  /// 切歌/切换布局时，仅刷新封面图源，不动矩形注册。
  void updateSource({String? songPath, String? networkUrl, String? thumbPath}) {
    final s = _source;
    if (s == null) return;
    s.songPath = songPath;
    s.networkUrl = networkUrl;
    s.thumbPath = thumbPath;
  }

  /// 注销源封面；仅当 [provider] 正是当前注册者时才清空，避免误删他方注册。
  void unregisterSource(Rect Function() provider) {
    final s = _source;
    if (s != null && identical(s.rectProvider, provider)) {
      _source = null;
    }
  }

  /// 读取当前源矩形（惰性：每次调用实时计算，布局稳定后即为封面矩形）。
  Rect get sourceRect => _source?.rectProvider?.call() ?? Rect.zero;

  (String?, String?, String?) get coverSource {
    final s = _source;
    return (s?.songPath, s?.networkUrl, s?.thumbPath);
  }

  /// 注册目标封面（shell 迷你条封面矩形）。重复注册同实例会保留为最新。
  void registerTarget(Rect Function() provider) {
    _targetProvider = provider;
  }

  /// 注销目标封面；仅当是同一实例时清空。
  void unregisterTarget(Rect Function() provider) {
    if (identical(_targetProvider, provider)) {
      _targetProvider = null;
    }
  }

  /// 当前生效的目标封面矩形；无注册实例时返回 null。
  Rect? get targetRect => _targetProvider?.call();
}

class _ReturnSource {
  String? songPath;
  String? networkUrl;
  String? thumbPath;
  Rect Function()? rectProvider;
}

/// 播放页大封面锚点：把自身矩形与封面图源注册进 [PredictiveCoverReturn]，
/// 供预测返回转场读取后进行封面临回动画。只需包住大封面的 Hero 即可。
class CoverReturnSource extends StatefulWidget {
  const CoverReturnSource({
    super.key,
    required this.child,
    this.songPath,
    this.networkUrl,
    this.thumbPath,
  });

  final Widget child;
  final String? songPath;
  final String? networkUrl;
  final String? thumbPath;

  @override
  State<CoverReturnSource> createState() => _CoverReturnSourceState();
}

class _CoverReturnSourceState extends State<CoverReturnSource> {
  final GlobalKey _key = GlobalKey();
  bool _registered = false;
  // 保持为闭包变量：unregisterSource 依赖 identical 按实例匹配，若改成方法
  // tear-off 每次访问都会生成新闭包，identical 恒为 false 导致源无法注销。
  // ignore: prefer_function_declarations_over_variables
  late final Rect Function() _provider = () {
    final ctx = _key.currentContext;
    // 元素可能已处于 failed/inactive（如预测返回转场中途注销），此时
    // findRenderObject() 会断言失败，需先通过 mounted 守卫。
    if (ctx == null || !ctx.mounted) return Rect.zero;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return Rect.zero;
    // localToGlobal 会一路向上求祖先链的变换。转场中祖先可能仍处于
    // NEEDS-LAYOUT（如 SlideTransition 的 RenderFractionalTranslation），
    // 即便封面自身 hasSize，debug 下仍会断言失败、打断整帧 build 导致
    // 飞封面失效。这里把几何查询做成防御式：那一帧拿不到就返回零矩形。
    try {
      return ro.localToGlobal(Offset.zero) & ro.size;
    } catch (_) {
      return Rect.zero;
    }
  };

  void _sync() {
    if (!_registered) {
      _registered = true;
      PredictiveCoverReturn.instance.registerSource(
        songPath: widget.songPath,
        networkUrl: widget.networkUrl,
        thumbPath: widget.thumbPath,
        rectProvider: _provider,
      );
    } else {
      PredictiveCoverReturn.instance.updateSource(
        songPath: widget.songPath,
        networkUrl: widget.networkUrl,
        thumbPath: widget.thumbPath,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant CoverReturnSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    PredictiveCoverReturn.instance.unregisterSource(_provider);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: _key, child: widget.child);
  }
}

/// 预测返回转场中叠加的「正在飞回迷你条」封面。
///
/// [animation] 由路由传入：预测返回开始时 ≈1，随提交趋近 0，因此推进量
/// `t = 1 - animation` 从 0→1，把封面从源封面位置线性缩向目标封面位置。
/// 取消手势时 animation 返回 1，封面原路飞回，自然反向。
///
/// 封面通过 `OverlayPortal` 渲染到**根 overlay 顶层**，而不是放进路由转场的
/// Stack 内。预测返回由 FadeForwards 整屏缩放/backdrop 接管，若封面只挂在
/// 转场子树里，会被上层缩放变换或播放页遮挡；提到 overlay 顶层后与
/// FlyingCover 同级渲染，保证「不被播放页挡住」。
class PredictiveCoverReturnView extends StatefulWidget {
  const PredictiveCoverReturnView({
    super.key,
    required this.animation,
  });

  final Animation<double> animation;

  @override
  State<PredictiveCoverReturnView> createState() =>
      _PredictiveCoverReturnViewState();
}

class _PredictiveCoverReturnViewState extends State<PredictiveCoverReturnView> {
  OverlayEntry? _entry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 本组件随预测返回转场在 buildTransitions 内首帧挂载，此刻正处于 build
    // 阶段（正在构建 PredictiveBackGestureDetector）。若同步 Overlay.insert，
    // insert 会对根 overlay 调 setState → 命中「markNeedsBuild called during
    // build」断言、整帧中断并引发后续连环报错。因此把 overlay entry 的插入
    // 推迟到本帧结束之后（此后再无 build scope，安全可改）。
    if (_entry == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _entry != null) return;
        final entry = OverlayEntry(builder: (ctx) => _buildCover(ctx));
        _entry = entry;
        Overlay.of(context, rootOverlay: true).insert(entry);
      });
    }
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  Rect _target(BuildContext context) {
    // 目标位置优先用实时封面矩形（mini bar 封面 localToGlobal），与普通返回
    // 完全一致——播放条被拖到任意位置（如上/横屏）都能精确对位。只有二级页面
    // 未注册 FlyingCover 目标时，才回退到 shell 的固定停靠位（returnTarget）。
    return FlyingCover.instance.targetRect ??
        PredictiveCoverReturn.instance.targetRect ??
        // 兜底：迷你条封面左下角固定占位。
        Rect.fromLTWH(
          20,
          MediaQuery.of(context).size.height -
              MediaQuery.of(context).padding.bottom -
              64,
          46,
          46,
        );
  }

  Widget _buildCover(BuildContext context) {
    final src = PredictiveCoverReturn.instance.sourceRect;
    if (src.isEmpty) return const SizedBox.shrink();
    final (songPath, networkUrl, thumbPath) =
        PredictiveCoverReturn.instance.coverSource;
    final target = _target(context);

    final p0 = src.center;
    final p2 = target.center;
    final s0 = src.width;
    final s1 = target.width;
    // 源封面是方形圆角（播放页大封面约 23-32，随机型不同），目标迷你条封面是
    // 圆形。圆角从源的近似方形渐变到目标的圆形（半径 = 边长一半），贴合
    // 原有封面回拨观感，避免全程画成圆盘（source cover big circle）显得怪异。
    final srcRadius = math.min(32.0, s0 * 0.08);
    final dstRadius = s1 / 2;

    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: widget.animation,
          builder: (context, _) {
            // 跟手量 raw：0（页完全在）→ 1（页完全退）。封面不随手势立即飞，
            // 而是等页面先退过 [_startProgress] 再启动，避免飞行封面与仍在原位
            // 的播放页封面重叠抢跑（「封面飞走了、原图上还有封面」）。
            // 启动前 t=0，飞行封面停在源封面位置遮住它；页退过阈值后才开始缩向
            // 迷你条。取消手势则 raw 回落、封面原路回退，与页面一并弹回。
            final raw = (1 - widget.animation.value).clamp(0.0, 1.0);
            const startProgress = 0.5;
            final t = raw <= startProgress
                ? 0.0
                : (raw - startProgress) / (1 - startProgress);
            final center = Offset.lerp(p0, p2, t)!;
            final w = s0 + (s1 - s0) * t;
            final h = w;
            final radius = srcRadius + (dstRadius - srcRadius) * t;
            final topLeft = center - Offset(w / 2, h / 2);
            // 投影与透明度沿用飞行语义：近到达（t≈1）时淡出，避免与迷你条封面重叠闪烁。
            double opacity = 1.0;
            if (t > 0.94) opacity = 1 - (t - 0.94) / 0.06;
            opacity = opacity.clamp(0.0, 1.0);

            return Positioned(
              left: topLeft.dx,
              top: topLeft.dy,
              width: w,
              height: h,
              child: IgnorePointer(
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: w,
                    height: h,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 20,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: CoverImage(
                      songPath: songPath ?? '',
                      networkUrl: networkUrl,
                      thumbPath: thumbPath,
                      width: w,
                      height: h,
                      radius: radius,
                      highQuality: true,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 实际封面通过 [_entry] 渲染到根 overlay 顶层，这里只占位，不占转场布局。
    return const SizedBox.shrink();
  }
}

/// 「打开播放页」封面飞行全局状态。
///
/// 打开转场期间为 true，用于两个配套抑制，避免手工顶层封面与真实封面重影：
/// - mini bar 收起其 Hero 源（[MiniPlayerBar] 忽略 heroTag）；
/// - 播放页隐藏真实大封面（[OpenCoverGuard] 让出顶层空间）。
class PlayerOpenCover {
  PlayerOpenCover._();
  static final ValueNotifier<bool> opening = ValueNotifier<bool>(false);
}

/// 播放页真实大封面守卫：打开飞行期间淡出真实封面，让顶层 overlay 封面独占；
/// 落地时淡入真实封面，与顶层封面的淡出做交叉淡化。子树始终保留在树中，
/// 因此 [CoverReturnSource] 持续注册目标矩形，顶层 [PlayerOpenCoverFly] 可精确对位。
class OpenCoverGuard extends StatefulWidget {
  const OpenCoverGuard({super.key, required this.child});

  final Widget child;

  @override
  State<OpenCoverGuard> createState() => _OpenCoverGuardState();
}

class _OpenCoverGuardState extends State<OpenCoverGuard> {
  bool _opening = PlayerOpenCover.opening.value;

  @override
  void initState() {
    super.initState();
    PlayerOpenCover.opening.addListener(_onOpeningChanged);
  }

  @override
  void dispose() {
    PlayerOpenCover.opening.removeListener(_onOpeningChanged);
    super.dispose();
  }

  // 不用 ValueListenableBuilder：其监听回调无 mounted 守卫，转场中（尤其播放页
  // 被 pop / predictive return 卸载时）若全局 notifier 恰好变化，会在元素已被
  // deactivate（不在 build scope）时 markNeedsBuild，触发
  // 「not a descendant of the root of the build scope」断言、整帧中断卡死。
  // 改为把自己的重建推迟到帧后（此时 deactivate 的元素已被 finalizeTree 卸载，
  // mounted 为 false 直接跳过），只在仍存活且可安全重建时 setState。
  void _onOpeningChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _opening = PlayerOpenCover.opening.value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _opening ? 0 : 1,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      child: widget.child,
    );
  }
}

/// 打开播放页时手工的「封面飞行」（mini bar → 播放页大封面）。
///
/// 常规打开由 Hero 承担飞行，但 HeroController 把飞行渲染在导航栈 overlay 内，
/// 特定导航层级下会被播放页盖住。本组件把封面渲染到**播放页自身层**（由路由
/// 转场 Stack 作为播放页上层的兄弟节点叠加），天然在整张播放页内容之上、且
/// 随播放页生命周期一起被清理，配合 [PlayerOpenCover]/[OpenCoverGuard] 抑制
/// 双份封面，实现打开期间始终可见的飞行。要求被放置在 `StackFit.expand` 的
/// 路由 Stack 中（见 _PlayerCoverRoute.buildTransitions）。
class PlayerOpenCoverFly extends StatefulWidget {
  const PlayerOpenCoverFly({super.key, required this.animation});

  final Animation<double> animation;

  @override
  State<PlayerOpenCoverFly> createState() => _PlayerOpenCoverFlyState();
}

class _PlayerOpenCoverFlyState extends State<PlayerOpenCoverFly> {
  bool _opened = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 挂载即标记打开态：mini bar 早已置 true，此处兜底确保覆盖所有触发路径，
    // 让 OpenCoverGuard 隐藏真实大封面，避免双份封面重影。
    if (!_opened) {
      _opened = true;
      PlayerOpenCover.opening.value = true;
    }
  }

  @override
  void dispose() {
    // 本组件在路由转场完成时随 transition Stack 卸载，卸载发生在 widget tree
    // 处于 locked 状态（finalizeTree/build 期间）。此时同步置 opening=false 会
    // 通知 OpenCoverGuard 的 ValueListenableBuilder 触发 markNeedsBuild，命中
    // 「setState() called when widget tree was locked」断言、整帧中断卡死。
    // 因此把复位推迟到本帧之后，避免在锁定期内同步广播重建。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PlayerOpenCover.opening.value = false;
    });
    super.dispose();
  }

  /// 飞行起点：mini bar 封面（圆形），复用 FlyingCover 实时目标位。
  Rect _source(BuildContext context) {
    return FlyingCover.instance.targetRect ??
        PredictiveCoverReturn.instance.targetRect ??
        Rect.fromLTWH(
          20,
          MediaQuery.of(context).size.height -
              MediaQuery.of(context).padding.bottom -
              64,
          46,
          46,
        );
  }

  /// 飞行终点：播放页大封面。优先用 [CoverReturnSource] 实时注册的矩形；
  /// 无法读取时回退到按屏宽/高估算的居中方块。
  Rect _destination(BuildContext context) {
    final s = PredictiveCoverReturn.instance.sourceRect;
    if (!s.isEmpty) return s;
    final size = MediaQuery.of(context).size;
    final cs = math.min(size.width * 0.85, size.height * 0.6);
    final cy = size.height * 0.46;
    return Rect.fromCenter(
      center: Offset(size.width / 2, cy),
      width: cs,
      height: cs,
    );
  }

  Widget _buildFly(BuildContext context) {
    final src = _source(context);
    final dst = _destination(context);
    final (songPath, networkUrl, thumbPath) =
        PredictiveCoverReturn.instance.coverSource;
    final p0 = src.center;
    final p2 = dst.center;
    final s0 = src.width;
    final s1 = dst.width;
    // 源封面是圆形 mini 条封面，目标封面是圆角方形大封面；半径随进度渐变。
    final srcRadius = s0 / 2;
    final dstRadius = math.min(30.0, s1 * 0.09);

    // 打开进度：与页面滑入用同一 easeOutCubic，视觉跟手一致。
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) {
        final raw = widget.animation.value.clamp(0.0, 1.0);
        final t = Curves.easeOutCubic.transform(raw);
        final center = Offset.lerp(p0, p2, t)!;
        final w = s0 + (s1 - s0) * t;
        final h = w;
        final radius = srcRadius + (dstRadius - srcRadius) * t;
        final topLeft = center - Offset(w / 2, h / 2);
        // 近落地淡出，配合 OpenCoverGuard 的真实封面淡入交叉淡化。
        double opacity = 1.0;
        if (t > 0.86) opacity = 1 - (t - 0.86) / 0.14;
        opacity = opacity.clamp(0.0, 1.0);

        return Positioned(
          left: topLeft.dx,
          top: topLeft.dy,
          width: w,
          height: h,
          child: IgnorePointer(
            child: Opacity(
              opacity: opacity,
              child: Container(
                width: w,
                height: h,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: CoverImage(
                  songPath: songPath ?? '',
                  networkUrl: networkUrl,
                  thumbPath: thumbPath,
                  width: w,
                  height: h,
                  radius: radius,
                  highQuality: true,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 直接内联渲染到播放页层：要求父级 Stack 为 StackFit.expand，
    // Positioned 依屏幕坐标系铺满，飞行封面位于整张播放页之上。
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.expand,
        children: [_buildFly(context)],
      ),
    );
  }
}