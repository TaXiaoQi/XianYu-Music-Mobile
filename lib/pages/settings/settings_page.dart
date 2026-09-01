import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/developer_mode.dart';
import '../../src/navigation/shell.dart'
    show landscapeSettingsCategoryProvider;
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/landscape_page_fade.dart';
import '../../src/i18n/i18n.dart';
import '../../src/responsive/landscape.dart';
import '../about/about_page.dart';
import '../feedback/feedback_page.dart';
import '../plugin/plugin_page.dart';
import 'account_settings_page.dart';
import 'settings_category_page.dart';

/// 设置导航页：浅白底 + 纯白分类卡片。
///
/// 竖屏：分类列表，点入详情（原行为）。
/// 横屏：master-detail 平行布局 —— 左侧分类导航、右侧对应详情面板直嵌，无需跳页。
///
/// 本页为二级推入页（从「我的」页菜单与首页顶栏进入）。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// 设置搜索关键字；非空时列表区切换为搜索结果。
  String _query = '';
  final _searchCtrl = TextEditingController();

  /// 横屏 master-detail 左侧分类导航宽度（默认 260，可拖动分割线调整）。
  double _navWidth = 260;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDeveloperMode = ref.watch(developerModeProvider);
    final groups = _buildGroups(isDeveloperMode);

    // 横屏重排为 master-detail（左导航 + 右内嵌详情），两套 UI 完全分开。
    return LandscapeGate(
      portrait: _buildPortrait(context, groups),
      landscape: _buildLandscape(context, groups),
    );
  }

  Widget _buildPortrait(BuildContext context, List<(String, List<_CategoryEntry>)> groups) {
    // 搜索框并入顶栏 bottom：上下留边对齐我的页顶栏搜索栏（mine_page `_TopBarSearchSlot` 用 fromLTRB(18,2,18,12)），与首页/我的页/搜索页同款对比色。
    final searchBox = PreferredSize(
      preferredSize: const Size.fromHeight(54),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
        child: _buildSearchBox(context),
      ),
    );
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 内容列表：顶部预留顶栏（含搜索框）高度，静止时位于毛玻璃下方，上拉时内容滑入顶栏被高斯模糊。
          // 底部避让：二级页底栏隐藏，仅迷你播放条悬浮在距底 18px 处（高 58）。
          // 包 RepaintBoundary 隔离内部重绘，避免列表重排波及背景层。
          RepaintBoundary(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                GlassTopBar.height(context, bottom: searchBox) + 12,
                16,
                92 + MediaQuery.of(context).padding.bottom,
              ),
              children: [
                if (_query.trim().isEmpty)
                  ..._buildCategorySections(context, groups)
                else
                  ..._buildSearchResults(context),
              ],
            ),
          ),
          // 顶栏高斯模糊毛玻璃（二级页带返回按钮），底部内嵌搜索框。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(tr('设置')),
              bottom: searchBox,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCategorySections(
      BuildContext context, List<(String, List<_CategoryEntry>)> groups) {
    return [
      for (final (header, entries) in groups) ...[
        _sectionHeader(context, header),
        _CardGroup(
          children: [
            for (var i = 0; i < entries.length; i++)
              _CategoryTile(entry: entries[i]),
          ],
        ),
      ],
    ];
  }

  Widget _buildSearchBox(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: searchBoxFill(context, ref),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: tr('搜索设置'),
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
              ),
            ),
          ),
          if (_query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 40),
              onPressed: () {
                _searchCtrl.clear();
                setState(() => _query = '');
              },
            ),
        ],
      ),
    );
  }

  List<Widget> _buildSearchResults(
    BuildContext context, {
    bool compact = false,
    void Function(_SearchItem)? onTapOverride,
  }) {
    final results = _searchSettings(_query.trim(), context);
    if (results.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return [
        Padding(
          padding: const EdgeInsets.only(top: 80),
          child: Column(
            children: [
              Icon(Icons.search_off, size: 40, color: scheme.outline),
              const SizedBox(height: 8),
              Text(
                tr('未找到相关设置'),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ];
    }
    return [
      _sectionHeader(context, tr('搜索结果'), compact: compact),
      _CardGroup(
        children: [
          for (final r in results)
            _SearchResultTile(
              item: r,
              compact: compact,
              onTapOverride:
                  onTapOverride == null ? null : () => onTapOverride(r),
            ),
        ],
      ),
    ];
  }

  /// 检索设置选项：对静态索引做归一化 + 分词 + 打分排序（对齐桌面端 searchIndex）。
  List<_SearchItem> _searchSettings(String q, BuildContext context) {
    final qn = q.trim().toLowerCase();
    if (qn.isEmpty) return const [];
    final tokens =
        qn.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return const [];

    final scored = <(int, _SearchItem)>[];
    for (final item in _settingsSearchItems) {
      final hay =
          '${tr(item.label)} ${tr(item.section)} ${tr(item.categoryName)} ${item.keywords}'
              .toLowerCase();
      if (!tokens.every((t) => hay.contains(t))) continue;
      final label = tr(item.label).toLowerCase();
      int score;
      if (label == qn) {
        score = 0;
      } else if (label.startsWith(qn)) {
        score = 1;
      } else if (label.contains(qn)) {
        score = 2;
      } else if (tr(item.section).toLowerCase().contains(qn)) {
        score = 3;
      } else if (tr(item.categoryName).toLowerCase().contains(qn)) {
        score = 4;
      } else {
        score = 5;
      }
      scored.add((score, item));
    }
    scored.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      if (c != 0) return c;
      return tr(a.$2.label).compareTo(tr(b.$2.label));
    });
    return scored.map((e) => e.$2).take(30).toList();
  }

  /// 横屏 master-detail：左侧分类导航（含选中态），右侧直嵌当前分类详情。
  Widget _buildLandscape(BuildContext context, List<(String, List<_CategoryEntry>)> groups) {
    // 选中分类走全局 provider：翻转重定向（停在设置二级页进横屏）由 shell
    // 先写入目标分类再 pop 揭开本页，master-detail 直接落在对应分类。
    final sel = ref.watch(landscapeSettingsCategoryProvider) ?? '/settings/account';
    final detail = _detailFor(sel);
    final selTitle = _titleOf(groups, sel) ?? tr('设置');

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左：分类导航（透明继承外层页面底色，与右侧详情一致，避免割裂）
          Material(
            color: Colors.transparent,
            child: SizedBox(
              width: _navWidth,
              // 只避让顶部（状态栏）与左侧（摄像头在左列时），右/下 padding 属右列，
              // 否则翻转屏幕后右侧挖孔的 padding 会误作用到左列，导航条右侧空出一节。
              child: SafeArea(
                top: true,
                bottom: false,
                left: true,
                right: false,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                      child: Row(
                        children: [
                          const BackButton(),
                          Text(
                            tr('设置'),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 横屏无底部栏，迷你条停靠右下，左列底部无需大留白，仅留少量安全间距。
                    const SizedBox(height: 6),
                    // 搜索框：与竖屏/首页/我的页/搜索页同款对比色。
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: _buildSearchBox(context),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.fromLTRB(
                          8,
                          0,
                          8,
                          24 + MediaQuery.of(context).padding.bottom,
                        ),
                        children: [
                          if (_query.trim().isEmpty)
                            for (final (header, entries) in groups) ...[
                              _sectionHeader(context, header, compact: true),
                              _CardGroup(
                                children: [
                                  for (var i = 0; i < entries.length; i++)
                                    _CategoryTile(
                                      entry: entries[i],
                                      compact: true,
                                      selected: _isEmbeddable(entries[i].path) &&
                                          sel == entries[i].path,
                                      onTapOverride: _isEmbeddable(entries[i].path)
                                          ? () => ref
                                              .read(landscapeSettingsCategoryProvider
                                                  .notifier)
                                              .state = entries[i].path
                                          : null,
                                    ),
                                ],
                              ),
                            ]
                          else
                            // 横屏搜索结果：可嵌入分类直接切换右侧，其余整页跳转。
                            ..._buildSearchResults(
                              context,
                              compact: true,
                              onTapOverride: (r) {
                                if (_isEmbeddable(r.path)) {
                                  ref
                                      .read(landscapeSettingsCategoryProvider
                                          .notifier)
                                      .state = r.path;
                                } else {
                                  context.push(r.path);
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _SettingsDivider(
            onDragUpdate: (dx) {
              final screenW = MediaQuery.sizeOf(context).width;
              setState(() {
                // 最小即当前默认宽度 260，最远只能划到屏幕中部（对半）。
                _navWidth = (_navWidth + dx).clamp(260.0, screenW * 0.5);
              });
            },
          ),
          // 右：当前分类详情（薄顶栏 + 嵌入体，切换带淡入淡出）
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // plugin 嵌入时自带纯色标题条（含音源操作按钮），外层不再渲染；
                // 其余分类（含 feedback，TabBar 在标题条之下）统一由外层渲染标题条。
                if (sel != '/plugin')
                  Container(
                    height: GlassTopBar.height(context),
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.only(left: 18),
                    child: Text(
                      selTitle,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                Expanded(
                  // 与横屏壳层右侧面板同一套桌面版 page-fade out-in（旧分类
                  // 淡出微上移缩小 → 新分类自下方淡入），替换原 AnimatedSwitcher
                  // 交叉淡入（切换观感与壳层面板不一致、近似硬切）。
                  child: LandscapePageFade(
                    open: detail != null,
                    trigger: sel,
                    child: detail,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 可直嵌进 master-detail 右侧的分类详情；其余（调试）仍整页跳转。
  Widget? _detailFor(String path) {
    return switch (path) {
      '/settings/account' => const AccountSettingsPage(embedded: true),
      '/settings/general' => const SettingsCategoryPage(
          category: SettingsCategory.general, embedded: true),
      '/settings/appearance' => const SettingsCategoryPage(
          category: SettingsCategory.appearance, embedded: true),
      '/settings/lyrics' => const SettingsCategoryPage(
          category: SettingsCategory.lyrics, embedded: true),
      '/settings/playback' => const SettingsCategoryPage(
          category: SettingsCategory.playback, embedded: true),
      '/settings/download' => const SettingsCategoryPage(
          category: SettingsCategory.download, embedded: true),
      '/settings/advanced' => const SettingsCategoryPage(
          category: SettingsCategory.advanced, embedded: true),
      '/plugin' => const PluginPage(embedded: true),
      '/feedback' => const FeedbackPage(embedded: true),
      '/about' => const AboutPage(embedded: true),
      _ => null,
    };
  }

  bool _isEmbeddable(String path) => _detailFor(path) != null;

  String? _titleOf(List<(String, List<_CategoryEntry>)> groups, String path) {
    for (final (_, entries) in groups) {
      for (final e in entries) {
        if (e.path == path) return e.title;
      }
    }
    return null;
  }

  /// 构建分类分组；开发者模式开启时在「系统」分组末尾追加「调试」入口（对齐桌面端）。
  List<(String, List<_CategoryEntry>)> _buildGroups(bool isDeveloperMode) {
    final groups = <(String, List<_CategoryEntry>)>[..._groups];
    if (isDeveloperMode) {
      final systemIndex = groups.indexWhere((g) => g.$1 == '系统');
      if (systemIndex >= 0) {
        final (header, entries) = groups[systemIndex];
        groups[systemIndex] = (
          header,
          [
            ...entries,
            _CategoryEntry(
              tr('调试'),
              Icons.bug_report_outlined,
              tr('调试模式：弹窗测试、退出调试'),
              '/debug',
            ),
          ],
        );
      }
    }
    return groups;
  }

  Widget _sectionHeader(BuildContext context, String title,
          {bool compact = false}) =>
      Padding(
        padding: EdgeInsets.fromLTRB(compact ? 12 : 16, 20, compact ? 12 : 16, 8),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  /// 分组：标题 -> 分类条目。每个条目的 path 指向分类详情页或既有页面。
  static List<(String, List<_CategoryEntry>)> get _groups => [
    (
      tr('账号'),
      [
        _CategoryEntry(
          tr('账号'),
          Icons.account_circle_outlined,
          tr('服务端设置、手动同步、自动同步'),
          '/settings/account',
        ),
      ],
    ),
    (
      tr('偏好'),
      [
        _CategoryEntry(tr('常规'), Icons.tune, tr('语言、反馈、存储'), '/settings/general'),
        _CategoryEntry(
          tr('外观'),
          Icons.palette_outlined,
          tr('主题、主题色、壁纸、液态玻璃、导航栏'),
          '/settings/appearance',
        ),
        _CategoryEntry(
          tr('歌词'),
          Icons.lyrics_outlined,
          tr('歌词显示、悬浮歌词窗'),
          '/settings/lyrics',
        ),
      ],
    ),
    (
      tr('在线与音源'),
      [
        _CategoryEntry(
          tr('音源'),
          Icons.library_music_outlined,
          tr('插件音源：导入、启用、更新、卸载'),
          '/plugin',
        ),
        _CategoryEntry(
          tr('播放'),
          Icons.play_circle_outline,
          tr('音量、双击播放、在线音质、输出'),
          '/settings/playback',
        ),
        _CategoryEntry(
          tr('下载'),
          Icons.download_outlined,
          tr('音质、路径、并发、嵌入'),
          '/settings/download',
        ),
      ],
    ),
    (
      tr('系统'),
      [
        _CategoryEntry(
          tr('高级设置'),
          Icons.settings_suggest_outlined,
          tr('屏幕常亮、应用备份、预测返回'),
          '/settings/advanced',
        ),
        _CategoryEntry(
          tr('意见反馈'),
          Icons.feedback_outlined,
          tr('向我们反馈问题与建议'),
          '/feedback',
        ),
        _CategoryEntry(tr('关于'), Icons.info_outline, tr('版本信息、项目主页'), '/about'),
      ],
    ),
  ];
}

/// 设置页 master-detail 的可拖动分割条：横跨全高的窄 hit 区，静置为细分隔线。
class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider({required this.onDragUpdate});

  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDragUpdate(d.delta.dx),
      child: SizedBox(
        width: 28,
        child: Center(
          child: Container(
            width: 1,
            height: 56,
            color: scheme.onSurface.withValues(alpha: 0.16),
          ),
        ),
      ),
    );
  }
}

class _CategoryEntry {
  const _CategoryEntry(this.title, this.icon, this.subtitle, this.path);
  final String title;
  final IconData icon;
  final String subtitle;
  final String path;
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.entry,
    this.onTapOverride,
    this.selected = false,
    this.compact = false,
  });

  final _CategoryEntry entry;
  final VoidCallback? onTapOverride;
  final bool selected;

  /// 紧凑模式（横屏左列）：收窄 ListTile 水平内边距，让内容更贴近卡片边缘。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      // 横屏 compact：标准 ListTile 行高（无 subtitle 高 56），与右侧详情分组卡片的 ListTile 完全一致，保证左右卡片高度统一
      dense: !compact,
      contentPadding: compact
          ? const EdgeInsets.symmetric(horizontal: 12)
          : null,
      selected: selected,
      selectedTileColor: scheme.primary.withValues(alpha: 0.10),
      selectedColor: scheme.primary,
      leading: Icon(
        entry.icon,
        color: selected ? scheme.primary : null,
      ),
      title: Text(entry.title),
      subtitle: compact
          ? null
          : Text(
              entry.subtitle,
              style: Theme.of(context).textTheme.bodySmall,
            ),
      onTap: onTapOverride ?? () => context.push(entry.path),
    );
  }
}

/// 分组圆角卡片包裹容器。
class _CardGroup extends ConsumerWidget {
  const _CardGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i != children.length - 1) {
        items.add(
          Divider(
            height: 1,
            indent: 52,
            endIndent: 16,
            thickness: 0.5,
            color: scheme.onSurface.withValues(alpha: 0.08),
          ),
        );
      }
    }

    // 毛玻璃表面：跟随全局开关，与顶栏底栏一致。
    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 16,
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide.none,
        ),
        child: Column(children: items),
      ),
    );
  }
}

/// 设置搜索索引项：label/section/categoryName 为 tr key，keywords 为同义词。
class _SearchItem {
  const _SearchItem({
    required this.label,
    required this.section,
    required this.path,
    required this.categoryName,
    this.keywords = '',
    this.isCategory = false,
  });

  final String label;
  final String section;
  final String path;
  final String categoryName;
  final String keywords;
  final bool isCategory;
}

/// 设置搜索结果行。
class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.item,
    this.compact = false,
    this.onTapOverride,
  });

  final _SearchItem item;
  final bool compact;
  final VoidCallback? onTapOverride;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: compact,
      contentPadding: compact
          ? const EdgeInsets.symmetric(horizontal: 12)
          : null,
      leading: Icon(
        item.isCategory ? Icons.category_outlined : Icons.settings_outlined,
        size: 20,
        color: scheme.primary,
      ),
      title: Text(tr(item.label)),
      subtitle: Text(
        item.isCategory
            ? tr('设置分类')
            : '${tr(item.section)} · ${tr(item.categoryName)}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: onTapOverride ?? () => context.push(item.path),
    );
  }
}

