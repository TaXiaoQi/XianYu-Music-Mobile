part of 'favorites_page.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

class _SongsTab extends ConsumerStatefulWidget {
  const _SongsTab({
    required this.fav,
    required this.notifier,
    required this.batch,
    this.filter = '',
    this.topInset = 0,
    this.query = '',
    this.sort = _FavSort.none,
    this.result,
    this.showControls = false,
    required this.onOpenSort,
  });

  final FavoritesState fav;
  final FavoritesManager notifier;
  final SongBatchController batch;

  final String filter;

  final double topInset;

  final String query;

  final _FavSort sort;

  final List<FavoriteEntry>? result;

  final bool showControls;

  final VoidCallback onOpenSort;

  @override
  ConsumerState<_SongsTab> createState() => _SongsTabState();
}

extension _SongsTabBatch on _SongsTabState {
  List<FavoriteEntry> _selectedEntries(
      List<FavoriteEntry> entries, SongBatchController batch) {
    return entries.where((e) => batch.selected.contains(e.path)).toList();
  }

  Future<void> _batchPlay(
      List<FavoriteEntry> entries, SongBatchController batch) async {
    final sel = _selectedEntries(entries, batch);
    if (sel.isEmpty) return;
    final items = sel.map((e) => e.toQueueItem()).toList();
    await ref.read(playerProvider.notifier).playQueue(items, startIndex: 0);
    batch.exit();
  }

  Future<void> _batchAddToPlaylist(
      List<FavoriteEntry> entries, SongBatchController batch) async {
    final sel = _selectedEntries(entries, batch);
    if (sel.isEmpty) return;
    final songs = sel.map((e) => importedSongFromQueueItem(e.toQueueItem())).toList();
    await showAddToPlaylistSheet(context, ref, songs);
    batch.exit();
  }

  Future<void> _batchDownload(
      List<FavoriteEntry> entries, SongBatchController batch) async {
    final selected = _selectedEntries(entries, batch);
    if (selected.isEmpty) return;
    final dn = ref.read(downloadProvider.notifier);
    if (!await dn.requireDownloadDir(context)) return;
    final localSkipped = selected.where((e) => !e.isOnline).length;
    var downloadedSkipped = 0;
    final toDownload = <FavoriteEntry>[];
    for (final e in selected.where((e) => e.isOnline)) {
      if (await dn.isAlreadyDownloaded(e.path)) {
        downloadedSkipped++;
      } else {
        toDownload.add(e);
      }
    }
    if (!mounted) return;
    if (localSkipped > 0) {
      showXianYuToast(
          context, tr('已跳过 {n} 首本地歌曲', {'n': localSkipped}));
    }
    if (downloadedSkipped > 0) {
      showXianYuToast(
          context, tr('已跳过 {n} 首已下载歌曲', {'n': downloadedSkipped}));
    }
    if (toDownload.isEmpty) {
      showXianYuToast(context, tr('没有可下载的在线歌曲'));
      return;
    }
    for (final e in toDownload) {
      dn.download(e.toQueueItem());
    }
    showXianYuToast(context, tr('开始下载 {n} 首歌曲', {'n': toDownload.length}));
    batch.exit();
  }

  Future<void> _confirmBatchRemove(
      List<FavoriteEntry> entries, SongBatchController batch) async {
    final sel = _selectedEntries(entries, batch);
    if (sel.isEmpty) return;
    final paths = sel.map((e) => e.path).toList();
    if (await shouldAskFavoriteDeleteScope(ref, paths)) {
      if (!mounted) return;
      final scope = await resolveFavoriteDeleteScope(context, ref, paths);
      if (!mounted) return;
      if (scope == null) return;
      await applyFavoriteDeleteScope(context, ref, scope, paths,
          onLocalRemove: () async {
        for (final e in sel) {
          await widget.notifier.remove(e.path);
        }
      });
      batch.exit();
      return;
    }
    if (!mounted) return;
    final ok = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('移除收藏')),
        content: Text(tr('确定要移除选中的 {n} 首收藏歌曲吗？', {'n': sel.length})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('移除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final e in sel) {
      await widget.notifier.remove(e.path);
    }
    batch.exit();
  }
}
