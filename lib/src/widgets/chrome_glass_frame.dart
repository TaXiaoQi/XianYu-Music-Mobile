import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'blur_budget.dart';

/// chrome 液态玻璃「最后一帧」缓存。
///
/// 转场动画中 ImageFilter.shader 的 backdrop 采样在部分设备（Impeller）
/// 上失效，chrome 条（悬浮顶栏/悬浮搜索条/底部导航）被迫降级为纯 blur，
/// 液态观感整段丢失。本模块在 chrome 可见且空闲时整屏抓一帧——chrome
/// 条的液态渲染输出就在这一帧里（toImage 边界内含 backdrop 内容时
/// shader 采样正确，同 RouteStaticSnapshot 的页内玻璃）；转场中各
/// chrome 玻璃面直接画自己区域的裁剪（drawImageRect，无任何采样），
/// 转场结束再交叉淡回实时渲染，观感全程连续。
class ChromeGlassFrame {
  ChromeGlassFrame({
    required this.image,
    required this.dpr,
    required this.logicalSize,
    this.region,
  });

  final ui.Image image;

  final double dpr;

  final Size logicalSize;

  /// 滚动补帧只抓 chrome 玻璃面并集区域（逻辑屏幕坐标），把滚动中
  /// 20Hz 的整屏 toImageSync 全场景重渲染（首页等重页签的滚动分段
  /// 卡顿主源）降为小区域重渲染；null = 整屏抓帧（静置/落定帧）。
  /// 消费端源矩形 = 面静止原点 − region.topLeft 后再乘 dpr。
  final Rect? region;
}

/// 最近一帧整屏缓存；null = 尚未抓到（消费方回落原降级路径）
final ValueNotifier<ChromeGlassFrame?> chromeGlassFrame =
    ValueNotifier<ChromeGlassFrame?>(null);

/// shell 写入：液态材质 + 竖屏悬浮 chrome 可见（根页签、未被二级页压住）
/// 时为 true。抓帧只发生在可见态，保证缓存里的 chrome 区域就是有效液态帧。
final ValueNotifier<bool> chromeGlassFrameActive = ValueNotifier<bool>(false);

final GlobalKey _boundaryKey = GlobalKey();

Timer? _debounce;

bool _capturing = false;

bool _wired = false;

// 补抓截止时刻：门控挡掉的抓帧在门控放开后自动重试，直到该时刻
DateTime _retryUntil = DateTime.fromMillisecondsSinceEpoch(0);

// 滚动中节流抓帧的下次允许时刻：帧供玻璃画裁剪（无 backdrop 采样），
// 50ms 节流（≈3 帧@60Hz）——透底内容滞后与液态波动离散化在模糊下无感
DateTime _nextRollingCaptureAt = DateTime.fromMillisecondsSinceEpoch(0);

/// builder 层边界：包住背景层 + 路由子树（含 shell chrome 条），
/// 不含 mini 播放条/播放页/飞行封面（其玻璃不走 chrome 缓存）
class ChromeGlassFrameBoundary extends StatefulWidget {
  const ChromeGlassFrameBoundary({super.key, required this.child});

  final Widget child;

  @override
  State<ChromeGlassFrameBoundary> createState() =>
      _ChromeGlassFrameBoundaryState();
}

