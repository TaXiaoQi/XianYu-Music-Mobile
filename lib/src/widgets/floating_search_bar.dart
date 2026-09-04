import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../i18n/i18n.dart';
import 'bilipai_glass.dart';
import 'blur_budget.dart';
import 'glass_settings.dart';
import 'page_search_bar.dart';

/// 首页/我的页「悬浮搜索框」：独立悬浮胶囊，固定悬浮在顶栏下方，不随内容滚动。
///
/// 材质跟随全局玻璃设置：
/// - 液态玻璃开启 → 中/高档走 [AdaptiveGlass]（shader 折射 + 高光，与底栏/迷你条
///   同一套参数），低档走伪液态毛玻璃（不跑 shader）；
/// - 液态玻璃关闭 → 毛玻璃（透明磨砂）/ 纯色回退，口径同底栏 `_frostedGlass`。
class FloatingSearchBar extends ConsumerWidget {
  const FloatingSearchBar({super.key, required this.onTap, this.onRecognize});

  final VoidCallback onTap;

  /// 听歌识曲入口（可选：首页带话筒，我的页不带）。
  final VoidCallback? onRecognize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 44,
          padding: const EdgeInsets.fromLTRB(18, 0, 6, 0),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('搜索歌曲、歌手、专辑'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
              if (onRecognize != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onRecognize,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC4141).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.mic_none,
                      size: 17,
                      color: Color(0xFFEC4141),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    // 材质外壳统一走 [FloatingGlassSurface]（与横屏搜索输入框同口径）。
    return FloatingGlassSurface(child: content);
  }
}

/// 悬浮玻璃表面容器：与 [FloatingSearchBar] 完全同一套材质口径（液态 shader /
/// 伪液态毛玻璃 / 毛玻璃 / 纯色回退，BlurSurfaceType.header），供搜索胶囊与
/// 横屏顶栏搜索输入框等 44 高胶囊控件复用，保证形态切换（点击进搜索）时
/// 材质连续不跳变。
class FloatingGlassSurface extends ConsumerWidget {
  const FloatingGlassSurface({super.key, required this.child, this.radius = 22});

  final Widget child;

  /// 视觉圆角：44 高胶囊用 22（半高）。
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.header));
    // 壁纸模式不再排除液态玻璃：悬浮顶栏与播放条同口径（playbarGlassSurface
    // 的液态条件也不排除壁纸），BiliPaiGlass 半透明铺底（alpha 0.40~0.50）
    // 本就透出壁纸，可读性由底色保证。仅低性能模式回退毛玻璃/纯色。
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            false) &&
            !lowPerf;

    if (liquid) {
      // 液态玻璃全档走真 shader（BiliPai 三档配方），低档不再用伪液态充数。
      final quality = liquidGlassQualitySetting(ref);
      return BiliPaiGlass(
        radius: radius,
        refract: bilipaiRefractOf(quality),
        chroma: bilipaiChromaOf(quality),
        blurSigma: surfaceBlurSigma(
          base: bilipaiBackdropBlurOf(quality),
          budget: budget,
          type: BlurSurfaceType.header,
          crispAtRest: true,
        ),
        backgroundColor: bilipaiSurfaceTint(context, ref, quality),
        specular: bilipaiSpecularOf(quality),
        edgeAmount: bilipaiEdgeOf(quality),
        saturation: bilipaiSaturationOf(quality),
        child: child,
      );
    }
    // 液态玻璃关闭：毛玻璃/纯色回退，复用伪液态表面口径（透明底 + 淡模糊）。
    // 搜索胶囊是毛玻璃表面，模糊强度跟随毛玻璃档位（frostedBlurScale）。
    return pseudoLiquidSurface(
      context: context,
      ref: ref,
      radius: radius,
      child: child,
      lowPerf: lowPerf,
      surfaceType: BlurSurfaceType.header,
      budget: budget,
      frostedScale: frostedBlurScale(ref),
    );
  }
}

/// BiliPai 风格小液态玻璃胶囊/圆钮：跟随全局玻璃设置（液态 shader / 伪液态
/// 毛玻璃 / 毛玻璃 / 纯色），材质口径与 [FloatingSearchBar] 完全一致。
/// 用于顶栏标题、图标按钮等小控件的玻璃包裹（BiliPai 首页顶部按钮观感）。
class BiliPaiPill extends ConsumerWidget {
  const BiliPaiPill({
    super.key,
    required this.child,
    this.onTap,
    this.radius = 20,
  });

