import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/i18n/i18n.dart';
import '../../src/theme/remote_theme.dart';
import '../../src/theme/remote_theme_store.dart';
import '../../src/theme/remote_theme_tile.dart';
import '../../src/theme/theme_package.dart';
import '../../src/theme/theme_store.dart';
import '../../src/widgets/app_toast.dart';

/// 主题中心（阶段 1：本地导入 + 应用）。
/// 广场 / 我的上传 / 我的下载依赖服务端接口，待接入后补。
class ThemeCenterPage extends ConsumerStatefulWidget {
  const ThemeCenterPage({super.key});

  @override
  ConsumerState<ThemeCenterPage> createState() => _ThemeCenterPageState();
}

class _ThemeCenterPageState extends ConsumerState<ThemeCenterPage> {
  bool _busy = false;

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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final library = ref.watch(themeLibraryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('主题中心')),
        actions: [
          TextButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.file_open_outlined, size: 18),
            label: Text(tr('导入主题包')),
          ),
        ],
      ),
      body: DefaultTabController(
        length: 3,
        child: Column(
          children: [
            TabBar(
              tabs: [
                Tab(text: tr('本地')),
                Tab(text: tr('广场')),
                Tab(text: tr('我的上传')),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  // 本地已导入：沿用原有列表，行为与接线前一致。
                  ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    children: [
                      if (library.packages.isEmpty)
                        _emptyHint(scheme)
                      else
                        for (final pkg in library.packages)
                          _packageCard(scheme, pkg,
                              isActive: pkg.id == library.activeId),
                    ],
                  ),
                  _remoteList(ref.watch(themeSquareProvider), scheme),
                  _remoteList(ref.watch(myThemesProvider), scheme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 远端列表三态渲染：加载中 / 失败 / 列表。
  ///
  /// 失败时不退化成空列表——那会让用户以为「没有主题」，与真实的加载失败混淆。
  Widget _remoteList(AsyncValue<List<RemoteTheme>> async, ColorScheme scheme) {
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => _hintBlock(
        scheme,
        icon: Icons.cloud_off_outlined,
        title: tr('加载失败'),
        detail: tr('请检查网络后重试'),
      ),
      data: (list) => list.isEmpty
          ? _hintBlock(
              scheme,
              icon: Icons.palette_outlined,
              title: tr('暂无主题'),
              detail: '',
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
              itemCount: list.length,
              itemBuilder: (context, i) => RemoteThemeTile(
                theme: list[i],
                onTap: () => _applyRemote(list[i]),
              ),
            ),
    );
  }

  Widget _hintBlock(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String detail,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: 96),
        child: Column(
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
        ),
      );

  /// 应用远端主题。
  ///
  /// 接口回的 `payload` 是 Map，而导入器收的是 JSON 字符串，故先 jsonEncode。
  Future<void> _applyRemote(RemoteTheme theme) async {
    try {
      final pkg = await ref
          .read(themeLibraryProvider.notifier)
          .importJson(jsonEncode(theme.payload));
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

  Widget _emptyHint(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(top: 96),
        child: Column(
          children: [
            Icon(Icons.palette_outlined, size: 44, color: scheme.outline),
            const SizedBox(height: 14),
            Text(tr('还没有导入主题包'),
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Text(
              tr('在主题编辑器 https://topic.xianyumusic.cn 导出 JSON 后导入'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ],
        ),
      );

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
