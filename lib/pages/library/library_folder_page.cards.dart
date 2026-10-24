part of 'library_folder_page.dart';

class _ScanHero extends StatelessWidget {
  const _ScanHero({
    required this.scanning,
    required this.onScan,
    this.onSafFallback,
  });

  final bool scanning;
  final VoidCallback onScan;
  final VoidCallback? onSafFallback;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = Color.lerp(scheme.primary, Colors.white, 0.35)!;
    return Column(
      children: [
        const SizedBox(height: 20),
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.3, -0.4),
              colors: [light, scheme.primary],
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.35),
                blurRadius: 22,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(
            Icons.library_music_rounded,
            color: Colors.white,
            size: 40,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          tr('一键扫描手机内的歌曲文件'),
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: 220,
          height: 46,
          child: FilledButton(
            onPressed: scanning ? null : onScan,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              shape: const StadiumBorder(),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (scanning)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.play_arrow_rounded, size: 22),
                const SizedBox(width: 6),
                Text(
                  scanning ? tr('正在扫描…') : tr('开始扫描'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (onSafFallback != null) ...[
          const SizedBox(height: 4),
          TextButton(
            onPressed: onSafFallback,
            style: TextButton.styleFrom(
              foregroundColor: scheme.primary,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: Text(tr('看不到部分歌曲？试试系统选择器添加目录')),
          ),
        ],
      ],
    );
  }
}

class _FilterCard extends ConsumerWidget {
  const _FilterCard({
    required this.minDuration,
    required this.onToggle,
    required this.onPick,
  });

  final int minDuration;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    final card = Material(
      color: appCardFill(context, ref),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: ListTile(
        leading: Icon(Icons.timer_outlined, color: scheme.primary),
        title: Text(tr('按时长过滤')),
        subtitle: Text(
          minDuration > 0
              ? tr('已过滤时长小于 {n} 秒的音频文件', {'n': minDuration})
              : tr('可过滤掉时长过短的音频文件（点按调整阈值）'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        trailing: Switch(value: minDuration > 0, onChanged: onToggle),
        onTap: onPick,
      ),
    );
    return PressableScale(child: card);
  }
}

class _ScanFoldersCard extends ConsumerWidget {
  const _ScanFoldersCard({
    required this.folders,
    required this.lost,
    required this.adding,
    this.importMode = false,
    this.onAddFolder,
    required this.onAdd,
    required this.onRemove,
    required this.onReauthorize,
  });

  final List<ScanFolder> folders;
  final List<String> lost;
  final bool adding;
  final bool importMode;