class _ChromeGlassFrameBoundaryState extends State<ChromeGlassFrameBoundary>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    _wire();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      schedule();
      // 首抓落在冷启动早期：字体加载、布局、安全区插值尚未稳定时抓的
      // 帧会被长期持有，之后转场裁剪与稳定后的实时渲染出现字形/位置
      // 漂移（底栏 label 双影、两份不同字号）。启动后追加补抓，让缓存
      // 帧追上稳定后的真实渲染。
      Timer(const Duration(milliseconds: 2500), () => schedule());
      Timer(const Duration(seconds: 6), () => schedule());
    });
  }

  // 单例接线：转场结束（信号 false 沿）后安排抓帧，刷新缓存。
  // 抓帧时机 = 落定 + 350ms（chrome 淡入 240ms 完成后）
  void _wire() {
    if (_wired) return;
    _wired = true;
    globalIsTransitioning.addListener(() {
      if (!globalIsTransitioning.value) {
        schedule(const Duration(milliseconds: 350));
      }
    });
    // 滚动中低频刷新帧：玻璃滚动中改画缓存帧裁剪（无 backdrop 采样），
    // 帧必须跟手刷新才不会有「透底内容冻结」感——50ms 节流驱动。
    // 换页滑动（PageView）例外：整屏 toImageSync 全场景重渲染×每次换页
    // 6+ 次是卡顿主源，且玻璃面在换页段已按转场口径静默（不追帧），
    // 落定后由 scrolling 归零沿的 schedule(100ms) 补抓落定帧
    globalScrollTick.addListener(() {
      if (!globalIsScrolling.value) return;
      if (globalIsTabSwitching.value) return;
      final now = DateTime.now();
      if (now.isBefore(_nextRollingCaptureAt)) return;
      _nextRollingCaptureAt = now.add(const Duration(milliseconds: 50));
      schedule(Duration.zero);
    });
    // 停手补抓落定帧：滚动中帧内容滞后，落定帧供下一次转场裁剪使用
    globalIsScrolling.addListener(() {
      if (!globalIsScrolling.value) {
        schedule(const Duration(milliseconds: 100));
      }
    });
  }

  @override
  void didChangeMetrics() {
    // 旋转/分屏等几何变化后旧帧坐标失效，刷新
    schedule(const Duration(milliseconds: 400));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 主题等 Inherited 依赖变化后刷新（去抖 + 门控兜底）
    schedule(const Duration(milliseconds: 400));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(key: _boundaryKey, child: widget.child);
  }
}

/// 去抖安排一次抓帧；抓不抓由门控决定（转场/滚动/拖拽中、chrome 不可见
/// 时跳过并自动补抓，见 _capture/_retry）
void schedule([Duration delay = const Duration(milliseconds: 300)]) {
  _debounce?.cancel();
  // 每次显式安排都重置补抓截止。没有补抓的话：页签切换后 300ms 的
  // 抓帧会被 PageView 滑动（320ms）的 scrolling 门控吞掉，帧永远停留
  // 在上个页签——之后进二级页再返回，转场裁剪+adopt 淡回裁出的都是
  // 上个页签的透底（错页叠加复发）
  _retryUntil = DateTime.now().add(const Duration(seconds: 3));
  _debounce = Timer(delay, _capture);
}

// 门控挡掉后的补抓：短间隔重试直到门控放开或截止
void _retry() {
  if (DateTime.now().isAfter(_retryUntil)) return;
  _debounce?.cancel();
  _debounce = Timer(const Duration(milliseconds: 250), _capture);
}

/// chrome 玻璃面静止原点登记表。
///
/// 抓帧只发生在静止屏，此时 localToGlobal 是准确的（无动画在飞），
/// 顺手登记各玻璃面的布局原点；转场裁剪时直接查表，彻底绕开转场中
/// 祖先变换（底栏 hidden 动画 AnimatedScale 0.92⇄1.0）对 localToGlobal
/// 的污染——转场中污染值会把源矩形算偏，裁剪内容与实时渲染错位成
/// 「两个页面叠一起」的双影。此前用沿布局链累计 parentData offset 的
/// walk 规避，但 Scaffold 的 CustomMultiChildLayout 给 body 挂的
/// MultiChildLayoutParentData 不是 BoxParentData，walk 必断链回退
/// （悬浮底栏整树在 Scaffold body 里），双影复发——查表方案对树形
/// 零假设。value 为 null 表示尚未随抓帧登记，调用方回退 localToGlobal
/// （静止时才可能发生，此时 localToGlobal 本就准确）。
final Map<RenderBox, Offset?> _chromeFaceOrigins = {};

void registerChromeFace(RenderBox face) {
  _chromeFaceOrigins[face] = null;
}

void unregisterChromeFace(RenderBox face) {
  _chromeFaceOrigins.remove(face);
}

Offset? chromeFaceStaticOrigin(RenderBox face) => _chromeFaceOrigins[face];

/// 已登记 chrome 玻璃面的屏幕并集区域（逻辑坐标，裁到屏幕内）。
/// 滚动补帧只重渲染该区域——各面在滚动中位置固定，localToGlobal 准确；
/// 无已登记面时返回 null 回退整屏抓帧
Rect? _chromeUnionRegion(Size screen) {
  _chromeFaceOrigins.removeWhere((face, _) => !face.attached);
  Rect? union;
  for (final face in _chromeFaceOrigins.keys) {
    final rect = face.localToGlobal(Offset.zero) & face.size;
    union = union == null ? rect : union.expandToInclude(rect);
  }
  if (union == null || union.isEmpty) return null;
  final clipped = union.intersect(Offset.zero & screen);
  return clipped.isEmpty ? null : clipped;
}