/// 设置检索静态索引（对齐桌面端 searchIndex.ts）：分类 + 各分类页设置项。
const _settingsSearchItems = <_SearchItem>[
  // 分类
  _SearchItem(label: '账号', section: '设置分类', path: '/settings/account', categoryName: '账号', isCategory: true, keywords: '账户 登录 服务端'),
  _SearchItem(label: '常规', section: '设置分类', path: '/settings/general', categoryName: '常规', isCategory: true, keywords: '语言 反馈 存储'),
  _SearchItem(label: '外观', section: '设置分类', path: '/settings/appearance', categoryName: '外观', isCategory: true, keywords: '主题 壁纸 材质 皮肤 皮肤配色'),
  _SearchItem(label: '歌词', section: '设置分类', path: '/settings/lyrics', categoryName: '歌词', isCategory: true, keywords: '悬浮歌词 卡拉OK 歌词页'),
  _SearchItem(label: '播放', section: '设置分类', path: '/settings/playback', categoryName: '播放', isCategory: true, keywords: '音量 音质 输出 播放设置'),
  _SearchItem(label: '下载', section: '设置分类', path: '/settings/download', categoryName: '下载', isCategory: true, keywords: '路径 音质 歌词'),
  _SearchItem(label: '高级设置', section: '设置分类', path: '/settings/advanced', categoryName: '高级设置', isCategory: true, keywords: '备份 日志 常亮 高级'),
  _SearchItem(label: '音源', section: '设置分类', path: '/plugin', categoryName: '音源', isCategory: true, keywords: '插件 音乐源 落雪'),
  _SearchItem(label: '意见反馈', section: '设置分类', path: '/feedback', categoryName: '意见反馈', isCategory: true, keywords: '反馈 建议 问题'),
  _SearchItem(label: '关于', section: '设置分类', path: '/about', categoryName: '关于', isCategory: true, keywords: '版本 信息 项目 主页'),
  _SearchItem(label: '调试', section: '设置分类', path: '/debug', categoryName: '调试', isCategory: true, keywords: 'debug 测试 弹窗'),

  // 常规
  _SearchItem(label: '语言', section: '语言', path: '/settings/general', categoryName: '常规', keywords: '简体中文 繁體中文 English 跟随系统'),
  _SearchItem(label: '触觉反馈力度', section: '反馈', path: '/settings/general', categoryName: '常规', keywords: '震动 力度 手感'),
  _SearchItem(label: '检测更新模式', section: '检测更新', path: '/settings/general', categoryName: '常规', keywords: '启动 检查 版本 更新'),
  _SearchItem(label: '存储设置', section: '存储空间', path: '/settings/general', categoryName: '常规', keywords: '缓存 空间 清理'),

  // 外观
  _SearchItem(label: '主题模式', section: '主题', path: '/settings/appearance', categoryName: '外观', keywords: '深色 浅色 跟随系统 暗色 明亮'),
  _SearchItem(label: '主题色', section: '主题', path: '/settings/appearance', categoryName: '外观', keywords: '品牌色 强调色 颜色 HEX 预设 自定义 红色'),
  _SearchItem(label: '壁纸中心', section: '主题', path: '/wallpaper', categoryName: '外观', keywords: '自定义背景 动态壁纸 图片'),
  _SearchItem(label: '毛玻璃材质', section: '材质', path: '/settings/appearance', categoryName: '外观', keywords: '磨砂 模糊 frosted 透明'),
  _SearchItem(label: '毛玻璃效果', section: '材质', path: '/settings/appearance', categoryName: '外观', keywords: '模糊强度 档位'),
  _SearchItem(label: '液态玻璃', section: '材质', path: '/settings/appearance', categoryName: '外观', keywords: 'liquid 悬浮底栏 shader 折射'),
  _SearchItem(label: '液态玻璃效果', section: '材质', path: '/settings/appearance', categoryName: '外观', keywords: '渲染强度 耗电'),
  _SearchItem(label: '导航栏位置', section: '导航栏与底栏', path: '/settings/appearance', categoryName: '外观', keywords: '底部 侧边'),
  _SearchItem(label: '悬浮式底栏', section: '导航栏与底栏', path: '/settings/appearance', categoryName: '外观', keywords: '悬浮 底栏'),
  _SearchItem(label: '悬浮搜索框', section: '导航栏与底栏', path: '/settings/appearance', categoryName: '外观', keywords: '搜索 悬浮 首页'),
  _SearchItem(label: '侧边栏展开方向', section: '导航栏与底栏', path: '/settings/appearance', categoryName: '外观', keywords: '抽屉 方向'),
  _SearchItem(label: '播放页样式', section: '播放页', path: '/settings/appearance', categoryName: '外观', keywords: '正在播放 布局 风格'),
  _SearchItem(label: '播放页液态玻璃', section: '播放页', path: '/settings/appearance', categoryName: '外观', keywords: '控制卡 液态'),
  _SearchItem(label: '列表大小', section: '列表', path: '/settings/appearance', categoryName: '外观', keywords: '歌曲 歌手 专辑 歌单 尺寸'),

  // 歌词
  _SearchItem(label: '显示翻译', section: '歌词显示', path: '/settings/lyrics', categoryName: '歌词', keywords: '翻译 translation'),
  _SearchItem(label: '逐字动效', section: '歌词显示', path: '/settings/lyrics', categoryName: '歌词', keywords: '卡拉OK 逐字 动画'),
  _SearchItem(label: '悬浮歌词窗', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '悬浮 卡拉OK 逐字 歌词窗'),
  _SearchItem(label: '文字颜色', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '歌词颜色'),
  _SearchItem(label: '不透明度', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '透明度 opacity'),
  _SearchItem(label: '字号', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '字体大小'),
  _SearchItem(label: '副行字号', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '字体'),
  _SearchItem(label: '使用歌词字体', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '字体 播放页'),
  _SearchItem(label: '显示罗马音', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '罗马音 romaji'),
  _SearchItem(label: '显示背景歌词', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '背景 歌词'),
  _SearchItem(label: '暂停时隐藏', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '隐藏 暂停'),
  _SearchItem(label: '横屏时隐藏', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '横屏 隐藏'),
  _SearchItem(label: '宽度', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '宽'),
  _SearchItem(label: '水平位置', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '左右 位置'),
  _SearchItem(label: '垂直位置', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '上下 位置'),
  _SearchItem(label: '锁定位置', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '锁定 拖动'),
  _SearchItem(label: '重置位置', section: '悬浮歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '重置 还原'),
  _SearchItem(label: '车机歌词', section: '车机歌词', path: '/settings/lyrics', categoryName: '歌词', keywords: '通知栏 锁屏 车机 蓝牙 状态栏'),

  // 播放
  _SearchItem(label: '音量', section: '播放', path: '/settings/playback', categoryName: '播放', keywords: 'volume 声音'),
  _SearchItem(label: '双击播放歌曲', section: '播放', path: '/settings/playback', categoryName: '播放', keywords: '双击 单击 播放'),
  _SearchItem(label: '音量平衡', section: '音量平衡', path: '/settings/playback', categoryName: '播放', keywords: 'ReplayGain 响度 标准化'),
  _SearchItem(label: '整体增益偏移', section: '音量平衡', path: '/settings/playback', categoryName: '播放', keywords: 'ReplayGain dB 增益'),
  _SearchItem(label: '防削波破音保护', section: '音量平衡', path: '/settings/playback', categoryName: '播放', keywords: '峰值 clipping 破音'),
  _SearchItem(label: '在线默认音质', section: '在线音质', path: '/settings/playback', categoryName: '播放', keywords: '无损 Hi-Res 320k 音质'),
  _SearchItem(label: '起播失败行为', section: '在线音质', path: '/settings/playback', categoryName: '播放', keywords: '播放失败 换源'),
  _SearchItem(label: '音质回退行为', section: '在线音质', path: '/settings/playback', categoryName: '播放', keywords: '降级 回退 音质'),
  _SearchItem(label: '播放失败自动换源', section: '在线音质', path: '/settings/playback', categoryName: '播放', keywords: '换源 搜索 播放'),
  _SearchItem(label: '分享链接有效时长', section: '分享', path: '/settings/playback', categoryName: '播放', keywords: '分享 过期'),
  _SearchItem(label: '分享链接播放失败行为', section: '分享', path: '/settings/playback', categoryName: '播放', keywords: '分享 失败'),
  _SearchItem(label: '输出设备', section: '输出', path: '/settings/playback', categoryName: '播放', keywords: 'USB DAC 声卡 扬声器 耳机'),
  _SearchItem(label: 'USB 独占输出 (Bit-perfect)', section: '输出', path: '/settings/playback', categoryName: '播放', keywords: '独占 绕过混音 位完美'),
  _SearchItem(label: 'Bit-perfect 直出', section: '输出', path: '/settings/playback', categoryName: '播放', keywords: '位完美 直出 DAC 独占'),
  _SearchItem(label: 'DSD 原生直出', section: '输出', path: '/settings/playback', categoryName: '播放', keywords: 'DSD DoP 直通 独占'),

  // 下载
  _SearchItem(label: '下载路径', section: '下载', path: '/settings/download', categoryName: '下载', keywords: '保存 文件夹 目录'),
  _SearchItem(label: '下载音质', section: '下载', path: '/settings/download', categoryName: '下载', keywords: '无损 Hi-Res 320k'),
  _SearchItem(label: '同时下载歌词', section: '下载', path: '/settings/download', categoryName: '下载', keywords: '歌词 lrc'),
  _SearchItem(label: '批量并发数', section: '下载', path: '/settings/download', categoryName: '下载', keywords: '并发 数量'),
  _SearchItem(label: '文件名样式', section: '下载', path: '/settings/download', categoryName: '下载', keywords: '命名 歌手 歌名'),
  _SearchItem(label: '覆盖同名文件', section: '下载', path: '/settings/download', categoryName: '下载', keywords: '覆盖 重复 序号'),
  _SearchItem(label: '下载管理', section: '下载', path: '/download', categoryName: '下载', keywords: '下载任务 列表'),
  _SearchItem(label: '嵌入元数据', section: '下载后嵌入', path: '/settings/download', categoryName: '下载', keywords: '标签 tag 写入'),
  _SearchItem(label: '嵌入歌词', section: '下载后嵌入', path: '/settings/download', categoryName: '下载', keywords: '内嵌 歌词'),
  _SearchItem(label: '嵌入封面', section: '下载后嵌入', path: '/settings/download', categoryName: '下载', keywords: '封面 图片'),

  // 高级设置
  _SearchItem(label: '导出应用备份', section: '应用备份', path: '/settings/advanced', categoryName: '高级设置', keywords: '备份 导出 恢复'),
  _SearchItem(label: '导入应用备份', section: '应用备份', path: '/settings/advanced', categoryName: '高级设置', keywords: '备份 导入 恢复'),
  _SearchItem(label: '导出全部日志', section: '日志', path: '/settings/advanced', categoryName: '高级设置', keywords: '日志 导出'),
  _SearchItem(label: '导出错误日志', section: '日志', path: '/settings/advanced', categoryName: '高级设置', keywords: '错误 日志 故障'),
  _SearchItem(label: '清理日志', section: '日志', path: '/settings/advanced', categoryName: '高级设置', keywords: '删除 清空 日志'),
  _SearchItem(label: '保持屏幕常亮', section: '系统', path: '/settings/advanced', categoryName: '高级设置', keywords: '屏幕 常亮 唤醒'),
  _SearchItem(label: '预测返回手势', section: '导航', path: '/settings/advanced', categoryName: '高级设置', keywords: '返回 手势 预测'),

  // 账号
  _SearchItem(label: '账号状态', section: '账号状态', path: '/settings/account', categoryName: '账号', keywords: '登录 用户 资料 退出'),
  _SearchItem(label: '服务器 API', section: '服务端设置', path: '/settings/account', categoryName: '账号', keywords: '后端 地址 服务器 根地址'),
  _SearchItem(label: '服务器密钥', section: '服务端设置', path: '/settings/account', categoryName: '账号', keywords: '密钥 签名 签名密钥'),
  _SearchItem(label: '上传歌单', section: '上传', path: '/settings/account', categoryName: '账号', keywords: '同步 云端 歌单'),
  _SearchItem(label: '上传收藏', section: '上传', path: '/settings/account', categoryName: '账号', keywords: '同步 云端 收藏'),
  _SearchItem(label: '上传插件', section: '上传', path: '/settings/account', categoryName: '账号', keywords: '同步 插件'),
  _SearchItem(label: '上传本地设置', section: '上传', path: '/settings/account', categoryName: '账号', keywords: '同步 设置 偏好'),
  _SearchItem(label: '手动同步', section: '手动同步', path: '/settings/account', categoryName: '账号', keywords: '上传 下载 云端 同步'),
  _SearchItem(label: '启用自动同步', section: '自动同步', path: '/settings/account', categoryName: '账号', keywords: '定时 后台 同步'),
  _SearchItem(label: '同步间隔', section: '自动同步', path: '/settings/account', categoryName: '账号', keywords: '小时 分钟 自动 间隔'),
  _SearchItem(label: '繁忙延后上限', section: '自动同步', path: '/settings/account', categoryName: '账号', keywords: '繁忙 延后 延迟'),
];