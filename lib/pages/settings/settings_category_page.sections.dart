part of 'settings_category_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _SettingsCategoryPageSections on _SettingsCategoryPageState {
  List<Widget> _buildItems(
    BuildContext context,
    WidgetRef ref,
    SettingsCategory category,
    AppSettings? settings,
    SettingsNotifier notifier,
    bool exclusivePlaying,
  ) {
    switch (category) {
      case SettingsCategory.general:
        return _general(context, ref, settings, notifier);
      case SettingsCategory.appearance:
        return _appearance(context, ref, settings, notifier);
      case SettingsCategory.lyrics:
        return _lyrics(context, ref, settings, notifier);
      case SettingsCategory.playback:
        return _playback(context, ref, settings, notifier, exclusivePlaying);
      case SettingsCategory.download:
        return _download(context, ref, settings, notifier);
      case SettingsCategory.tools:
        return _tools(context);
      case SettingsCategory.watch:
        return _watch(context, ref, settings, notifier);
      case SettingsCategory.dlna:
        return _dlna(context, ref, settings, notifier);
      case SettingsCategory.desktop:
        return [const DesktopLinkSection()];
      case SettingsCategory.advanced:
        return _advanced(context, settings, notifier);
    }
  }

  // ---- DLNA 投放 ----
  List<Widget> _dlna(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    return [
      _sectionHeader(context, tr('DLNA 投放')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.cast_outlined,
            title: tr('选择设备投放'),
            subtitle: tr('将当前播放投送到电视、音箱等 DLNA 设备'),
            trailing: const SizedBox.shrink(),
            onTap: () => showDlnaDeviceDialog(context, ref),
          ),
        ],
      ),
      _sectionHeader(context, tr('DLNA 渲染器')),
      _CardGroup(
        children: [
          Builder(builder: (ctx) {
            final dlnaCast = ref.watch(dlnaCastProvider);
            return _switchTile(
              context,
              icon: Icons.album_outlined,
              title: tr('接收其它设备投屏'),
              subtitle: dlnaCast.rendererRunning
                  ? tr('运行中 · 端口 {port}',
                      {'port': dlnaCast.rendererPort.toString()})
                  : tr('开启后本机作为 DLNA 设备出现在局域网，其它 App 可直接投歌到本端'),
              value: s?.dlnaRendererEnabled ?? false,
              onChanged: (v) async {
                await n.setDlnaRendererEnabled(v);
                await ref.read(dlnaCastProvider.notifier).applyRendererSetting();
              },
            );
          }),
          _tile(
            context,
            icon: Icons.badge_outlined,
            title: tr('设备名称'),
            subtitle: tr('投送端看到的名字'),
            trailing: Text(
              (s?.dlnaRendererName ?? '').trim().isEmpty
                  ? tr('弦予音乐')
                  : s!.dlnaRendererName.trim(),
              style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _editDlnaRendererName(context, ref),
          ),
        ],
      ),
      _sectionHeader(context, tr('说明')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.info_outline,
            title: tr('同一局域网'),
            subtitle: tr('接收设备需与手机连接同一 Wi-Fi；播放页分享面板中也可发起投放'),
            trailing: const SizedBox.shrink(),
            showChevron: false,
          ),
        ],
      ),
    ];
  }

  // ---- 常规 ----
  List<Widget> _general(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    return [
      _sectionHeader(context, tr('语言')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.language_outlined,
            title: tr('语言'),
            trailing: Text(_languageLabel(s?.language ?? AppLanguage.system)),
            onTap: () => _pickLanguage(context, ref, s),
          ),
        ],
      ),
      _sectionHeader(context, tr('反馈')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.vibration_outlined,
            title: tr('触觉反馈力度'),
            subtitle: tr('点击底部导航等操作的手感震动强度'),
            trailing: Text(_hapticLabel(s?.hapticStrength ?? 1)),
            onTap: () => _pickHaptic(context, ref, s),
          ),
        ],
      ),
      if (PlatformCaps.supportsInAppUpdate) ...[
        _sectionHeader(context, tr('检测更新')),
        _CardGroup(
          children: [
            _tile(
              context,
              icon: Icons.system_update_alt_outlined,
              title: tr('检测更新模式'),
              subtitle: tr('启动时自动检查 App 更新'),
              trailing: Text(_updateModeLabel(s?.updateCheckMode ?? 'startup')),
              onTap: () => _pickUpdateCheckMode(context, ref, s),
            ),
          ],
        ),
      ],
      _sectionHeader(context, tr('系统')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.screen_lock_rotation_outlined,
            title: tr('保持屏幕常亮'),
            value: s?.keepScreenOn ?? true,
            onChanged: (v) => n.setKeepScreenOn(v),
          ),
        ],
      ),
      _sectionHeader(context, tr('列表显示')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.vertical_align_top_outlined,
            title: tr('显示回到顶部按钮'),
            subtitle: tr('歌曲列表滚动后显示返回顶部的悬浮按钮'),
            value: s?.enableScrollToTopButton ?? true,
            onChanged: (v) => n.setEnableScrollToTopButton(v),
          ),
        ],
      ),
      _sectionHeader(context, tr('存储空间')),
      const _StorageSettingsGroup(),
    ];
  }

  // ---- 外观 ----
  List<Widget> _appearance(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    return [
      _sectionHeader(context, tr('主题')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.palette_outlined,
            title: tr('主题模式'),
            trailing: _themeLabel(s),
            onTap: () => _pickThemeMode(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.color_lens_outlined,
            title: tr('主题色'),
            trailing: _ColorDot(color: Color(s?.accentColor ?? 0xFFEC4141)),
            onTap: () => _pickAccentColor(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.palette_outlined,
            title: tr('主题中心'),
            subtitle: tr('导入主题包并应用图标、贴纸与组件色块'),
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/theme'),
          ),
          _tile(
            context,
            icon: Icons.wallpaper_outlined,
            title: tr('壁纸中心'),
            subtitle: tr('自定义背景与动态壁纸'),
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/wallpaper'),
          ),
          _tile(
            context,
            icon: Icons.view_list_outlined,
            title: tr('列表大小'),
            subtitle: tr('歌曲 / 歌手 / 专辑 / 歌单列表项尺寸'),
            trailing: Text(listSizeLabel(
                s?.listSize ?? ListSize.medium)),
            onTap: () => _pickListSize(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.text_fields_outlined,
            title: tr('字体大小'),
            subtitle: tr('跟随系统缩放，或选择应用内固定字号'),
            trailing: Text(_fontSizeLabel(s?.fontSize ?? AppFontSize.system)),
            onTap: () => _pickFontSize(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.photo_size_select_large_outlined,
            title: tr('样式大小'),
            subtitle: tr('整套界面统一缩放，适配不同屏幕'),
            trailing: Text(_uiScaleLabel(s?.uiScaleIndex ?? 1)),
            onTap: () => _pickUiScale(context, ref, s),
          ),
        ],
      ),
      _sectionHeader(context, tr('材质')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.blur_on_outlined,
            title: tr('毛玻璃材质'),
            subtitle: tr('顶栏、底栏与播放条透明磨砂质感，关闭时回退纯色'),
            value: s?.frostedGlass ?? false,
            onChanged: (v) => n.setFrostedGlass(v),
          ),
          if (s?.frostedGlass ?? false)
            _tile(
              context,
              icon: Icons.tune_outlined,
              title: tr('毛玻璃效果'),
              subtitle: tr('调整毛玻璃模糊强度'),
              trailing: Text(switch (s?.frostedGlassLevel ??
                  FrostedGlassLevel.medium) {
                FrostedGlassLevel.strongest => tr('最强'),
                FrostedGlassLevel.medium => tr('中等'),
                FrostedGlassLevel.light => tr('轻度'),
              }),
              onTap: () => _pickFrostedGlassLevel(context, ref, s),
            ),
          _switchTile(
            context,
            icon: Icons.gradient_outlined,
            title: tr('液态玻璃'),
            subtitle: tr(
                '开启时自动切换到悬浮式底栏；底栏、迷你条、搜索框与播放页控制卡优先液态，其余表面由毛玻璃补齐'),
            value: s?.liquidGlass ?? false,
            onChanged: (v) => n.setLiquidGlass(v),
          ),
          if (s?.liquidGlass ?? false)
            _tile(
              context,
              icon: Icons.tune_outlined,
              title: tr('液态玻璃效果'),
              subtitle: tr('调整玻璃透亮与磨砂程度'),
              trailing: Text(switch (s?.liquidGlassQuality ??
                  LiquidGlassQuality.medium) {
                LiquidGlassQuality.low => tr('低 · 透亮'),
                LiquidGlassQuality.high => tr('高 · 磨砂'),
                LiquidGlassQuality.medium => tr('中 · 均衡'),
              }),
              onTap: () => _pickLiquidGlassQuality(context, ref, s),
            ),
        ],
      ),
      _sectionHeader(context, tr('导航栏与底栏')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.navigation_outlined,
            title: tr('导航栏位置'),
            trailing: Text(switch (s?.navBarPosition ?? NavBarPosition.bottom) {
              NavBarPosition.bottom => tr('底部导航'),
              NavBarPosition.side => tr('侧边悬浮'),
            }),
            onTap: () => _pickNavBarPosition(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.screen_rotation_alt_outlined,
            title: tr('竖屏切换动画'),
            subtitle: tr('覆盖：新页盖住旧页；平滑：新旧两页平行平移'),
            trailing: Text(switch (s?.pageTransitionStyle ??
                PageTransitionStyle.cover) {
              PageTransitionStyle.cover => tr('覆盖'),
              PageTransitionStyle.smooth => tr('平滑'),
            }),
            onTap: () => _pickPageTransitionStyle(context, ref, s),
          ),
          _switchTile(
            context,
            icon: Icons.animation_outlined,
            title: tr('横屏切换动画'),
            subtitle: tr('横屏下首页/我的在右侧容器切换时淡进淡出'),
            value: s?.landscapeTransitionEnabled ?? true,
            onChanged: (v) => n.setLandscapeTransitionEnabled(v),
          ),
          if ((s?.navBarPosition ?? NavBarPosition.bottom) ==
              NavBarPosition.bottom)
            _switchTile(
              context,
              icon: Icons.subtitles_outlined,
              title: tr('悬浮式底栏'),
              value: s?.floatingNavBar ?? true,
              onChanged: (v) => n.setFloatingNavBar(v),
            ),
          _switchTile(
            context,
            icon: Icons.manage_search_outlined,
            title: tr('悬浮顶部栏'),
            subtitle: tr('首页、我的页与横屏顶栏改为悬浮显示（控件独立悬浮），应用液态玻璃时同步生效'),
            value: s?.floatingSearchBar ?? false,
            onChanged: (v) => n.setFloatingSearchBar(v),
          ),
          _switchTile(
            context,
            icon: Icons.crop_landscape_outlined,
            title: tr('横屏使用摄像头区域'),
            subtitle: tr('横屏时各页面铺满到摄像头(挖孔)区域，不再留黑边'),
            value: s?.landscapeCameraArea ?? true,
            onChanged: (v) => n.setLandscapeCameraArea(v),
          ),
          if ((s?.navBarPosition ?? NavBarPosition.side) == NavBarPosition.side)
            _tile(
              context,
              icon: Icons.swap_vert_outlined,
              title: tr('侧边栏展开方向'),
              trailing: Text(switch (s?.sideBarExpandDirection ??
                  SideBarExpandDirection.down) {
                SideBarExpandDirection.down => tr('向下展开'),
                SideBarExpandDirection.up => tr('向上展开'),
              }),
              onTap: () => _pickSideBarExpandDirection(context, ref, s),
            ),
        ],
      ),
      _sectionHeader(context, tr('播放页')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.grid_view_outlined,
            title: tr('播放页样式'),
            subtitle: tr('切换正在播放页的布局风格'),
            trailing: Text(switch (s?.playerStyle ?? PlayerStyle.traditional) {
              PlayerStyle.advanced => tr('高级模式'),
              PlayerStyle.traditional => tr('传统模式'),
            }),
            onTap: () => _pickPlayerStyle(context, ref, s),
          ),
          _switchTile(
            context,
            icon: Icons.flip_outlined,
            title: tr('横屏自动隐藏顶栏/底栏'),
            subtitle: tr('横屏播放页无操作 3.5 秒后收起，触摸屏幕唤回'),
            value: s?.landscapeAutoHideChrome ?? true,
            onChanged: (v) => n.setLandscapeAutoHideChrome(v),
          ),
          _switchTile(
            context,
            icon: Icons.touch_app_outlined,
            title: tr('横屏点击收起顶栏/底栏'),
            subtitle: tr('横屏播放页顶栏/底栏显示时，点击画面空白处立即收起'),
            value: s?.landscapeTapToHideChrome ?? true,
            onChanged: (v) => n.setLandscapeTapToHideChrome(v),
          ),
          if ((s?.playerStyle ?? PlayerStyle.traditional) == PlayerStyle.advanced)
            _switchTile(
              context,
              icon: Icons.sync_alt_outlined,
              title: tr('播放页液态玻璃'),
              subtitle: tr('播放页控制卡使用液态玻璃材质'),
              value: s?.playerLiquidGlass ?? true,
              onChanged: (v) => n.setPlayerLiquidGlass(v),
            ),
        ],
      ),
    ];
  }

  // ---- 歌词 ----
  List<Widget> _lyrics(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    final mvOn = ref.watch(mvProvider.select((state) => state.requested));
    return [
      _sectionHeader(context, tr('歌词显示')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.translate_outlined,
            title: tr('显示翻译'),
            value: s?.showLyricsTranslation ?? true,
            onChanged: (v) => n.setShowLyricsTranslation(v),
          ),
          _switchTile(
            context,
            icon: Icons.abc_outlined,
            title: tr('显示罗马音'),
            value: s?.showLyricsRomaji ?? false,
            onChanged: (v) => n.setShowLyricsRomaji(v),
          ),
          _switchTile(
            context,
            icon: Icons.spellcheck_outlined,
            title: tr('逐字动效'),
            value: s?.enableWordEffect ?? true,
            onChanged: (v) => n.setEnableWordEffect(v),
          ),
        ],
      ),
      _sectionHeader(context, tr('歌词同步')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.sync_outlined,
            title: tr('同步偏移'),
            subtitle: tr('正值让歌词更晚显示，负值让歌词更早显示，用于修正歌词与音频的对齐差异'),
            trailing: _lyricsSyncOffsetSlider(s, n),
          ),
        ],
      ),
      if (PlatformCaps.supportsFloatingLyrics) ...[
      _sectionHeader(context, tr('桌面歌词')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.lyrics_outlined,
            title: tr('桌面歌词窗'),
            subtitle: mvOn
                ? tr('此功能不支持在MV期间使用')
                : tr('在其他应用上层显示卡拉OK逐字歌词'),
            enabled: !mvOn,
            value: s?.floatingLyricsEnabled ?? false,
            onChanged: (v) => _toggleFloatingLyrics(context, ref, n, v),
          ),
          _tile(
            context,
            icon: Icons.palette_outlined,
            title: tr('文字颜色'),
            trailing: _ColorDot(
              color: Color(s?.floatingLyricsTextColor ?? 0xFFFFFFFF),
            ),
            onTap: (s?.floatingLyricsEnabled ?? false)
                ? () => _pickFloatingLyricsColor(context, ref, s)
                : null,
          ),
          _tile(
            context,
            icon: Icons.contrast,
            title: tr('未播放颜色'),
            trailing: _ColorDot(
              // 0 = 跟随主色：以主色按淡度预览
              color: (s?.floatingLyricsUnplayedColor ?? 0) == 0
                  ? Color(s?.floatingLyricsTextColor ?? 0xFFFFFFFF)
                      .withValues(alpha: 0.38)
                  : Color(s!.floatingLyricsUnplayedColor),
            ),
            onTap: (s?.floatingLyricsEnabled ?? false)
                ? () => _pickFloatingLyricsUnplayedColor(context, ref, s)
                : null,
          ),
          _tile(
            context,
            icon: Icons.opacity_outlined,
            title: tr('不透明度'),
            trailing: _floatingLyricsOpacitySlider(s, n),
          ),
          _tile(
            context,
            icon: Icons.text_fields_outlined,
            title: tr('字号'),
            trailing: _floatingLyricsFontSlider(s, n),
          ),
          _tile(
            context,
            icon: Icons.subtitles_outlined,
            title: tr('副行字号'),
            trailing: _floatingLyricsSecondarySlider(s, n),
          ),
          _switchTile(
            context,
            icon: Icons.font_download_outlined,
            title: tr('使用歌词字体'),
            subtitle: tr('应用播放页设置的自定义歌词字体'),
            value: s?.floatingLyricsUseLyricFont ?? false,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsUseLyricFont(v)
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.translate_outlined,
            title: tr('显示翻译'),
            value: s?.floatingLyricsShowTranslation ?? true,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsShowTranslation(v)
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.skip_next_outlined,
            title: tr('显示下一句'),
            subtitle: tr('在下方提前显示下一句歌词；与「显示翻译」同开时会占三行'),
            value: s?.floatingLyricsShowNextLine ?? false,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsShowNextLine(v)
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.spellcheck_outlined,
            title: tr('显示罗马音'),
            value: s?.floatingLyricsShowRomanization ?? false,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsShowRomanization(v)
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.queue_music_outlined,
            title: tr('显示背景歌词'),
            value: s?.floatingLyricsShowBackground ?? true,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsShowBackground(v)
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.pause_outlined,
            title: tr('暂停时隐藏'),
            value: s?.floatingLyricsHideWhenPaused ?? false,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsHideWhenPaused(v)
                : null,
          ),
          _switchTile(
            context,
            icon: Icons.screen_lock_landscape_outlined,
            title: tr('横屏时隐藏'),
            value: s?.floatingLyricsHideInLandscape ?? false,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsHideInLandscape(v)
                : null,
          ),
          _tile(
            context,
            icon: Icons.width_full_outlined,
            title: tr('宽度'),
            trailing: _floatingLyricsWidthSlider(s, n),
          ),
          _tile(
            context,
            icon: Icons.swap_horiz_outlined,
            title: tr('水平位置'),
            trailing: _floatingLyricsXSlider(context, s, n),
          ),
          _tile(
            context,
            icon: Icons.swap_vert_outlined,
            title: tr('垂直位置'),
            trailing: _floatingLyricsYSlider(context, s, n),
          ),
          _switchTile(
            context,
            icon: Icons.lock_outline,
            title: tr('锁定位置'),
            subtitle: tr('锁定后不可拖动，通知栏解锁'),
            value: s?.floatingLyricsLocked ?? false,
            onChanged: (s?.floatingLyricsEnabled ?? false)
                ? (v) => n.setFloatingLyricsLocked(v)
                : null,
          ),
          _tile(
            context,
            icon: Icons.center_focus_strong_outlined,
            title: tr('重置位置'),
            trailing: const SizedBox.shrink(),
            onTap: (s?.floatingLyricsEnabled ?? false)
                ? () => _resetFloatingLyricsPosition()
                : null,
          ),
        ],
      ),
      ],
      if (PlatformCaps.supportsStatusBarLyrics) ...[
      _sectionHeader(context, tr('通知栏歌词')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.notifications_active_outlined,
            title: tr('通知栏歌词'),
            subtitle: tr('把当前歌词行推送到系统通知栏 / 锁屏展示'),
            value: s?.statusBarLyricsEnabled ?? false,
            onChanged: (v) => n.setStatusBarLyricsEnabled(v),
          ),
        ],
      ),
      ],
    ];
  }

  // ---- 播放 ----
  List<Widget> _playback(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
    bool exclusivePlaying,
  ) {
    return [
      _sectionHeader(context, tr('播放')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.volume_up_outlined,
            title: exclusivePlaying ? tr('音量（直出已锁定）') : tr('音量'),
            trailing: _volumeSlider(s, n, locked: exclusivePlaying),
            subtitle: exclusivePlaying
                ? tr('Bit-perfect / DSD 直出中，音量由 DAC 控制')
                : null,
          ),
          _tile(
            context,
            icon: Icons.bedtime_outlined,
            title: tr('睡眠定时'),
            trailing: const Icon(Icons.chevron_right, size: 18),
            subtitle: ref.watch(sleepTimerProvider).active
                ? tr('已开启，到点淡出并暂停')
                : tr('到点淡出并暂停播放'),
            onTap: () => showSleepTimerSheet(context),
          ),
          _switchTile(
            context,
            icon: Icons.mouse_outlined,
            title: tr('双击播放歌曲'),
            subtitle: tr('开启后双击歌曲播放，关闭后单击播放'),
            value: (s?.songClickAction ?? 'single') == 'double',
            onChanged: (v) => n.setSongClickAction(v ? 'double' : 'single'),
          ),
          _tile(
            context,
            icon: Icons.high_quality_outlined,
            title: tr('播放默认音质'),
            trailing: Text(s?.onlineDefaultQuality ?? '320k'),
            onTap: () => _pickQuality(context, ref, s, isOnline: true),
          ),
          _switchTile(
            context,
            icon: Icons.straighten_outlined,
            title: tr('显示真实音质体积'),
            subtitle: tr('开启后每首在线歌会向音源多请求约 5~8 次（预解析全部档位并探测真实体积），可能触发音源限流；关闭时仅按需解析，体积显示插件自报值'),
            value: s?.showRealQualitySizes ?? false,
            onChanged: (v) => n.setShowRealQualitySizes(v),
          ),
          _tile(
            context,
            icon: Icons.vertical_align_bottom_outlined,
            title: tr('音质回退行为'),
            subtitle: tr('默认音质播放失败时如何切换音质档位'),
            trailing: Text(
              _qualityFallbackLabel(
                s?.onlineQualityFallbackBehavior ?? 'lower',
              ),
            ),
            onTap: () => _pickQualityFallback(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.play_disabled_outlined,
            title: tr('起播失败行为'),
            subtitle: tr('在线音源完全无法播放时的处理方式'),
            trailing: Text(
              _failureBehaviorLabel(
                  s?.onlineFailureBehavior ?? 'stop'),
            ),
            onTap: () => _pickFailureBehavior(context, ref, s),
          ),
          _switchTile(
            context,
            icon: Icons.branding_watermark_outlined,
            title: tr('被打断后自动恢复播放'),
            subtitle: tr('来电、导航语音等临时打断结束后自动继续；被其他应用占用输出时始终暂停并提示'),
            value: s?.autoResumeAfterInterruption ?? true,
            onChanged: (v) => n.setAutoResumeAfterInterruption(v),
          ),
        ],
      ),
      _sectionHeader(context, tr('音量平衡 (ReplayGain)')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.balance_outlined,
            title: tr('音量平衡'),
            subtitle: tr('按歌曲内置的 ReplayGain 标签调整增益，让不同歌曲响度一致；无标签的歌曲保持原音量'),
            value: s?.volumeBalanceEnabled ?? false,
            onChanged: (v) => n.setVolumeBalanceEnabled(v),
          ),
          if (s?.volumeBalanceEnabled ?? false) ...[
            _tile(
              context,
              icon: Icons.tune_outlined,
              title: tr('整体增益偏移'),
              trailing: _gainOffsetSlider(s, n),
            ),
            _switchTile(
              context,
              icon: Icons.shield_outlined,
              title: tr('防削波破音保护'),
              subtitle: tr('增益可能超出 0 dB 极限时自动压低；无峰值标签的歌曲不提升音量'),
              value: s?.volumeBalancePreventClipping ?? true,
              onChanged: (v) => n.setVolumeBalancePreventClipping(v),
            ),
          ],
        ],
      ),
      _sectionHeader(context, tr('输出')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.speaker_outlined,
            title: tr('输出设备'),
            subtitle:
                tr('独占 / 共享 DSP 管线输出到所选设备，可查看设备支持格式'),
            trailing: Text(_outputDeviceLabel(s?.usbExclusiveDeviceId ?? -1)),
            onTap: () => _pickOutputDevice(context, ref),
          ),
          _switchTile(
            context,
            icon: Icons.usb_outlined,
            title: tr('USB 独占输出 (Bit-perfect)'),
            subtitle:
                tr('绕过系统混音器直达 USB DAC，仅本地音乐生效；均衡器与音效走原生 DSP 管线，无 USB DAC 或启动失败时自动回退'),
            value: s?.usbExclusiveOutput ?? false,
            onChanged: (v) => n.setUsbExclusiveOutput(v),
          ),
          _switchTile(
            context,
            icon: Icons.high_quality,
            title: tr('Bit-perfect 直出'),
            subtitle:
                tr('USB 独占输出时按源位深整数直出 DAC：绕过响度归一化/均衡器/音效/音量，仅保留安全限幅；DSD 仍需开启上方「DSD 原生直出」'),
            value: s?.bitPerfectOutput ?? false,
            onChanged: (v) => n.setBitPerfectOutput(v),
          ),
          _switchTile(
            context,
            icon: Icons.graphic_eq_outlined,
            title: tr('DSD 原生直出'),
            subtitle:
                tr('dsf/dff 本地文件按 DoP 打包直送 DSD-DAC，绕过解码与所有音效；需 USB DSD-DAC 支持，失败自动回退普通播放，直出时音量与均衡器自动锁定'),
            value: s?.dsdNativePassthrough ?? false,
            onChanged: (v) => n.setDsdNativePassthrough(v),
          ),
          _switchTile(
            context,
            icon: Icons.link,
            title: tr('无缝播放'),
            subtitle: tr(
                '本地曲目之间不留缝：当前曲播完直接在输出流里接上下一首。'
                '采样率或声道与当前流不一致时自动退回普通切歌'),
            value: s?.gaplessEnabled ?? true,
            onChanged: (v) => n.setGaplessEnabled(v),
          ),
          _switchTile(
            context,
            icon: Icons.swap_horiz,
            title: tr('曲间淡入淡出'),
            subtitle: tr(
                '本地曲目之间按等功率曲线交叠换曲（交叉段本身就是无缝的，'
                '开启时优先于「无缝播放」）；太短的曲子不交叉'),
            value: s?.crossfadeEnabled ?? false,
            onChanged: (v) => n.setCrossfadeEnabled(v),
          ),
          if (s?.crossfadeEnabled ?? false)
            _tile(
              context,
              icon: Icons.timer_outlined,
              title: tr('交叉时长'),
              trailing: Text('${s?.crossfadeSeconds ?? 5} s'),
              onTap: () => _pickCrossfadeSeconds(context, s, n),
            ),
          _switchTile(
            context,
            icon: Icons.content_cut,
            title: tr('跳过静音'),
            subtitle: tr(
                '把过长的静音段压到「保留时长」，多出来的直接跳过（播客/有声书/现场专辑友好）；'
                '只作用于走音效引擎的播放，进度条仍按原曲时间轴显示'),
            value: s?.skipSilenceEnabled ?? false,
            onChanged: (v) => n.setSkipSilenceEnabled(v),
          ),
          if (s?.skipSilenceEnabled ?? false) ...[
            _tile(
              context,
              icon: Icons.vertical_align_center,
              title: tr('静音判定阈值'),
              trailing: Text(
                '${(s?.skipSilenceThresholdDb ?? -45).toStringAsFixed(0)} dB',
              ),
              onTap: () => _pickSkipSilenceThreshold(context, s, n),
            ),
            _tile(
              context,
              icon: Icons.timer_outlined,
              title: tr('静音保留时长'),
              trailing: Text('${s?.skipSilenceKeepMs ?? 500} ms'),
              onTap: () => _pickSkipSilenceKeep(context, s, n),
            ),
          ],
        ],
      ),
      _sectionHeader(context, tr('分享')),
      _CardGroup(
        children: [
          _shareValidityTile(context, s, n),
          _tile(
            context,
            icon: Icons.link_outlined,
            title: tr('分享链接播放失败行为'),
            subtitle:
                tr('通过分享链接播放的歌曲起播失败时：暂停播放，或按来源信息走插件换源重播同一首歌'),
            trailing: Text(
              _sharePlaybackFailureBehaviorLabel(
                s?.sharePlaybackFailureBehavior ?? 'pause',
              ),
            ),
            onTap: () => _pickShareFailureBehavior(context, ref, s),
          ),
        ],
      ),
    ];
  }

  Future<void> _editDlnaRendererName(BuildContext context, WidgetRef ref) async {
    final s = ref.read(settingsProvider).valueOrNull;
    final name = await showModernInputDialog(
      context: context,
      title: tr('设备名称'),
      subtitle: tr('投送端看到的名字'),
      initialValue: (s?.dlnaRendererName ?? '').trim(),
      hintText: tr('弦予音乐'),
      keyboardType: TextInputType.text,
    );
    if (name == null) return;
    final trimmed = name.trim().substring(0, name.trim().length.clamp(0, 40));
    await ref.read(settingsProvider.notifier).setDlnaRendererName(trimmed);
    await ref.read(dlnaCastProvider.notifier).rebuildRendererIfRunning();
  }

  // ---- 下载 ----
  List<Widget> _download(
    BuildContext context,
    WidgetRef ref,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    return [
      _sectionHeader(context, tr('下载')),
      _CardGroup(
        children: [
          if (PlatformCaps.supportsCustomDownloadDir)
            _tile(
              context,
              icon: Icons.folder_outlined,
              title: tr('下载路径'),
              trailing: Text(
                s?.downloadPath == null || s!.downloadPath.isEmpty ? tr('默认') : tr('自定义'),
              ),
              onTap: () => _pickDownloadPath(context, ref, s),
            ),
          _tile(
            context,
            icon: Icons.download_outlined,
            title: tr('下载音质'),
            trailing: Text(s?.downloadQuality ?? '320k'),
            onTap: () => _pickQuality(context, ref, s, isOnline: false),
          ),
          _tile(
            context,
            icon: Icons.movie_outlined,
            title: tr('MV 默认画质'),
            trailing: Text(_mvQualityKeyLabel(s?.onlineDefaultMvQuality ?? '720p')),
            onTap: () => _pickMvQuality(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.movie_creation_outlined,
            title: tr('MV 下载画质'),
            trailing: Text(_mvQualityKeyLabel(s?.downloadMvQuality ?? '720p')),
            onTap: () => _pickDownloadMvQuality(context, ref, s),
          ),
          _switchTile(
            context,
            icon: Icons.lyrics_outlined,
            title: tr('下载独立歌词'),
            subtitle: tr('额外保存一份歌词文件，歌词默认已嵌入音频'),
            value: s?.downloadLyrics ?? false,
            onChanged: (v) => n.setDownloadLyrics(v),
          ),
          if (s?.downloadLyrics ?? false)
            _tile(
              context,
              icon: Icons.format_align_left,
              title: tr('歌词格式'),
              trailing: Text(
                (s?.downloadLyricsFormat ?? 'lrc') == 'txt' ? 'TXT' : 'LRC',
              ),
              onTap: () => _pickLyricsFormat(context, ref, s),
            ),
          _tile(
            context,
            icon: Icons.graphic_eq,
            title: tr('歌词风格'),
            subtitle: tr('同时影响独立歌词与内嵌歌词'),
            trailing: Text(
              (s?.downloadLyricsStyle ?? 'word-by-word') == 'line-by-line'
                  ? tr('逐行')
                  : tr('内置逐字'),
            ),
            onTap: () => _pickLyricsStyle(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.speed_outlined,
            title: tr('批量并发数'),
            trailing: Text('${s?.downloadConcurrency ?? 3}'),
            onTap: () => _pickConcurrency(context, ref, s),
          ),
          _tile(
            context,
            icon: Icons.label_outline,
            title: tr('文件名样式'),
            trailing: Text(
              _fileNameStyleLabel(s?.downloadFileNameStyle ?? 'artist-title'),
            ),
            onTap: () => _pickFileNameStyle(context, ref, s),
          ),
          _switchTile(
            context,
            icon: Icons.file_copy_outlined,
            title: tr('覆盖同名文件'),
            subtitle: tr('关闭时同名文件自动追加序号，避免覆盖'),
            value: s?.overwriteExisting ?? false,
            onChanged: (v) => n.setOverwriteExisting(v),
          ),
          _tile(
            context,
            icon: Icons.download_done_outlined,
            title: tr('下载管理'),
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/download'),
          ),
        ],
      ),
      _sectionHeader(context, tr('下载后嵌入')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.info_outline,
            title: tr('嵌入元数据'),
            value: s?.embedDownloadMetadata ?? true,
            onChanged: (v) => n.setEmbedDownloadMetadata(v),
          ),
          _switchTile(
            context,
            icon: Icons.lyrics_outlined,
            title: tr('嵌入歌词'),
            subtitle: tr('将歌词数据写入音频文件'),
            value: s?.embedDownloadLyrics ?? true,
            onChanged: (v) => n.setEmbedDownloadLyrics(v),
          ),
          _switchTile(
            context,
            icon: Icons.image_outlined,
            title: tr('嵌入封面'),
            value: s?.embedDownloadCover ?? true,
            onChanged: (v) => n.setEmbedDownloadCover(v),
          ),
        ],
      ),
    ];
  }

  // ---- 高级设置 ----
  List<Widget> _advanced(
    BuildContext context,
    AppSettings? s,
    SettingsNotifier n,
  ) {
    return [
      _sectionHeader(context, tr('应用备份')),
      const _AppBackupGroup(),
      _sectionHeader(context, tr('日志')),
      const _LogGroup(),
      _sectionHeader(context, tr('导航')),
      _CardGroup(
        children: [
          _switchTile(
            context,
            icon: Icons.arrow_back_outlined,
            title: tr('预测返回手势'),
            subtitle: tr('开启后所有页面支持安卓系统预测返回动画（需 Android 13+ 手势导航）'),
            value: s?.enablePredictiveBack ?? false,
            onChanged: (v) => _togglePredictiveBack(context, v, n),
          ),
        ],
      ),
    ];
  }

  /// 预测返回开关兜底：安卓 13 以下系统无 OnBackInvokedCallback 链路，
  /// 不给开并提示原因。
  Future<void> _togglePredictiveBack(
    BuildContext context,
    bool v,
    SettingsNotifier n,
  ) async {
    if (!v) {
      await n.setEnablePredictiveBack(false);
      return;
    }
    if (PlatformCaps.isAndroid &&
        await SystemUiChannel.androidSdkInt() < 33) {
      if (context.mounted) showXianYuToast(context, tr('需要 Android 13+'));
      return;
    }
    await n.setEnablePredictiveBack(true);
  }

  List<Widget> _tools(BuildContext context) {
    return [
      _sectionHeader(context, tr('工具')),
      _CardGroup(
        children: [
          _tile(
            context,
            icon: Icons.autorenew,
            title: tr('音频格式转换'),
            subtitle: tr('批量转换 WAV / FLAC / MP3 / AAC / Opus 等'),
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/audio-convert'),
          ),
          _tile(
            context,
            icon: Icons.content_cut,
            title: tr('音频剪辑'),
            subtitle: tr('截取音频区间，支持无损剪切 / 重编码'),
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/audio-trim'),
          ),
          _tile(
            context,
            icon: Icons.lock_open_outlined,
            title: tr('QMC 文件解密'),
            subtitle: tr('解密 QQ 音乐加密文件 .qmcflac / .qmcmp3'),
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/qmc-decrypt'),
          ),
          _tile(
            context,
            icon: Icons.drive_file_rename_outline,
            title: tr('批量重命名'),
            subtitle: tr('按模板批量重命名文件'),
            trailing: const SizedBox.shrink(),
            onTap: () => context.push('/batch-rename'),
          ),
        ],
      ),
    ];
  }
}
