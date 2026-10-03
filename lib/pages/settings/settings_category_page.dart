import '../../src/widgets/modern_dialog.dart';
import '../../src/widgets/predictive_dialog_route.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import '../../src/backup/app_backup.dart';
import '../../src/core/app_colors.dart';
import '../../src/responsive/landscape.dart';
import '../../src/core/application_logger.dart';
import '../../src/core/platform_caps.dart';
import '../../src/core/settings.dart';
import '../../src/player/player_provider.dart';
import '../../src/player/sleep_timer.dart';
import '../../src/player/sleep_timer_sheet.dart';
import '../../src/player/mv_provider.dart';
import '../../src/player/cast_provider.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/committed_slider.dart';
import '../../src/audio/audio_devices.dart';
import '../../src/lyrics/floating_lyrics.dart';
import '../../src/rust/api.dart' as frb;
import '../../src/i18n/i18n.dart';
import '../../src/library/saf_channel.dart';
import '../../src/watch_link/watch_link_channel.dart';
import '../../src/watch_link/watch_link_provider.dart';
import '../../src/widgets/dlna_device_dialog.dart';
import 'desktop_link_page.dart';

part 'settings_category_page.watch.dart';
part 'settings_category_page.controls.dart';
part 'settings_category_page.sections.dart';
part 'settings_category_page.picks.dart';
part 'settings_category_page.color_picker.dart';
part 'settings_category_page.groups.dart';

enum SettingsCategory {
  general,
  appearance,
  lyrics,
  playback,
  download,
  tools,
  watch,
  dlna,
  desktop,
  advanced;

  static SettingsCategory fromPath(String p) => switch (p) {
    'appearance' => SettingsCategory.appearance,
    'lyrics' => SettingsCategory.lyrics,
    'playback' => SettingsCategory.playback,
    'download' => SettingsCategory.download,
    'tools' => SettingsCategory.tools,
    'watch' => SettingsCategory.watch,
    'dlna' => SettingsCategory.dlna,
    'desktop' => SettingsCategory.desktop,
    'advanced' => SettingsCategory.advanced,
    _ => SettingsCategory.general,
  };

  String get title => switch (this) {
    SettingsCategory.general => tr('常规'),
    SettingsCategory.appearance => tr('外观'),
    SettingsCategory.lyrics => tr('歌词'),
    SettingsCategory.playback => tr('播放'),
    SettingsCategory.download => tr('下载'),
    SettingsCategory.tools => tr('工具'),
    SettingsCategory.watch => tr('腕上联动'),
    SettingsCategory.dlna => tr('DLNA 投放'),
    SettingsCategory.desktop => tr('桌面联动'),
    SettingsCategory.advanced => tr('高级设置'),
  };
}

Color settingsSurfaceBg(BuildContext context) => appSurfaceBg(context);

Color settingsCardColor(BuildContext context) => appCardColor(context);

class SettingsCategoryPage extends ConsumerStatefulWidget {
  const SettingsCategoryPage({
    super.key,
    required this.category,
    this.embedded = false,
  });

  final SettingsCategory category;

  final bool embedded;

  @override
  ConsumerState<SettingsCategoryPage> createState() =>
      _SettingsCategoryPageState();
}

class _SettingsCategoryPageState extends ConsumerState<SettingsCategoryPage> {
  SettingsCategory get category => widget.category;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final notifier = ref.read(settingsProvider.notifier);
    final exclusivePlaying = ref.watch(playerProvider.select((s) => s.usbExclusive));

    if (widget.embedded) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: _buildItems(
          context,
          ref,
          category,
          settings,
          notifier,
          exclusivePlaying,
        ),
      );
    }

    // 账号页同款透出做法:ListView 铺满整屏,顶距写进自身 padding,
    // 内容可滚到悬浮表头/状态栏后面,而非被外层 Padding 硬垫开
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
            children: _buildItems(
              context,
              ref,
              category,
              settings,
              notifier,
              exclusivePlaying,
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(category.title),
            ),
          ),
        ],
      ),
    );
  }

  Widget _choiceSheet(
    BuildContext context,
    List<_Choice> choices,
    Object? cur, {
    required String Function(dynamic) labelOf,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in choices)
            ListTile(
              title: Text(labelOf(c.value)),
              subtitle: c.subtitle == null
                  ? null
                  : Text(
                      c.subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
              trailing: c.value == cur
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              selected: c.value == cur,
              onTap: () => Navigator.pop(context, c),
            ),
        ],
      ),
    );
  }
}
