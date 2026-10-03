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
          child: const Icon(Icons.library_music_rounded,
              color: Colors.white, size: 40),
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
                      fontSize: 15, fontWeight: FontWeight.w600),
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
            child:   Text(tr('看不到部分歌曲？试试系统选择器添加目录')),
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

    return Material(
      color: appCardFill(context, ref),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: ListTile(
        leading: Icon(Icons.timer_outlined, color: scheme.primary),
        title:   Text(tr('按时长过滤')),
        subtitle: Text(
          minDuration > 0
              ? tr('已过滤时长小于 {n} 秒的音频文件', {'n': minDuration})
              : tr('可过滤掉时长过短的音频文件（点按调整阈值）'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        trailing: Switch(
          value: minDuration > 0,
          onChanged: onToggle,
        ),
        onTap: onPick,
      ),
    );
  }
}

class _ScanFoldersCard extends ConsumerWidget {
  const _ScanFoldersCard({
    required this.folders,
    required this.lost,
    required this.adding,
    this.importMode = false,
    required this.onAdd,
    required this.onRemove,
    required this.onReauthorize,
  });

  final List<ScanFolder> folders;
  final List<String> lost;
  final bool adding;
  final bool importMode;
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
                Icon(Icons.folder_copy_outlined,
                    size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  folders.isEmpty ? tr('扫描目录') : '扫描目录 · ${folders.length}',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
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
              ],
            ),
          ),
          if (folders.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text(
                importMode
                    ? tr('沙盒目录（下载/导入的音乐）会自动扫描；也可点击右上角「+」导入音频文件')
                    : tr('还没有扫描目录，点击右上角「+」选择包含音乐的文件夹\n（仅首次需要授予音乐读取权限）'),
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            )
          else
            for (var i = 0; i < folders.length; i++)
              Builder(builder: (context) {
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
                        IconButton(
                          tooltip: tr('重新授权'),
                          icon: Icon(Icons.key,
                              color: scheme.error, size: 20),
                          onPressed: () => onReauthorize(f.path),
                        ),
                      IconButton(
                        tooltip: tr('移除'),
                        icon: Icon(Icons.delete_outline,
                            color: scheme.error, size: 20),
                        onPressed: () => onRemove(f.path),
                      ),
                    ],
                  ),
                );
              }),
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
                      fontWeight: FontWeight.w500),
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

    return Material(
      color: appCardFill(context, ref),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: ListTile(
        leading: Icon(Icons.cloud_outlined, color: scheme.primary),
        title:   Text(tr('远程音乐库 (WebDAV)')),
        subtitle: Text(
          tr('访问 WebDAV 服务器上的音乐资源'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        trailing: Icon(Icons.chevron_right, color: scheme.outline),
        onTap: () => context.push('/remote-library'),
      ),
    );
  }
}