  final Widget child;

  /// 为 null 时不可点（无涟漪，等同 disabled）。
  final VoidCallback? onTap;

  /// 视觉圆角：40px 高胶囊/圆钮用 20（半高），搜索胶囊 44 高用 22。
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.header));
    // 壁纸模式不再排除液态玻璃：与 FloatingGlassSurface / 播放条同口径，
    // BiliPaiGlass 半透明铺底本就透出壁纸。仅低性能模式回退毛玻璃/纯色。
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            false) &&
            !lowPerf;

    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );

    if (liquid) {
      // 液态玻璃全档走真 shader（BiliPai 三档配方），低档不再用伪液态充数。
      final quality = liquidGlassQualitySetting(ref);
      return BiliPaiGlass(
        radius: radius,
        refract: bilipaiRefractOf(quality),
        chroma: bilipaiChromaOf(quality),
        blurSigma: surfaceBlurSigma(
          base: bilipaiBackdropBlurOf(quality),
          budget: budget,
          type: BlurSurfaceType.header,
          crispAtRest: true,
        ),
        backgroundColor: bilipaiSurfaceTint(context, ref, quality),
        specular: bilipaiSpecularOf(quality),
        edgeAmount: bilipaiEdgeOf(quality),
        saturation: bilipaiSaturationOf(quality),
        child: content,
      );
    }
    return pseudoLiquidSurface(
      context: context,
      ref: ref,
      radius: radius,
      child: content,
      lowPerf: lowPerf,
      surfaceType: BlurSurfaceType.header,
      budget: budget,
      frostedScale: frostedBlurScale(ref),
    );
  }
}

/// 独立来源气泡：每个音源来源一个玻璃胶囊（BiliPai 材质），选中用轻量红底+红字
/// 替换原 ChoiceChip 底色。用于搜索页/榜单页的来源切换条——拆开成独立气泡，
/// 不再用一个大 [FloatingTabPill] 包裹全部来源。
class FloatingSourcePill extends ConsumerWidget {
  const FloatingSourcePill({
    super.key,
    required this.name,
    required this.selected,
    required this.onTap,
    this.height = 40,
  });

  final String name;

  /// 当前是否选中。
  final bool selected;

  final VoidCallback onTap;

