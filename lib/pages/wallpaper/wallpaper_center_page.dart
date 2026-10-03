import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import '../../src/core/application_logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../src/auth/account_api.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/app_http.dart';
import '../../src/core/motion_photo.dart';
import '../../src/core/settings.dart';
import '../../src/navigation/routes.dart' show coverPageRoute;
import '../../src/navigation/shell.dart';
import '../../src/widgets/custom_background.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/i18n/i18n.dart';
part 'wallpaper_center_page.gallery.dart';
part 'wallpaper_center_page.upload.dart';
part 'wallpaper_center_page.downloads.dart';
part 'wallpaper_center_page.editor.dart';

final ValueNotifier<int> _downloadsRevision = ValueNotifier<int>(0);

class WallpaperCenterPage extends ConsumerStatefulWidget {
  const WallpaperCenterPage({super.key});

  @override
  ConsumerState<WallpaperCenterPage> createState() =>
      _WallpaperCenterPageState();
}

class _WallpaperCenterPageState extends ConsumerState<WallpaperCenterPage>
    with HideMiniBar, TickerProviderStateMixin {
  late TabController _tab;
  bool _tabReady = false;
  bool? _lastLoggedIn;

  TabController _buildTab(bool loggedIn) =>
      TabController(length: loggedIn ? 4 : 1, vsync: this);

  PreferredSizeWidget get _tabBar => TabBar(
    controller: _tab,
    // 固定不滚动,tab 等宽平均分布(与主题中心同口径)
    isScrollable: false,
    tabs: [
      if (_lastLoggedIn == true) ...[
        Tab(text: tr('壁纸广场')),
        Tab(text: tr('我的上传')),
        Tab(text: tr('我的下载')),
      ],
      Tab(text: tr('自定义壁纸')),
    ],
  );

  @override
  void dispose() {
    if (_tabReady) _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(authProvider.select((a) => a.isLoggedIn));
    if (!_tabReady || _lastLoggedIn != loggedIn) {
      if (_tabReady) _tab.dispose();
      _tab = _buildTab(loggedIn);
      _tabReady = true;
      _lastLoggedIn = loggedIn;
    }
    final portraitFloating =
        MediaQuery.of(context).orientation != Orientation.landscape &&
        (ref.watch(
              settingsProvider.select(
                (s) => s.valueOrNull?.floatingSearchBar ?? false,
              ),
            ) ==
            true);
    final topInset = portraitFloating
        ? MediaQuery.paddingOf(context).top +
              66 +
              _tabBar.preferredSize.height +
              6
        : 0.0;
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          _tabHost(
            portraitFloating,
            topInset,
            RepaintBoundary(
              child: TabBarView(
                controller: _tab,
                children: [
                  if (_lastLoggedIn == true) ...[
                    _WallpaperBrowseTab(topInset: topInset),
                    _MyUploadsTab(topInset: topInset),
                    _MyDownloadsTab(topInset: topInset),
                  ],
                  CustomWallpaperEditor(topInset: topInset),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(tr('壁纸中心')),
              bottom: _tabBar,
              bottomTabController: _tab,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabHost(bool floating, double topInset, Widget child) {
    if (floating) return Positioned.fill(child: RepaintBoundary(child: child));
    return Padding(
      padding: EdgeInsets.only(
        top: GlassTopBar.height(context, bottom: _tabBar),
      ),
      child: child,
    );
  }
}
