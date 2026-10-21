import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/haptics.dart';
import '../../src/core/settings.dart';
import '../../src/i18n/i18n.dart';
import '../../src/navigation/routes.dart';
import '../../src/widgets/flat_top_bar.dart';

/// 导航栏管理：竖屏/横屏导航页签排序（长按拖拽）+ 插件页签显隐。
/// 对齐桌面端"侧边栏管理"；首页/我的为固定页签不提供隐藏
class NavManagePage extends ConsumerStatefulWidget {
  const NavManagePage({super.key});

  @override
  ConsumerState<NavManagePage> createState() => _NavManagePageState();
}

class _NavManagePageState extends ConsumerState<NavManagePage> {
  static final Map<String, BottomNavItem> _byId = {
    'home': bottomNavItems[0],
    'mine': bottomNavItems[1],
    'plugin': pluginsNavItem,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider).valueOrNull;
    final showPlugins = settings?.navShowPlugins ?? false;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FlatTopBar(
              title: tr('导航栏管理'),
              backgroundColor: scheme.surface,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _NavHint(text: tr('长按拖动调整顺序，开关控制页签显隐')),
                  _navGroup(
                    context,
                    title: tr('竖屏导航'),
                    order:
                        settings?.navOrderPortrait ?? kDefaultNavOrder,
                    showPlugins: showPlugins,
                    onReorder: (ids) => ref
                        .read(settingsProvider.notifier)
                        .setNavOrderPortrait(ids),
                  ),
                  const SizedBox(height: 20),
                  _navGroup(
                    context,
                    title: tr('横屏导航'),
                    order:
                        settings?.navOrderLandscape ?? kDefaultNavOrder,
                    showPlugins: showPlugins,
                    onReorder: (ids) => ref
                        .read(settingsProvider.notifier)
                        .setNavOrderLandscape(ids),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navGroup(
    BuildContext context, {
    required String title,
    required List<String> order,
    required bool showPlugins,
    required ValueChanged<List<String>> onReorder,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final items = [
      for (final id in order)
        if (_byId[id] != null) _byId[id]!,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
              letterSpacing: 0.5,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: true,
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
                  item: items[i],
                  showSwitch: items[i].branchIndex == 2,
                  switchValue: showPlugins,
                  onSwitch: (v) => ref
                      .read(settingsProvider.notifier)
                      .setNavShowPlugins(v),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context, {
    required Key key,
    required BottomNavItem item,
    required bool showSwitch,
    required bool switchValue,
    required ValueChanged<bool> onSwitch,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return KeyedSubtree(
      key: key,
      child: Row(
        children: [
          Expanded(
            child: ListTile(
              leading: Icon(item.icon, color: scheme.onSurfaceVariant),
              title: Text(
                navTitle(context, item),
                style: const TextStyle(fontSize: 14),
              ),
              dense: true,
            ),
          ),
          if (showSwitch)
            Switch(value: switchValue, onChanged: onSwitch)
          else
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                tr('固定显示'),
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavHint extends StatelessWidget {
  const _NavHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}
