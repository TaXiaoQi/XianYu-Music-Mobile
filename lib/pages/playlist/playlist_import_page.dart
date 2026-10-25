import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/core/platform_caps.dart';
import '../../src/navigation/shell.dart';
import '../../src/library/library_provider.dart';
import '../../src/library/ohos_folder_channel.dart';
import '../../src/library/saf_channel.dart';
import '../../src/plugin/plugin_backup_file.dart';
import '../../src/plugin/plugin_backup_import.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/playlist/playlist_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/add_to_playlist_sheet.dart'
    show importedSongFromQueueItem;
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/press_scale.dart';
import '../../src/i18n/i18n.dart';


part 'playlist_import_page.backup.dart';
part 'playlist_import_page.local.dart';
part 'playlist_import_page.cloud.dart';
class PlaylistImportPage extends ConsumerStatefulWidget {
  const PlaylistImportPage({super.key});

  @override
  ConsumerState<PlaylistImportPage> createState() => _PlaylistImportPageState();
}

class _PlaylistImportPageState extends ConsumerState<PlaylistImportPage>
    with TickerProviderStateMixin, HideMiniBar {
  late TabController _tabCtrl = TabController(length: 3, vsync: this);
  bool _cloudTab = true;

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasPlugin = ref.watch(
      pluginManagerProvider.select((s) => s.sources.any((p) => p.enabled)),
    );
    if (hasPlugin != _cloudTab) {
      _cloudTab = hasPlugin;
      final prev = _tabCtrl.index;
      _tabCtrl.dispose();
      _tabCtrl = TabController(length: hasPlugin ? 3 : 2, vsync: this)
        ..index = prev.clamp(0, (hasPlugin ? 3 : 2) - 1);
    }
    final tabBar = TabBar(
      controller: _tabCtrl,
      tabs: [
        Tab(text: tr('备份文件')),
        Tab(text: tr('本地文件')),
        if (hasPlugin) Tab(text: tr('云端导入')),
      ],
    );
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: RepaintBoundary(
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(
                top: GlassTopBar.height(context, bottom: tabBar),
              ),
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  const _BackupImportTab(),
                  const _LocalFolderTab(),
                  if (hasPlugin) const _CloudImportTab(),
                ],
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title: Text(tr('导入歌单')),
                bottom: tabBar,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 打开歌单导入：竖屏保持整页路由；横屏（平板/车机大屏）改为桌面端同款
/// 居中弹窗，替代原先整面铺满的页面。
Future<void> openPlaylistImport(BuildContext context) async {
  final landscape =
      MediaQuery.of(context).orientation == Orientation.landscape;
  if (!landscape) {
    await context.push('/playlist-import');
    return;
  }
  await showPredictiveDialog<void>(
    context: context,
    builder: (_) => const _ImportDialog(),
  );
}

/// 桌面端同款导入弹窗：容器 + 页签切换，三个导入 Tab 与整页路由共用组件。
class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog();

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog>
    with TickerProviderStateMixin {
  late TabController _tabCtrl = TabController(length: 3, vsync: this);
  bool _cloudTab = true;

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasPlugin = ref.watch(
      pluginManagerProvider.select((s) => s.sources.any((p) => p.enabled)),
    );
    if (hasPlugin != _cloudTab) {
      _cloudTab = hasPlugin;
      final prev = _tabCtrl.index;
      _tabCtrl.dispose();
      _tabCtrl = TabController(length: hasPlugin ? 3 : 2, vsync: this)
        ..index = prev.clamp(0, (hasPlugin ? 3 : 2) - 1);
    }
    final tabBar = TabBar(
      controller: _tabCtrl,
      tabs: [
        Tab(text: tr('备份文件')),
        Tab(text: tr('本地文件')),
        if (hasPlugin) Tab(text: tr('云端导入')),
      ],
    );
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).dialogTheme.backgroundColor ??
              Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(24),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: tabBar,
            ),
            Flexible(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  const _BackupImportTab(),
                  const _LocalFolderTab(),
                  if (hasPlugin) const _CloudImportTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
