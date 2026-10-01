import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/i18n/i18n.dart';
import '../../src/theme/remote_theme.dart';
import '../../src/theme/remote_theme_store.dart';
import '../../src/theme/remote_theme_tile.dart';
import '../../src/theme/theme_package.dart';
import '../../src/theme/theme_store.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';

/// 主题中心：本地导入 + 应用，并接入广场与我的上传。
/// 「我的下载」已按产品决定删除——主题层无来源信息，做出来只会是「本地」的重复页。
class ThemeCenterPage extends ConsumerStatefulWidget {
  const ThemeCenterPage({super.key});

  @override
  ConsumerState<ThemeCenterPage> createState() => _ThemeCenterPageState();
}

class _ThemeCenterPageState extends ConsumerState<ThemeCenterPage>
    with SingleTickerProviderStateMixin {
  bool _busy = false;

  late TabController _tab;
  bool _tabReady = false;
  bool? _lastLoggedIn;

  // 未登录只留「本地」单 tab,广场/我的上传/我的下载需登录(与壁纸中心同口径)
  TabController _buildTab(bool loggedIn) =>
      TabController(length: loggedIn ? 4 : 1, vsync: this);

  @override
  void dispose() {
    if (_tabReady) _tab.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (files.isEmpty) return;
      final file = files.first;

      String content;
      final path = file.path ?? '';
      if (path.isNotEmpty && File(path).existsSync()) {
        content = await File(path).readAsString();
      } else {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          if (mounted) showXianYuToast(context, tr('无法读取所选文件'));
          return;
        }
        content = utf8.decode(bytes);
      }

      final pkg =
          await ref.read(themeLibraryProvider.notifier).importJson(content);
      if (!mounted) return;
      showXianYuToast(
        context,
        pkg == null
            ? tr('主题包格式不正确（需 mobile 版 v2）')
            : tr('已导入《{name}》', {'name': pkg.name}),
      );
    } catch (e) {
      if (mounted) showXianYuToast(context, tr('导入失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _activate(ThemePackage pkg) async {
    await ref.read(themeLibraryProvider.notifier).activate(pkg.id);
    if (!mounted) return;
    showXianYuToast(
      context,
      pkg.wallpaperId == null
          ? tr('已应用《{name}》', {'name': pkg.name})
          : tr('已应用《{name}》·该主题推荐了一张壁纸，可在壁纸中心应用',
              {'name': pkg.name}),
    );
  }

  Future<void> _deactivate() async {
    await ref.read(themeLibraryProvider.notifier).deactivate();
    if (mounted) showXianYuToast(context, tr('已取消主题'));
  }

  Future<void> _remove(ThemePackage pkg) async {
    await ref.read(themeLibraryProvider.notifier).remove(pkg.id);
    if (mounted) showXianYuToast(context, tr('已删除《{name}》', {'name': pkg.name}));
  }

  PreferredSizeWidget get _tabBar => TabBar(
        controller: _tab,
        // 固定不滚动,tab 等宽平均分布(与壁纸中心同口径)
        isScrollable: false,
        tabs: [
          Tab(text: tr('本地')),
          if (_lastLoggedIn == true) ...[
            Tab(text: tr('广场')),
            Tab(text: tr('我的上传')),
            Tab(text: tr('我的下载')),
          ],
        ],
      );

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(authProvider.select((a) => a.isLoggedIn));
    if (!_tabReady || _lastLoggedIn != loggedIn) {
      if (_tabReady) _tab.dispose();
      _tab = _buildTab(loggedIn);
      _tabReady = true;
      _lastLoggedIn = loggedIn;
    }
    final scheme = Theme.of(context).colorScheme;
    final library = ref.watch(themeLibraryProvider);
    // 悬浮顶栏切换:与壁纸中心同口径,跟随「悬浮搜索条」设置(竖屏生效)
    final portraitFloating =
        MediaQuery.of(context).orientation != Orientation.landscape &&
            (ref.watch(settingsProvider.select(
                  (s) => s.valueOrNull?.floatingSearchBar ?? false,
                )) ==
                true);
    final topInset = portraitFloating
        ? MediaQuery.paddingOf(context).top +
            GlassTopBar.height(context, bottom: _tabBar) +
            6
        : 0.0;
    final content = RepaintBoundary(
      child: TabBarView(
        controller: _tab,
        children: [
          // 本地已导入:全部包;导入入口按壁纸中心风格放内容区中间。
          _libraryList(
            scheme,
            library.packages,
            activeId: library.activeId,
            empty: _hintBlock(
              scheme,
              icon: Icons.palette_outlined,
              title: tr('还没有导入主题包'),
              detail: tr('在主题编辑器 https://topic.xianyumusic.cn 导出 JSON 后导入'),
            ),
            topInset: topInset,
            leading: _importButton(),
          ),
          if (_lastLoggedIn == true) ...[
            _remoteList(ref.watch(themeSquareProvider), scheme,
                topInset: topInset),
            _remoteList(ref.watch(myThemesProvider), scheme,
                topInset: topInset),
            // 我的下载:仅列出从广场下载过的子集(本地来源记录)。
            _libraryList(
              scheme,
              library.packages
                  .where((pkg) => library.downloadedIds.contains(pkg.id))
                  .toList(),
              activeId: library.activeId,
              empty: _hintBlock(
                scheme,
                icon: Icons.download_outlined,
                title: tr('还没有从广场下载主题'),
                detail: tr('到「广场」挑选主题，下载后会出现在这里'),
              ),
              topInset: topInset,
            ),
          ],
        ],
      ),
    );
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 悬浮态内容全屏(顶栏浮在其上);非悬浮态内容下移让出顶栏
          if (portraitFloating)
            Positioned.fill(child: content)
          else
            Padding(
              padding: EdgeInsets.only(
                top: GlassTopBar.height(context, bottom: _tabBar),
              ),
              child: content,
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(tr('主题中心')),
              bottom: _tabBar,
              bottomTabController: _tab,
            ),
          ),
        ],
      ),
    );
  }

  /// 导入入口:原顶栏右上角按钮移到内容区中间(壁纸中心风格)
  Widget _importButton() => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.file_open_outlined, size: 18),
            label: Text(tr('导入主题包')),
          ),
        ),
      );

  /// 本地包列表（「本地」与「我的下载」共用，卡片与操作行为保持一致）。
  /// [leading] 为本地 tab 的导入入口:有包时插在列表最前,
  /// 空状态时移到空提示文字下方。
  Widget _libraryList(
    ColorScheme scheme,
    List<ThemePackage> pkgs, {
    String? activeId,
    required Widget empty,
    double topInset = 0,
    Widget? leading,
  }) {
    // 空状态:提示块+导入按钮整体在剩余高度垂直居中,
    // 不再叠加 96 固定偏移;有内容时维持原列表
    if (pkgs.isEmpty) {
      return LayoutBuilder(builder: (context, box) {
        return ListView(
          padding: EdgeInsets.fromLTRB(16, 12 + topInset, 16, 32),
          children: [
            SizedBox(
              height: math.max(0, box.maxHeight - (12 + topInset) - 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [empty, ?leading],
              ),
            ),
          ],
        );
      });
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 12 + topInset, 16, 32),
      children: [
        ?leading,
        for (final pkg in pkgs)
          _packageCard(scheme, pkg, isActive: pkg.id == activeId),
      ],
    );
  }

  /// 远端列表三态渲染：加载中 / 失败 / 列表。
  ///
  /// 失败时不退化成空列表——那会让用户以为「没有主题」，与真实的加载失败混淆。
  Widget _remoteList(AsyncValue<List<RemoteTheme>> async, ColorScheme scheme,
      {double topInset = 0}) {
    return async.when(
      loading: () => Padding(
        padding: EdgeInsets.only(top: topInset),
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => Padding(
        padding: EdgeInsets.only(top: 96 + topInset),
        child: _hintBlock(
          scheme,
          icon: Icons.cloud_off_outlined,
          title: tr('加载失败'),
          detail: tr('请检查网络后重试'),
        ),
      ),
      data: (list) => list.isEmpty
          ? Padding(
              padding: EdgeInsets.only(top: 96 + topInset),
              child: _hintBlock(
                scheme,
                icon: Icons.palette_outlined,
                title: tr('暂无主题'),
                detail: '',
              ),
            )
          : ListView.builder(
              padding: EdgeInsets.fromLTRB(8, 8 + topInset, 8, 24),
              itemCount: list.length,
              itemBuilder: (context, i) => RemoteThemeTile(
                theme: list[i],
                onTap: () => _applyRemote(list[i]),
              ),
            ),
    );
  }

  /// 提示块本体不带顶距;需要的位置偏移由调用方包裹,
  /// 便于空态在 _libraryList 里垂直居中时不叠加偏移
  Widget _hintBlock(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String detail,
  }) =>
      Column(
        children: [
          Icon(icon, size: 44, color: scheme.outline),
          const SizedBox(height: 14),
          Text(title, style: TextStyle(color: scheme.onSurfaceVariant)),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ],
        ],
      );

  /// 应用远端主题。
  ///
  /// 接口回的 `payload` 是 Map，而导入器收的是 JSON 字符串，故先 jsonEncode。
  Future<void> _applyRemote(RemoteTheme theme) async {
    try {
      final pkg = await ref
          .read(themeLibraryProvider.notifier)
          .importJson(jsonEncode(theme.payload), fromSquare: true);
      if (!mounted) return;
      if (pkg == null) {
        showXianYuToast(context, tr('该主题包格式不正确，无法应用'));
        return;
      }
      await _activate(pkg);
    } catch (e) {
      if (mounted) showXianYuToast(context, tr('应用失败：{e}', {'e': '$e'}));
    }
  }

  Widget _packageCard(ColorScheme scheme, ThemePackage pkg, {required bool isActive}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        border: isActive
            ? Border.all(color: scheme.primary, width: 1.4)
            : Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _preview(pkg, scheme),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(pkg.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    if (isActive) ...[
                      const SizedBox(width: 8),
                      _badge(scheme),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  pkg.author.isEmpty ? tr('未知作者') : pkg.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Text(
                  _slotSummary(pkg),
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (isActive)
                      TextButton(onPressed: _deactivate, child: Text(tr('取消应用')))
                    else
                      FilledButton(onPressed: () => _activate(pkg), child: Text(tr('应用'))),
                    TextButton(
                      onPressed: () => _remove(pkg),
                      child: Text(tr('删除'), style: TextStyle(color: scheme.error)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _preview(ThemePackage pkg, ColorScheme scheme) {
    const size = 56.0;
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(Icons.image_outlined, color: scheme.outline, size: 22),
    );
    if (pkg.preview.isEmpty) return fallback;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: CachedNetworkImage(
        imageUrl: pkg.preview,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }

  Widget _badge(ColorScheme scheme) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(tr('已应用'),
            style: TextStyle(fontSize: 10, color: scheme.onPrimary)),
      );

  String _slotSummary(ThemePackage pkg) => tr(
        '图标 {icons} · 贴纸 {stickers} · 色块 {surfaces}',
        {
          'icons': pkg.icons.length,
          'stickers': pkg.stickers.length,
          'surfaces': pkg.surfaces.length,
        },
      );
}
