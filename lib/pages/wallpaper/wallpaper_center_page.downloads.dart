part of 'wallpaper_center_page.dart';

class _MyDownloadsTab extends StatefulWidget {
  const _MyDownloadsTab({this.topInset = 0});

  final double topInset;

  @override
  State<_MyDownloadsTab> createState() => _MyDownloadsTabState();
}

class _MyDownloadsTabState extends State<_MyDownloadsTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _downloads = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    _downloadsRevision.addListener(_load);
  }

  @override
  void dispose() {
    _downloadsRevision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('xianyu_downloaded_wallpapers_v1');
      final list = raw == null
          ? <Map<String, dynamic>>[]
          : (jsonDecode(raw) as List)
                .whereType<Map>()
                .map(
                  (m) => Map<String, dynamic>.from(m.cast<String, dynamic>()),
                )
                .toList();
      if (mounted) setState(() => _downloads = list);
    } catch (e) { AppLog.warn('wallpaper', '读取下载列表失败: $e'); }
  }

  Future<void> _remove(int index) async {
    final list = [..._downloads];
    final removed = list.removeAt(index);
    setState(() => _downloads = list);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'xianyu_downloaded_wallpapers_v1',
        jsonEncode(list),
      );
      final localPath = removed['localPath'] as String?;
      if (localPath != null && localPath.isNotEmpty) {
        final f = File(localPath);
        if (await f.exists()) await f.delete();
      }
    } catch (e) { AppLog.warn('wallpaper', '删除下载记录失败: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    if (_downloads.isEmpty) {
      return Center(
        child: Text(
          tr('还没有下载过壁纸'),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(16, 16 + widget.topInset, 16, 16),
      itemCount: _downloads.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final w = _downloads[i];
        final thumb = (w['thumbnailUrl'] as String?) ?? '';
        final title = (w['title'] as String?) ?? '';
        final path = (w['localPath'] as String?) ?? '';
        final exists = File(path).existsSync();
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: thumb.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: thumb,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.image_outlined),
                    ),
                  )
                : const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(Icons.image_outlined),
                  ),
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            exists ? path : tr('本地文件已不存在'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          trailing: IconButton(
            icon: Icon(Icons.delete_outline, color: scheme.error),
            onPressed: () => _remove(i),
          ),
          onTap: () {
            if (exists) {
              Navigator.of(context).push(
                coverPageRoute<void>(
                  context,
                  (_) => _WallpaperPreviewPage(wallpaper: w),
                ),
              );
            }
          },
        );
      },
    );
  }
}
