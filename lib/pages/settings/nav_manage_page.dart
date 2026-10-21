import 'dart:async';

import 'package:flutter/gestures.dart'
    show DelayedMultiDragGestureRecognizer, MultiDragGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/haptics.dart';
import '../../src/core/settings.dart';
import '../../src/i18n/i18n.dart';
import '../../src/navigation/routes.dart';
import '../../src/widgets/glass_appbar.dart' show GlassTopBar;
import '../../src/widgets/glass_settings.dart' show frostedCardSurface;

/// 导航栏管理：竖屏/横屏导航页签排序（长按拖拽）+ 插件页签显隐。
/// 对齐桌面端"侧边栏管理"；首页/我的为固定页签不提供隐藏。
/// 版式与设置分类页统一：毛玻璃顶栏 + 红色分组标题 + frostedCardSurface 卡片。
/// 横屏设置面板内以 embedded 模式嵌入（裸内容，标题由面板宿主绘制）
class NavManagePage extends ConsumerStatefulWidget {
  const NavManagePage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<NavManagePage> createState() => _NavManagePageState();
}

class _NavManagePageState extends ConsumerState<NavManagePage> {
  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      // 与 SettingsCategoryPage.embedded 同款：裸 ListView，面板宿主出
      // 标题；PageStorageKey 记忆滚动位置（返回再进不弹回顶部）
      return ListView(
        key: const PageStorageKey('nav-manage'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _sectionHeader(context, tr('竖屏导航')),
          _navGroup(
            context,
            order:
                ref.watch(settingsProvider).valueOrNull?.navOrderPortrait ??
                kDefaultNavOrder,
            showPlugins:
                ref.watch(settingsProvider).valueOrNull?.navShowPlugins ??
                false,
            onReorder: (ids) =>
                ref.read(settingsProvider.notifier).setNavOrderPortrait(ids),
          ),
          _sectionHeader(context, tr('横屏导航')),
          _navGroup(
            context,
            order:
                ref.watch(settingsProvider).valueOrNull?.navOrderLandscape ??
                kDefaultNavOrder,
            showPlugins:
                ref.watch(settingsProvider).valueOrNull?.navShowPlugins ??
                false,
            onReorder: (ids) =>
                ref.read(settingsProvider.notifier).setNavOrderLandscape(ids),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
            child: Text(
              tr('长按拖动调整顺序，开关控制页签显隐'),
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      );
    }

    final settings = ref.watch(settingsProvider).valueOrNull;
    final showPlugins = settings?.navShowPlugins ?? false;

    // 与 SettingsCategoryPage 同款透出：ListView 铺满整屏、顶距写进自身
    // padding，内容可滚到悬浮顶栏后面
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              GlassTopBar.height(context),
              16,
              24 + MediaQuery.of(context).padding.bottom,
            ),
            children: [
              _sectionHeader(context, tr('竖屏导航')),
              _navGroup(
                context,
                order: settings?.navOrderPortrait ?? kDefaultNavOrder,
                showPlugins: showPlugins,
                onReorder: (ids) => ref
                    .read(settingsProvider.notifier)
                    .setNavOrderPortrait(ids),
              ),
              _sectionHeader(context, tr('横屏导航')),
              _navGroup(
                context,
                order: settings?.navOrderLandscape ?? kDefaultNavOrder,
                showPlugins: showPlugins,
                onReorder: (ids) => ref
                    .read(settingsProvider.notifier)
                    .setNavOrderLandscape(ids),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  tr('长按拖动调整顺序，开关控制页签显隐'),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(tr('导航栏管理')),
            ),
          ),
        ],
      ),
    );
  }

  // 与设置分类页 _sectionHeader 同款
  Widget _sectionHeader(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _navGroup(
    BuildContext context, {
    required List<String> order,
    required bool showPlugins,
    required ValueChanged<List<String>> onReorder,
  }) {
    final items = [
      for (final id in order)
        if (navItemsById[id] != null) navItemsById[id]!,
    ];
    // 与设置分类页 _CardGroup 同款卡片容器；行间分隔线与 ReorderableListView
    // 冲突（子项必须全带 key），沿用原布局不出线
    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 16,
      themeSlot: 'settings.group',
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide.none,
        ),
        child: ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          // 默认手柄关掉：行首自绘握把（立即拖动），整行长按兜底
          buildDefaultDragHandles: false,
          // 提起的行：卡片同款圆角与底色，柔和阴影随提起进度渐入，
          // 关掉 surfaceTint（默认染主色，拖起来整行发红）
          proxyDecorator: (child, index, animation) => AnimatedBuilder(
            animation: animation,
            builder: (context, built) {
              final scheme = Theme.of(context).colorScheme;
              return Material(
                color: scheme.surface,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(16),
                elevation:
                    Curves.easeInOut.transform(animation.value) * 6,
                shadowColor: scheme.shadow.withValues(alpha: 0.25),
                surfaceTintColor: Colors.transparent,
                child: built,
              );
            },
            child: child,
          ),
          onReorderItem: (oldIndex, newIndex) {
            // onReorderItem 已校正移除项对 newIndex 的偏移
            final ids = [...order];
            final moved = ids.removeAt(oldIndex);
            ids.insert(newIndex.clamp(0, ids.length), moved);
            onReorder(normalizeNavOrder(ids));
            triggerHaptic(HapticStrength.light);
          },
          children: [
            for (var i = 0; i < items.length; i++)
              _row(
                context,
                key: ValueKey(items[i].location),
                index: i,
                item: items[i],
                // optIn 页签出显隐开关（插件页签），固定页签只读展示
                showSwitch: items[i].optIn,
                switchValue: showPlugins,
                onSwitch: (v) =>
                    ref.read(settingsProvider.notifier).setNavShowPlugins(v),
              ),
          ],
        ),
      ),
    );
  }

  // 与设置分类页 _tile 同款行版式：握把 + 图标 + 16 间距 + 15 号标题，
  // trailing 收进 FittedBox 占行宽一半封顶
  Widget _row(
    BuildContext context, {
    required Key key,
    required int index,
    required BottomNavItem item,
    required bool showSwitch,
    required bool switchValue,
    required ValueChanged<bool> onSwitch,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return KeyedSubtree(
      key: key,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: LayoutBuilder(builder: (context, cons) {
            return Row(
              children: [
                // 行首拖拽握把：按住 300ms 起拖 + 震动反馈（对齐插件页）
                _HandleDragListener(
                  index: index,
                  child: Icon(
                    Icons.drag_indicator,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(width: 12),
                Icon(item.icon, color: scheme.onSurfaceVariant),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    navTitle(context, item),
                    style: (textTheme.bodyLarge ?? const TextStyle())
                        .copyWith(color: scheme.onSurface, fontSize: 15),
                  ),
                ),
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: cons.maxWidth * 0.5),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: showSwitch
                        ? Switch(value: switchValue, onChanged: onSwitch)
                        : Text(
                            tr('固定显示'),
                            style: (textTheme.bodySmall ?? const TextStyle())
                                .copyWith(color: scheme.onSurfaceVariant),
                          ),
                  ),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

/// 拖拽握把监听，对齐插件页 _HoldDragStartListener：按住 300ms 才起拖，
/// 起拖瞬间中档震动反馈；只有握把可发起拖动，行内其余触点不响应
class _HandleDragListener extends StatefulWidget {
  const _HandleDragListener({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_HandleDragListener> createState() => _HandleDragListenerState();
}

class _HandleDragListenerState extends State<_HandleDragListener> {
  Timer? _haptic;

  void _onDown(PointerDownEvent _) {
    _haptic?.cancel();
    _haptic = Timer(const Duration(milliseconds: 300), () {
      if (mounted) HapticFeedback.mediumImpact();
    });
  }

  void _clear() {
    _haptic?.cancel();
    _haptic = null;
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerUp: (_) => _clear(),
      onPointerCancel: (_) => _clear(),
      child: _DelayedDragRecognizerListener(
        index: widget.index,
        child: widget.child,
      ),
    );
  }
}

/// 300ms 延迟识别器（与震动计时同步），同插件页 _DelayedDragRecognizerListener
class _DelayedDragRecognizerListener
    extends ReorderableDelayedDragStartListener {
  const _DelayedDragRecognizerListener({
    required super.child,
    required super.index,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() {
    return DelayedMultiDragGestureRecognizer(
      delay: const Duration(milliseconds: 300),
      debugOwner: this,
    );
  }
}
