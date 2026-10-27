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
import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_filename.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_scoped_query.dart';
import '../../src/library/library_provider.dart';
import '../../src/library/ohos_folder_channel.dart';
import '../../src/library/saf_channel.dart';
import '../../src/player/player_provider.dart';
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
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/press_scale.dart';
import '../../src/widgets/glass_dialog_shell.dart';
import '../../src/i18n/i18n.dart';


part 'playlist_import_page.backup.dart';
part 'playlist_import_page.local.dart';
part 'playlist_import_page.cloud.dart';

/// 打开歌单导入：双端（横竖屏）统一为桌面端同款居中弹窗，替代原先的
/// 整页路由（竖屏整页已删，与横屏共用弹窗）。
Future<void> openPlaylistImport(BuildContext context) async {
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
  /// controller 恒 3（云端 tab 缺席时只有 2 个 tab，index 由下方 clamp
  /// 兜底）。绝不在 build 中 dispose/重建：旧 controller 的动画还被
  /// TabBar 指示器等引用，paint 期会抛空指针（弹窗整片空白的根因）
  late final TabController _tabCtrl = TabController(length: 3, vsync: this);

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
    // 插件被禁用导致云端页不可用时，帧后把停在云端页的 index 拉回
    // 本地文件页（build 期间不能改 controller：会同步触发 setState）
    if (!hasPlugin && _tabCtrl.index >= 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tabCtrl.index = 1;
      });
    }
    final scheme = Theme.of(context).colorScheme;
    // tabs 恒 3 与 controller.length 恒匹配：无插件时云端 tab 置灰并
    // 拦截点击（避免 index 指向不存在的 tab 导致指示器绘制越界）
    final tabBar = TabBar(
      controller: _tabCtrl,
      // IndexedStack 直切页面：弹窗内 PageView(TabBarView) 在部分机型
      // 上切页后不渲染（空白），索引直切更稳
      onTap: (i) {
        if (i == 2 && !hasPlugin) {
          _tabCtrl.index = 1;
        }
        setState(() {});
      },
      tabs: [
        Tab(text: tr('备份文件')),
        Tab(text: tr('本地文件')),
        Tab(
          child: Text(
            tr('云端导入'),
            style: TextStyle(
              color: hasPlugin ? null : scheme.outline,
            ),
          ),
        ),
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
        // 桌面端同款玻璃弹窗：材质开启时整窗毛玻璃透底（无按钮区）
        child: GlassDialogShell(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: tabBar,
              ),
              // 内容区固定高度：屏幕过矮时由 Flexible 收缩让位
              Flexible(
                child: SizedBox(
                  height: 360,
                  child: IndexedStack(
                    index: _tabCtrl.index,
                    children: [
                      const _BackupImportTab(),
                      const _LocalFolderTab(),
                      const _CloudImportTab(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
