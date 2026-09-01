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

  /// 预测返回手势是否处于「进行中」（[PredictiveCoverReturnView] 已挂载，
  /// 即 phase ≠ idle）。页面自身封面据此隐藏——封面由 overlay 单张接管，
  /// 避免「页面带着封面一起退下」。取消返回时视图卸载，恢复显示页内封面。
  final ValueNotifier<bool> returning = ValueNotifier<bool>(false);

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
    // 预测返回手势进行中（返回画面面自身封面，由根 overlay 单张接管）时把
    // 页内封面调成透明。用 Opacity 而非 Offstage：保持占用布局，Rect 解析与
    // Hero 转场不受影响；取消返回时同一帧恢复显示，与 overlay 封面无缝衔接。
    return KeyedSubtree(
      key: _key,
      child: ValueListenableBuilder<bool>(
        valueListenable: PredictiveCoverReturn.instance.returning,
        builder: (context, returning, _) => Opacity(
          opacity: returning ? 0.0 : 1.0,
          child: widget.child,
        ),
      ),
    );
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
        // 与插入同刻才置「封面回拨进行中」：页内封面隐藏与 overlay 封面出现
        // 严格同帧，避免中间露一帧背景。
        PredictiveCoverReturn.instance.returning.value = true;
        Overlay.of(context, rootOverlay: true).insert(entry);
      });
    }
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    // 手势取消/完成卸载：结束封面回拨，恢复页面自身封面显示。
    PredictiveCoverReturn.instance.returning.value = false;
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
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: widget.animation,
          builder: (context, _) {
            // 源封面矩形必须在动画 builder 内「逐帧」解析：横竖屏切换后播放页
            // 布局分支（LandscapeGate CoverReturnSource）可能尚未完成首帧布局，
            // 此刻 RenderBox 无尺寸返回零矩形。若像旧实现那样在 builder 外只读
            // 一次并直接短路返回空组件，后续帧将永远不再重试，整段预测返回手势
            // 的封面回拨就被静默吞掉（表现为「有概率不触发飞行动画」）。放在
            // builder 里后，每帧重读一次，一旦布局就绪即恢复飞行，且为 0 的那
            // 一帧仅画空不打断动画。
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

            // 跟手量 raw：0（页完全在）→ 1（页完全退）。页面先退、封面在源位
            // 保持；待手势走过约 1/3（raw ≥ 1/3）才开始飞封面，避免飞行封面与
            // 仍在原位的播放页封面重叠抢跑（「封面飞走了、原图上还有封面」）。
            // 启动前 t=0，飞行封面停在源封面位置遮住它；越过阈值后才缩向迷你条。
            // 取消手势则 raw 回落、封面原路回退，与页面一并弹回。
            final raw = (1 - widget.animation.value).clamp(0.0, 1.0);
            // 页面先下 → 封面原保持 → 约 1/3 处开始缩向迷你条。
            const startProgress = 1 / 3;
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