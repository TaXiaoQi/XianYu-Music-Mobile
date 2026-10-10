part of 'library_folder_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _LibraryFolderPageViews on _LibraryFolderPageState {
  /// 列表底部留白：有迷你播放条时给足空间
  double _listBottomPad(BuildContext context) {
    return (ref.watch(playerProvider.select((s) => s.current != null))
                ? 92.0
                : 16.0) +
        MediaQuery.of(context).padding.bottom;
  }

  Widget _buildPortrait(
    BuildContext context, {
    required List<FolderNodeData> root,
    required List<String> lost,
    required AsyncValue<List<ScanFolder>> foldersAsync,
    required int minDuration,
    required List<Widget> tiles,
  }) {
    final scheme = Theme.of(context).colorScheme;

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: RepaintBoundary(
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(top: GlassTopBar.height(context)),
                child: RefreshIndicator(
                  onRefresh: _onRefresh,
                  child: ListView(
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 8,
                      bottom: _listBottomPad(context),
                    ),
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      _ScanHero(
                        scanning: _scanning,
                        onScan: _startScan,
                        onSafFallback:
                            Platform.isAndroid && !_adding
                                ? _addFolderViaSaf
                                : null,
                      ),
                      if (lost.isNotEmpty) _UnauthorizedBanner(lost: lost),
                      const SizedBox(height: 16),
                      _FilterCard(
                        minDuration: minDuration,
                        onToggle: (v) {
                          final next = v ? _lastDuration : 0;
                          ref
                              .read(settingsProvider.notifier)
                              .setLibraryMinDurationSeconds(next);
                        },
                        onPick: () => _pickMinDuration(minDuration),
                      ),
                      const SizedBox(height: 16),
                      foldersAsync.when(
                        loading: () => const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        error: (e, _) => Text(tr('扫描目录加载失败：{e}', {'e': e}),
                            style: TextStyle(
                                fontSize: 13, color: scheme.error)),
                        data: (folders) => _ScanFoldersCard(
                          folders: folders,
                          lost: lost,
                          adding: _adding,
                          importMode: PlatformCaps.supportsSandboxLibrary,
                          onAddFolder: PlatformCaps.supportsSandboxLibrary
                              ? _importFolder
                              : null,
                          onAdd: _adding
                              ? null
                              : (PlatformCaps.supportsSandboxLibrary
                                  ? _importFiles
                                  : _addFolder),
                          onRemove: _removeFolder,
                          onReauthorize: _reauthorize,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const _RemoteLibraryCard(),
                      if (root.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                          child: Text(
                            tr('已扫描文件夹'),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                        Material(
                          color: appCardFill(context, ref),
                          clipBehavior: Clip.antiAlias,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide.none,
                          ),
                          child: Column(children: tiles),
                        ),
                      ],
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
                  title: Text(tr('文件夹')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 横屏双栏：左列扫描入口与目录管理卡，右列已扫描文件夹树。
  /// [embedded] 为 true 时嵌入音乐库右侧容器（pane）：无自带顶栏/返回键，
  /// 顶部偏移对齐 LibraryPage 的 pane 头部口径（悬浮搜索栏时 statusBar+66）。
  Widget _buildLandscape(
    BuildContext context, {
    bool embedded = false,
    required List<FolderNodeData> root,
    required List<String> lost,
    required AsyncValue<List<ScanFolder>> foldersAsync,
    required int minDuration,
    required List<Widget> tiles,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final bottomPad = _listBottomPad(context);

    final double topPad;
    final Widget topBar;
    if (embedded) {
      final floating = ref.watch(settingsProvider.select(
          (s) => s.valueOrNull?.floatingSearchBar ?? false));
      final statusBar = MediaQuery.paddingOf(context).top;
      final paneTop = floating ? statusBar + 66 : 0.0;
      final headerTop = paneTop + (floating ? 10 : 4);
      topPad = headerTop + _LibraryFolderPageState._kPaneHeaderHeight + 8;
      topBar = Positioned(
        top: headerTop,
        left: floating ? 12 : 0,
        right: floating ? 12 : 0,
        child: _paneHeader(context, floating: floating),
      );
    } else {
      topPad = GlassTopBar.height(context);
      topBar = Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: GlassTopBar(
          leading: const BackButton(),
          title: Text(tr('文件夹')),
        ),
      );
    }

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: RepaintBoundary(
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(top: topPad),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 左列：扫描入口与目录管理
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 0)
                            .copyWith(bottom: bottomPad),
                        children: [
                          _ScanHero(
                            scanning: _scanning,
                            onScan: _startScan,
                            onSafFallback:
                                Platform.isAndroid && !_adding
                                    ? _addFolderViaSaf
                                    : null,
                          ),
                          if (lost.isNotEmpty) _UnauthorizedBanner(lost: lost),
                          const SizedBox(height: 16),
                          _FilterCard(
                            minDuration: minDuration,
                            onToggle: (v) {
                              final next = v ? _lastDuration : 0;
                              ref
                                  .read(settingsProvider.notifier)
                                  .setLibraryMinDurationSeconds(next);
                            },
                            onPick: () => _pickMinDuration(minDuration),
                          ),
                          const SizedBox(height: 16),
                          foldersAsync.when(
                            loading: () => const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Center(
                                  child: CircularProgressIndicator()),
                            ),
                            error: (e, _) => Text(
                                tr('扫描目录加载失败：{e}', {'e': e}),
                                style: TextStyle(
                                    fontSize: 13, color: scheme.error)),
                            data: (folders) => _ScanFoldersCard(
                              folders: folders,
                              lost: lost,
                              adding: _adding,
                              importMode:
                                  PlatformCaps.supportsSandboxLibrary,
                              onAddFolder:
                                  PlatformCaps.supportsSandboxLibrary
                                      ? _importFolder
                                      : null,
                              onAdd: _adding
                                  ? null
                                  : (PlatformCaps.supportsSandboxLibrary
                                      ? _importFiles
                                      : _addFolder),
                              onRemove: _removeFolder,
                              onReauthorize: _reauthorize,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const _RemoteLibraryCard(),
                        ],
                      ),
                    ),
                    // 右列：已扫描文件夹树
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _onRefresh,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(8, 8, 16, 0)
                              .copyWith(bottom: bottomPad),
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            if (root.isNotEmpty) ...[
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(4, 0, 4, 8),
                                child: Text(
                                  tr('已扫描文件夹'),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.primary,
                                  ),
                                ),
                              ),
                              Material(
                                color: appCardFill(context, ref),
                                clipBehavior: Clip.antiAlias,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  side: BorderSide.none,
                                ),
                                child: Column(children: tiles),
                              ),
                            ] else
                              Padding(
                                padding: const EdgeInsets.only(top: 56),
                                child: Center(
                                  child: Text(
                                    tr('暂无扫描结果，添加目录后开始扫描'),
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              topBar,
            ],
          ),
        ),
      ),
    );
  }

  /// 嵌入 pane 的头部：仅标题条（无返回键，导航由左侧栏承担），
  /// 样式对齐 LibraryPage 的 pane 头部（悬浮玻璃/描边两种材质）
  Widget _paneHeader(BuildContext context, {required bool floating}) {
    final scheme = Theme.of(context).colorScheme;
    final content = SizedBox(
      height: _LibraryFolderPageState._kPaneHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            tr('文件夹'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
    if (floating) {
      return FloatingGlassSurface(child: content);
    }
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.06)),
        ),
      ),
      child: content,
    );
  }
}