  /// 胶囊高度（默认 40，整高 circular radius=height/2）。
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final radius = height / 2;
    return BiliPaiPill(
      onTap: onTap,
      radius: radius,
      child: Container(
        height: height,
        constraints: BoxConstraints(
          minWidth: height + 12,
        ),
        padding: EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            // 选中红字，未选中跟随主题次要色。
            color: selected
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 40×40 圆形玻璃图标按钮（[BiliPaiPill] 包裹），BiliPai 首页顶部按钮观感。
class BiliPaiIconButton extends StatelessWidget {
  const BiliPaiIconButton({
    super.key,
    this.icon,
    this.iconChild,
    this.onTap,
    this.color,
    this.tooltip,
  });

  final IconData? icon;
  final Widget? iconChild;
  final VoidCallback? onTap;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    // IconTheme 包裹：内置 Icon 用显式 color/size；iconChild（如自定义 SkinIcon）
    // 不传 color 时也能从 IconTheme 继承按钮标准色与尺寸。
    final iconWidget = SizedBox(
      width: 40,
      height: 40,
      child: IconTheme(
        data: const IconThemeData(size: 20).copyWith(
          color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        child: iconChild ??
            Icon(
              icon,
              size: 20,
              color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
    return BiliPaiPill(
      onTap: onTap,
      child: tooltip == null
          ? iconWidget
          : Tooltip(message: tooltip!, child: iconWidget),
    );
  }
}

/// 竖屏悬浮顶部栏（首页/我的页共用）：[标题玻璃胶囊] [搜索胶囊·自适应宽]
/// [右侧玻璃小按钮]。直接悬浮在状态栏下方，取代页面自带的 GlassTopBar 标题行。
class FloatingTopBar extends StatelessWidget {
  const FloatingTopBar({
    super.key,
    required this.title,
    required this.onSearchTap,
    this.onRecognize,
    this.actions = const [],
  });

  /// 标题内容（由调用方传入已带样式文本，胶囊内左对齐垂直居中）。
  final Widget title;

  final VoidCallback onSearchTap;

  /// 听歌识曲入口（可选：首页带话筒）。
  final VoidCallback? onRecognize;

  /// 右侧 [BiliPaiIconButton] 列表。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        BiliPaiPill(
          radius: 20,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: SizedBox(
              height: 40,
              child: Align(alignment: Alignment.centerLeft, child: title),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FloatingSearchBar(
            onTap: onSearchTap,
            onRecognize: onRecognize,
          ),
        ),
        for (final action in actions) ...[
          const SizedBox(width: 10),
          action,
        ],
      ],
    );
  }
}

/// 悬浮搜索输入框胶囊：与 [FloatingTopBar] 同材质口径的 44 高玻璃胶囊，内嵌
/// 一个 [TextField]。供搜索页 / 搜索结果页 / 本地页的悬浮顶栏复用（替代固定
/// GlassTopBar 内的实色搜索框）。
class FloatingGlassSearchField extends ConsumerWidget {
  const FloatingGlassSearchField({
    super.key,
    required this.controller,
    this.hint,
    this.readOnly = false,
    this.autofocus = false,
    this.isDense = true,
    this.onChanged,
    this.onTap,
    this.onSubmitted,
    this.showClear = false,
    this.onClear,
  });

  final TextEditingController controller;
  final String? hint;
  final bool readOnly;
  final bool autofocus;

  /// 直接使用 [TextField.isDense] 语义，作为朴素输入框（非整页搜索框）时关闭。
  final bool isDense;

  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final ValueChanged<String>? onSubmitted;
  final bool showClear;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return FloatingGlassSurface(
      radius: 22,
      child: SizedBox(
        height: 44,
        child: TextField(
          controller: controller,
          readOnly: readOnly,
          autofocus: autofocus,
          textInputAction: TextInputAction.search,
          style: TextStyle(
            fontSize: 14.5,
            color: scheme.onSurface,
          ),
          // 字段被高 44 的前缀图标/清除按钮撑高后，dense 输入框默认顶部对齐，
          // 文字会偏上；显式居中让键入文字与 hint 都垂直居中。
          textAlignVertical: TextAlignVertical.center,
          cursorColor: scheme.primary,
          onChanged: onChanged,
          onTap: onTap,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 14.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            isDense: isDense,
            contentPadding: const EdgeInsets.symmetric(horizontal: 15),
            border: InputBorder.none,
            prefixIcon: Icon(Icons.search, size: 19, color: scheme.onSurfaceVariant),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 40, minHeight: 44),
            suffixIcon: showClear
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 19),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                        width: 32, height: 44),
                    onPressed: onClear,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// 悬浮 Tab 气泡：把下方切换 Tab（[child]，通常为 [TabBar]）原位置用小气泡
/// 包围起来，观感与首页/我的页悬浮顶栏一致（玻璃胶囊 + 描边 + 圆角）。
class FloatingTabPill extends StatelessWidget {
  const FloatingTabPill({super.key, required this.child, this.height = 48});

  final Widget child;

  /// 气泡高度：默认 48 容纳 46 高 TabBar（含底部指示器留白）。
  final double height;

  @override
  Widget build(BuildContext context) {
    return FloatingGlassSurface(
      radius: height / 2,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          // 覆盖 TabBar 底部默认分隔线：气泡内只需指示器/文字，去掉那条
          // 既多余又和玻璃底冲突的横线（仅影响悬浮气泡，不改非悬浮形态）。
          child: Theme(
            data: Theme.of(context).copyWith(
              tabBarTheme: TabBarThemeData(
                dividerColor: Colors.transparent,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 二级页（搜索页/搜索结果页/本地页）共用的悬浮顶栏：一列——
/// 第一行 [返回玻璃钮] + [搜索胶囊(自适应宽)] + [右侧玻璃钮]；
/// 可选第二行 [悬浮 Tab 气泡]。整列悬浮在状态栏下方，取代页面固定 GlassTopBar。
/// 仅竖屏悬浮顶栏模式渲染。
class FloatingSearchTopBar extends StatelessWidget {
  const FloatingSearchTopBar({
    super.key,
    required this.field,
    this.onBack,
    this.action,
    this.tabPill,
    this.bottomPill,
  });

  /// 搜索输入/展示胶囊（[FloatingGlassSearchField] 或自定义）。
  final Widget field;

  /// 可选返回按钮；null 则不渲染（如面板模式无返回）。
  final VoidCallback? onBack;

  /// 可选右侧玻璃按钮（搜索按钮/文件夹按钮等）。
  final Widget? action;

  /// 可选第二行悬浮 Tab 气泡。
  final Widget? tabPill;

  /// 可选第三行悬浮气泡（如搜索结果页/榜单页的音源来源切换条）。
  final Widget? bottomPill;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (onBack != null) ...[
              BiliPaiIconButton(icon: Icons.arrow_back, onTap: onBack),
              const SizedBox(width: 10),
            ],
            Expanded(child: field),
            if (action != null) ...[
              const SizedBox(width: 10),
              action!,
            ],
          ],
        ),
        if (tabPill != null) ...[
          const SizedBox(height: 10),
          tabPill!,
        ],
        if (bottomPill != null) ...[
          const SizedBox(height: 10),
          bottomPill!,
        ],
      ],
    );
  }
}

/// 二级页悬浮顶栏通用骨架（竖屏悬浮顶栏模式）：[返回玻璃钮] + [标题胶囊] +
/// 右侧玻璃钮，可选底部附加条（搜索胶囊 / Tab 气泡）。供 [GlassTopBar] /
/// [FlatTopBar] 在悬浮模式下整条换装复用——总高度与固定形态逐像素一致
/// （状态栏 + kToolbarHeight + bottom.preferredSize.height），页面内容顶部
/// 避让零改动。
Widget floatingChromeBar(
  BuildContext context, {
  Widget? leading,
  required Widget title,
  List<Widget> actions = const [],
  PreferredSizeWidget? bottom,
}) {
  final statusBar = MediaQuery.paddingOf(context).top;
  final bottomH = bottom?.preferredSize.height ?? 0;
  // 返回钮 + 间距（leading 为 null 时为空，避免集合内 if 判空展开触发 lint）。
  final lead = leading == null
      ? const <Widget>[]
      : [
          _chromeGlassAction(context, leading),
          const SizedBox(width: 10),
        ];
  Widget? bottomRow;
  if (bottom is PageSearchBarBottom) {
    // 搜索胶囊行：44 高胶囊撑满宽度（与壳层悬浮顶栏搜索胶囊同口径），
    // 在原 band 高度内垂直居中，总高不变。
    bottomRow = SizedBox(
      height: bottomH,
      child: Align(
        alignment: Alignment.center,
        child: FloatingSearchBar(
          onTap: bottom.onTap,
          onRecognize: bottom.onRecognize,
        ),
      ),
    );
  } else if (bottom != null) {
    // TabBar 等附加条：悬浮 Tab 气泡原高包裹（收藏/反馈/榜单等页同款）。
    bottomRow = FloatingTabPill(height: bottomH, child: bottom);
  }
  return Padding(
    padding: EdgeInsets.fromLTRB(12, statusBar + 8, 12, 0),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 标题行：上浮 8 + 行高 48 = kToolbarHeight(56)，与固定形态总高逐像素
        // 一致；40/44 高胶囊在行内垂直居中。
        SizedBox(
          height: kToolbarHeight - 8,
          child: Row(
            children: [
              ...lead,
              BiliPaiPill(
                radius: 20,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: SizedBox(
                    height: 40,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: DefaultTextStyle(
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        child: title,
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              for (final a in actions) ...[
                const SizedBox(width: 10),
                _chromeGlassAction(context, a),
              ],
            ],
          ),
        ),
        ?bottomRow,
      ],
    ),
  );
}

/// 把固定顶栏的 leading/action 控件换装为玻璃圆钮（与壳层悬浮顶栏 40×40
/// 观感一致）：BackButton/IconButton 重建为 [BiliPaiIconButton]（保留原
/// 图标/tooltip/回调），其余自定义控件玻璃胶囊原样包裹（不强制尺寸防溢出）。
Widget _chromeGlassAction(BuildContext context, Widget w) {
  if (w is BackButton) {
    return BiliPaiIconButton(
      icon: Icons.arrow_back,
      onTap: w.onPressed ?? () => Navigator.of(context).maybePop(),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
    );
  }
  if (w is IconButton) {
    final ic = w.icon;
    return BiliPaiIconButton(
      icon: ic is Icon ? ic.icon : null,
      iconChild: ic is Icon ? null : ic,
      color: w.color ?? (ic is Icon ? ic.color : null),
      tooltip: w.tooltip,
      onTap: w.onPressed,
    );
  }
  if (w is SizedBox) return w;
  return BiliPaiPill(
    radius: 20,
    child: IconTheme(
      data: const IconThemeData(size: 20)
          .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      child: w,
    ),
  );
}
