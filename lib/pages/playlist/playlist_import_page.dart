import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/navigation/shell.dart';
import '../../src/library/library_provider.dart';
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