/// 无读回抓帧：layer 树直接进 SceneBuilder，scene.toImageSync 产出
/// GPU 常驻纹理（不发生 GPU→CPU 读回），比 RenderRepaintBoundary
/// .toImage（读回型）便宜一个数量级——滚动中 50ms 节流刷新才可负担。
/// dpr 缩放由 pushTransform 承担（Scene.toImageSync 不支持 pixelRatio）；
/// region 非空时额外 pushClipRect 只光栅化该区域（chrome 面并集），
/// toImageSync 尺寸随之收窄——滚动补帧不再全场景重渲染
ui.Image? _captureSync(
  RenderRepaintBoundary box,
  double dpr, {
  Rect? region,
}) {
  final layer = box.debugLayer;
  if (layer is! OffsetLayer || !box.attached) return null;
  final w = ((region?.width ?? box.size.width) * dpr).round();
  final h = ((region?.height ?? box.size.height) * dpr).round();
  if (w <= 0 || h <= 0) return null;
  layer.updateSubtreeNeedsAddToScene();
  final builder = ui.SceneBuilder();
  try {
    builder.pushTransform(
        Matrix4.diagonal3Values(dpr, dpr, 1).storage);
    if (region != null) builder.pushClipRect(region);
    layer.addToScene(builder);
    if (region != null) builder.pop();
    builder.pop();
    final scene = builder.build();
    try {
      return scene.toImageSync(w, h);
    } finally {
      scene.dispose();
    }
  } catch (_) {
    return null;
  }
}

Future<void> _capture() async {
  if (_capturing) return;
  // 滚动中放行（由 scrollTick 的 50ms 节流控制频率）：帧刷新供玻璃画
  // 裁剪，滚动中玻璃不再实时采样 backdrop。转场/换页/拖拽中仍挡——
  // 转场要保护静态帧，换页段玻璃面已静默不需要追帧，拖拽中面在动会
  // 污染 origin 登记表
  if (globalIsTransitioning.value ||
      globalIsTabSwitching.value ||
      globalIsDragging.value) {
    _retry();
    return;
  }
  if (!chromeGlassFrameActive.value) {
    _retry();
    return;
  }
  if (!ui.ImageFilter.isShaderFilterSupported) return;
  final ctx = _boundaryKey.currentContext;
  final box = ctx?.findRenderObject();
  if (ctx == null || box is! RenderRepaintBoundary) return;
  if (box.size.isEmpty || !box.attached) return;
  final dpr = MediaQuery.devicePixelRatioOf(ctx);
  _capturing = true;
  try {
    // 滚动补帧只抓 chrome 玻璃面并集区域：整屏 toImageSync 全场景重渲染
    // 在重页签（首页）上以 20Hz 插进滚动帧 = 滚动分段卡顿（2026-10-08）。
    // 静置/落定帧保持整屏（转场 adopt 裁剪契约不变）
    final region =
        globalIsScrolling.value ? _chromeUnionRegion(box.size) : null;
    // 无读回抓帧优先：GPU 常驻纹理，比读回型便宜一个数量级；层未就绪
    // 等异常回退读回型兜底（仅整屏帧——区域帧的图像范围与读回型不符，
    // 回退会产生 region 错位的缓存帧，直接跳过等下个节流窗口重试）
    final img =
        _captureSync(box, dpr, region: region) ??
        (region == null ? await box.toImage(pixelRatio: dpr) : null);
    if (img == null) return;
    if (!box.attached) {
      img.dispose();
      return;
    }
    // 静止屏上 localToGlobal 准确：刷新各玻璃面登记原点，供转场裁剪查表
    _chromeFaceOrigins.removeWhere((face, _) => !face.attached);
    for (final face in _chromeFaceOrigins.keys.toList()) {
      _chromeFaceOrigins[face] = face.localToGlobal(Offset.zero);
    }
    final old = chromeGlassFrame.value;
    chromeGlassFrame.value = ChromeGlassFrame(
      image: img,
      dpr: dpr,
      logicalSize: box.size,
      region: region,
    );
    // 延迟一帧释放旧帧：消费方 paint 可能还持有引用读取
    if (old != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        old.image.dispose();
      });
    }
  } catch (_) {
    // 首帧图层未就绪等场景 toImage 可能抛错；安排补抓即可
    _retry();
  } finally {
    _capturing = false;
  }
}