import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/core/platform_caps.dart';
import '../../src/core/settings.dart';
import '../../src/library/library_provider.dart';
import '../../src/library/ohos_folder_channel.dart';
import '../../src/library/saf_channel.dart';
import '../../src/library/scan_settings_provider.dart';
import '../../src/remote/remote_library_service.dart';
import '../../src/navigation/routes.dart' show coverPageRoute;
import '../../src/navigation/shell.dart';
import '../../src/responsive/landscape.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/floating_search_bar.dart' show FloatingGlassSurface;
import '../../src/player/player_provider.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/predictive_dialog_route.dart';
import '../settings/folder_picker_page.dart';
import 'song_list_page.dart';
import '../../src/i18n/i18n.dart';
part 'library_folder_page.actions.dart';
part 'library_folder_page.cards.dart';
part 'library_folder_page.nodes.dart';
part 'library_folder_page.views.dart';

class LibraryFolderPage extends ConsumerStatefulWidget {
  const LibraryFolderPage({super.key, this.embedded = false});

  /// 横屏音乐库容器内嵌（右侧容器）模式：不显示自带顶栏/返回键，
  /// 顶部偏移跟随壳层全局顶栏（与 LibraryPage 的 pane 头部同口径）。
  final bool embedded;

  @override
  ConsumerState<LibraryFolderPage> createState() => _LibraryFolderPageState();
}

class _LibraryFolderPageState extends ConsumerState<LibraryFolderPage>
    with HideMiniBar {
  final Set<String> _expanded = {};
  bool _scanning = false;
  bool _adding = false;

  int _lastDuration = 60;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) {
        ref.read(libraryProvider.notifier).checkSafFolderAuthorization();
      }
    });
    Future.microtask(_seedSandboxFolders);
  }

  static const _audioExts = [
    'mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'ape', 'wma', 'aiff',
  ];

  @override
  Widget build(BuildContext context) {
    final root = ref.watch(libraryProvider.select((s) => s.folderRoot));
    final lost =
        ref.watch(libraryProvider.select((s) => s.unauthorizedFolders));
    final foldersAsync = ref.watch(scanFoldersProvider);
    final minDuration = ref
            .watch(settingsProvider)
            .valueOrNull
            ?.libraryMinDurationSeconds ??
        0;

    final tiles = <Widget>[];
    _buildNodes(context, root, tiles);

    if (widget.embedded) {
      // 嵌入横屏音乐库右侧容器：横竖屏都渲染 pane 布局（pane 仅在横屏挂载，
      // 竖屏旋转时壳层会关闭 pane 并走路由回退）
      return _buildLandscape(
        context,
        embedded: true,
        root: root,
        lost: lost,
        foldersAsync: foldersAsync,
        minDuration: minDuration,
        tiles: tiles,
      );
    }

    return LandscapeGate(
      portrait: _buildPortrait(
        context,
        root: root,
        lost: lost,
        foldersAsync: foldersAsync,
        minDuration: minDuration,
        tiles: tiles,
      ),
      landscape: _buildLandscape(
        context,
        root: root,
        lost: lost,
        foldersAsync: foldersAsync,
        minDuration: minDuration,
        tiles: tiles,
      ),
    );
  }

  static const double _kPaneHeaderHeight = 48.0;
}