  /// 沙盒模式（鸿蒙）的「导入文件夹」入口：folder picker 批量物化。
  final VoidCallback? onAddFolder;
  final VoidCallback? onAdd;
  final void Function(String path) onRemove;
  final void Function(String path) onReauthorize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: appCardFill(context, ref),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Icon(
                  Icons.folder_copy_outlined,
                  size: 20,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  folders.isEmpty ? tr('扫描目录') : '扫描目录 · ${folders.length}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (onAddFolder != null)
                  PressableScale(
                    pressScale: 0.88,
                    child: IconButton(
                      tooltip: tr('导入文件夹'),
                      onPressed: adding ? null : onAddFolder,
                      icon: const Icon(Icons.folder_open),
                    ),
                  ),
                PressableScale(
                  pressScale: 0.88,
                  child: IconButton(
                    tooltip: importMode ? tr('导入音频文件') : tr('添加目录'),
                    onPressed: onAdd,
                    icon: adding
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add),
                  ),
                ),
              ],
            ),
          ),
          if (folders.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text(
                importMode
                    ? tr('沙盒目录（下载/导入的音乐）会自动扫描；右上角可导入文件夹或音频文件')
                    : tr('还没有扫描目录，点击右上角「+」选择包含音乐的文件夹\n（仅首次需要授予音乐读取权限）'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            )
          else
            for (var i = 0; i < folders.length; i++)
              Builder(
                builder: (context) {
                  final f = folders[i];
                  final isLost = lost.contains(f.path);
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      isLost ? Icons.folder_off : Icons.folder,
                      color: isLost ? scheme.error : scheme.primary,
                    ),
                    title: FutureBuilder<String>(
                      future: _friendlyFolderName(f.path),
                      builder: (context, snap) => Text(
                        snap.data ?? f.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    subtitle: isLost
                        ? Text(
                            tr('授权已失效，点击钥匙重新授权'),
                            style: TextStyle(fontSize: 12, color: scheme.error),
                          )
                        : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isLost)
                          PressableScale(
                            pressScale: 0.88,
                            child: IconButton(
                              tooltip: tr('重新授权'),
                              icon: Icon(
                                Icons.key,
                                color: scheme.error,
                                size: 20,
                              ),
                              onPressed: () => onReauthorize(f.path),
                            ),
                          ),
                        PressableScale(
                          pressScale: 0.88,
                          child: IconButton(
                            tooltip: tr('移除'),
                            icon: Icon(
                              Icons.delete_outline,
                              color: scheme.error,
                              size: 20,
                            ),
                            onPressed: () => onRemove(f.path),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
        ],
      ),
    );
  }
}

Future<String> _friendlyFolderName(String path) async {
  final hit = _folderNameCache[path];
  if (hit != null) return hit;
  if (!SafChannel.isSafTree(path)) return path;
  final name = await SafChannel.friendlyTreeName(path);
  _folderNameCache[path] = name;
  return name;
}

final Map<String, String> _folderNameCache = {};

class _UnauthorizedBanner extends StatelessWidget {
  final List<String> lost;
  const _UnauthorizedBanner({required this.lost});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.folder_off, size: 20, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('{n} 个目录授权已失效，可在下方重新授权', {'n': lost.length}),
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w500,
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

class _RemoteLibraryCard extends ConsumerWidget {
  const _RemoteLibraryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    final card = Material(
      color: appCardFill(context, ref),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: ListTile(
        leading: Icon(Icons.cloud_outlined, color: scheme.primary),
        title: Text(tr('远程音乐库 (WebDAV)')),
        subtitle: Text(
          tr('访问 WebDAV 服务器上的音乐资源'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        trailing: Icon(Icons.chevron_right, color: scheme.outline),
        onTap: () {
          // 横屏：内嵌右容器详情面板；竖屏走路由
          if (useLandscape(ref)) {
            ref.read(landscapeDetailProvider.notifier).state =
                const LandscapeRemoteLibraryDetail();
          } else {
            context.push('/remote-library');
          }
        },
      ),
    );
    return PressableScale(child: card);
  }
}

/// 网盘入口卡：逐个已绑定账号直达浏览页，无绑定时引导去绑定页。
/// 已绑定网盘卡：横屏文件夹页里点网盘项内嵌到右列展示已选文件夹
/// （桌面端树形态）；竖屏保持点按直接打开全盘浏览页
class _CloudDrivesCard extends ConsumerStatefulWidget {
  const _CloudDrivesCard({this.selectedKey, this.onSelect, this.rev});

  /// 当前右列正在展示的网盘键（'providerId|accountId'），null = 未选中
  final String? selectedKey;

  /// 横屏点选回调：传入网盘项 = 展示其已选文件夹，传 null = 收起。
  /// 竖屏不传，保持原全屏浏览行为
  final ValueChanged<MapEntry<CloudProvider, CloudAccount>?>? onSelect;

  /// 已选文件夹版本号：右列选择器保存/移除后变化，据此重读计数
  final int? rev;

  @override
  ConsumerState<_CloudDrivesCard> createState() => _CloudDrivesCardState();
}

class _CloudDrivesCardState extends ConsumerState<_CloudDrivesCard> {
  List<MapEntry<CloudProvider, CloudAccount>> _bound = const [];
  Map<String, int> _selectedCounts = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant _CloudDrivesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.rev != oldWidget.rev) _reload();
  }

  Future<void> _reload() async {
    final bound = <MapEntry<CloudProvider, CloudAccount>>[];
    final counts = <String, int>{};
    for (final p in cloudProviders) {
      final accounts = await CloudCredentialsStore.instance.accountsFor(p.id);
      for (final a in accounts) {
        bound.add(MapEntry(p, a));
        final selected = await CloudFolderSelectionStore.instance.pathsFor(
          p.id,
          a.accountId,
        );
        counts['${p.id}|${a.accountId}'] = selected.length;
      }
    }
    if (!mounted) return;
    setState(() {
      _bound = bound;
      _selectedCounts = counts;
      _loading = false;
    });
  }

  /// 浏览页返回后重载，反映绑定变化
  Future<void> _openBrowser(CloudProvider p, CloudAccount a) async {
    await context.push('/cloud/browser/${p.id}?account=${a.accountId}');
    _reload();
  }

  Future<void> _openBind() async {
    // 横屏：内嵌右容器详情面板，面板收起后重读绑定列表；竖屏走路由
    if (useLandscape(ref)) {
      ProviderSubscription<LandscapeDetail?>? sub;
      sub = ref.listenManual(landscapeDetailProvider, (prev, next) {
        if (next != null) return;
        sub?.close();
        _reload();
      });
      ref.read(landscapeDetailProvider.notifier).state =
          const LandscapeCloudManageDetail();
      return;
    }
    await context.push('/cloud');
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = Material(
      color: appCardFill(context, ref),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: _loading
          ? ListTile(
              leading: Icon(Icons.cloud_outlined, color: scheme.primary),
              title: Text(tr('网盘')),
            )
          : Column(
              children: [
                for (final e in _bound)
                  Builder(
                    builder: (context) {
                      final key = '${e.key.id}|${e.value.accountId}';
                      final count = _selectedCounts[key] ?? 0;
                      final inline = widget.onSelect != null;
                      final selected = inline && widget.selectedKey == key;
                      return ListTile(
                        selected: selected,
                        leading: Icon(
                          Icons.cloud_outlined,
                          color: scheme.primary,
                        ),
                        title: Text(e.key.displayName),
                        subtitle: Text(
                          // 桌面端树形态：已选文件夹数；未选时展示账号昵称
                          count > 0
                              ? tr('{n} 个文件夹', {'n': '$count'})
                              : e.value.nickname,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: Icon(
                          selected ? Icons.expand_less : Icons.chevron_right,
                          color: scheme.outline,
                        ),
                        onTap: () => inline
                            ? widget.onSelect!(selected ? null : e)
                            : _openBrowser(e.key, e.value),
                      );
                    },
                  ),
                ListTile(
                  leading: Icon(
                    _bound.isEmpty ? Icons.add_link : Icons.settings_outlined,
                    color: scheme.primary,
                  ),
                  title: Text(_bound.isEmpty ? tr('绑定网盘') : tr('管理网盘')),
                  subtitle: _bound.isEmpty
                      ? Text(
                          tr('绑定后可在此浏览网盘音乐'),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      : null,
                  trailing: Icon(Icons.chevron_right, color: scheme.outline),
                  onTap: _openBind,
                ),
              ],
            ),
    );
    return PressableScale(child: card);
  }
}

/// 横屏文件夹页右列：单个网盘的已选文件夹管理（对齐桌面端树形态——
/// 网盘节点下直接列出已选文件夹，点选择器保存/移除后经 onChanged
/// 通知宿主 bump rev，左右两列同步重读）。
class _CloudSelectedFoldersPane extends ConsumerStatefulWidget {
  const _CloudSelectedFoldersPane({
    super.key,
    required this.drive,
    required this.rev,
    required this.onClose,
    required this.onChanged,
  });

  final MapEntry<CloudProvider, CloudAccount> drive;
  final int rev;
  final VoidCallback onClose;
  final VoidCallback onChanged;

  @override
  ConsumerState<_CloudSelectedFoldersPane> createState() =>
      _CloudSelectedFoldersPaneState();
}

class _CloudSelectedFoldersPaneState
    extends ConsumerState<_CloudSelectedFoldersPane> {
  List<String> _paths = const [];
  Map<String, String> _names = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _CloudSelectedFoldersPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rev != widget.rev) _load();
  }

  Future<void> _load() async {
    final p = widget.drive.key;
    final a = widget.drive.value;
    final paths = await CloudFolderSelectionStore.instance.pathsFor(
      p.id,
      a.accountId,
    );
    final names = await CloudFolderNameCache.instance.namesFor(
      p.id,
      a.accountId,
    );
    if (!mounted) return;
    setState(() {
      _paths = paths;
      _names = names;
      _loading = false;
    });
  }

  /// id 型盘的 path 是 id 串：优先名称缓存，回退末段/原串
  String _nameOf(String path) {
    final n = _names[path];
    if (n != null && n.isNotEmpty) return n;
    final idx = path.lastIndexOf('/');
    return idx >= 0 && idx < path.length - 1 ? path.substring(idx + 1) : path;
  }

  Future<void> _remove(String path) async {
    final p = widget.drive.key;
    final a = widget.drive.value;
    await CloudFolderSelectionStore.instance.setPaths(
      p.id,
      a.accountId,
      _paths.where((e) => e != path).toList(),
    );
    widget.onChanged();
  }

  Future<void> _pick() async {
    final p = widget.drive.key;
    final a = widget.drive.value;
    // 横屏：内嵌右容器详情面板，面板收起后通知宿主刷新；竖屏走路由
    if (useLandscape(ref)) {
      ProviderSubscription<LandscapeDetail?>? sub;
      sub = ref.listenManual(landscapeDetailProvider, (prev, next) {
        if (next != null) return;
        sub?.close();
        widget.onChanged();
      });
      ref.read(landscapeDetailProvider.notifier).state =
          LandscapeCloudPickerDetail(providerId: p.id, accountId: a.accountId);
      return;
    }
    await context.push('/cloud/folder-picker/${p.id}?account=${a.accountId}');
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playerVisible = ref.watch(
      playerProvider.select((s) => s.current != null),
    );
    final bottomPad =
        (playerVisible ? 92.0 : 16.0) + MediaQuery.paddingOf(context).bottom;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        8,
        8,
        16,
        0,
      ).copyWith(bottom: bottomPad),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        // 标题行：收起 + 网盘名 + 选择文件夹入口
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: tr('返回本地目录'),
                onPressed: widget.onClose,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${widget.drive.key.displayName} · ${tr('已选文件夹')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _loading ? null : _pick,
                icon: const Icon(Icons.folder_open, size: 18),
                label: Text(tr('选择文件夹'), style: const TextStyle(fontSize: 13)),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 34),
                ),
              ),
            ],
          ),
        ),
        Material(
          color: appCardFill(context, ref),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide.none,
          ),
          child: _loading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ),
                )
              : _paths.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 28,
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.folder_off_outlined,
                        size: 28,
                        color: scheme.outline,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        tr('未选择文件夹'),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tr('未选择时将扫描整个网盘，点右上角「选择文件夹」可缩小范围'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    for (final path in _paths)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.folder_outlined,
                          color: scheme.primary,
                        ),
                        title: Text(
                          _nameOf(path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: tr('移除'),
                          icon: const Icon(Icons.delete_outline, size: 20),
                          color: scheme.error,
                          onPressed: () => _remove(path),
                        ),
                      ),
                  ],
                ),
        ),
        if (!_loading && _paths.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 13, color: scheme.outline),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    tr('范围内的文件夹才会进入「网盘音乐」列表'),
                    style: TextStyle(fontSize: 11.5, color: scheme.outline),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
