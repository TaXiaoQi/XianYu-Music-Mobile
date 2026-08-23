import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../library/library_provider.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';
import '../rust/music/types.dart';

/// 歌曲信息弹窗：查看 + 标签编辑 + 歌词编辑（对齐桌面端 SongInfoModal）。
Future<void> showSongInfoDialog(BuildContext context, WidgetRef ref,
    QueueItem item) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _SongInfoDialog(
      item: item,
      editable: !item.isOnline,
      ref: ref,
    ),
  );
}

class _SongInfoDialog extends ConsumerStatefulWidget {
  const _SongInfoDialog({
    required this.item,
    required this.editable,
    required this.ref,
  });

  final QueueItem item;
  final bool editable;
  final WidgetRef ref;

  @override
  ConsumerState<_SongInfoDialog> createState() => _SongInfoDialogState();
}

enum _InfoMode { view, edit, lyrics }

class _SongInfoDialogState extends ConsumerState<_SongInfoDialog> {
  _InfoMode _mode = _InfoMode.view;
  bool _saving = false;
  String? _error;
  Map<String, dynamic>? _detail;

  // 标签编辑表单
  late final _titleCtrl =
      TextEditingController(text: widget.item.title);
  late final _artistCtrl =
      TextEditingController(text: widget.item.artist);
  late final _albumCtrl =
      TextEditingController(text: widget.item.album);
  final _trackCtrl = TextEditingController();
  final _discCtrl = TextEditingController();
  final _yearCtrl = TextEditingController();

  // 歌词编辑
  final _lyricsCtrl = TextEditingController();
  LyricsStorageSource _lyricsSource = LyricsStorageSource.empty;
  String? _lyricsSourcePath;
  bool _lyricsLoaded = false;

  @override
  void initState() {
    super.initState();
    if (widget.editable) _loadDetail();
  }

  Future<void> _loadDetail() async {
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final json = await getSongDetail(dbPath: dbPath, path: widget.item.path);
      final j = jsonDecode(json) as Map<String, dynamic>;
      _trackCtrl.text = (j['trackNumber'] as String?) ?? '';
      _discCtrl.text = (j['discNumber'] as String?) ?? '';
      _yearCtrl.text = (j['year'] as String?) ?? '';
      if (mounted) setState(() => _detail = j);
    } catch (_) {}
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _albumCtrl.dispose();
    _trackCtrl.dispose();
    _discCtrl.dispose();
    _yearCtrl.dispose();
    _lyricsCtrl.dispose();
    super.dispose();
  }

  Future<void> _enterLyricsMode() async {
    setState(() {
      _mode = _InfoMode.lyrics;
      _error = null;
    });
    if (!_lyricsLoaded) {
      try {
        final json = await getSongLyricsForEdit(path: widget.item.path);
        final j = jsonDecode(json) as Map<String, dynamic>;
        _lyricsCtrl.text = (j['lyrics'] as String?) ?? '';
        _lyricsSource = LyricsStorageSource.values.firstWhere(
          (v) => v.name == (j['source'] as String?)?.toLowerCase(),
          orElse: () => LyricsStorageSource.empty,
        );
        _lyricsSourcePath = j['sourcePath'] as String?;
        _lyricsLoaded = true;
        if (mounted) setState(() {});
      } catch (e) {
        if (mounted) {
          setState(() => _error = '读取歌词失败：$e');
        }
      }
    }
  }

  String _sourceLabel() {
    switch (_lyricsSource) {
      case LyricsStorageSource.embedded:
        return '内嵌歌词';
      case LyricsStorageSource.sidecar:
        return '侧车文件（LRC）';
      case LyricsStorageSource.empty:
        return '暂无歌词';
    }
  }

  Future<void> _saveLyrics() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await saveSongLyrics(
        path: widget.item.path,
        lyrics: _lyricsCtrl.text,
        // 空内容 + 原本无侧车路径 → 保存为内嵌
        source: _lyricsCtrl.text.trim().isEmpty &&
                _lyricsSource == LyricsStorageSource.empty
            ? LyricsStorageSource.embedded
            : _lyricsSource,
        sourcePath: _lyricsSourcePath,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _mode = _InfoMode.view;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('歌词已保存')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _saveTags() async {
    if (_saving) return;
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '歌名不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final payload = {
        'title': title,
        'artist': _artistCtrl.text.trim(),
        'album': _albumCtrl.text.trim(),
        if (_trackCtrl.text.trim().isNotEmpty)
          'trackNumber': _trackCtrl.text.trim(),
        if (_discCtrl.text.trim().isNotEmpty)
          'discNumber': _discCtrl.text.trim(),
        if (_yearCtrl.text.trim().isNotEmpty) 'year': _yearCtrl.text.trim(),
      };
      await saveSongInfo(
          dbPath: dbPath, path: widget.item.path, payloadJson: jsonEncode(payload));
      // 刷新音乐库列表（歌名/歌手/专辑立即生效）
      widget.ref.read(libraryProvider.notifier).load();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _mode = _InfoMode.view;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('歌曲信息已保存')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(switch (_mode) {
        _InfoMode.view => '歌曲信息',
        _InfoMode.edit => '编辑歌曲信息',
        _InfoMode.lyrics => '编辑歌词',
      }),
      content: SizedBox(
        width: double.maxFinite,
        child: _mode == _InfoMode.view
            ? _buildView(scheme)
            : _mode == _InfoMode.edit
                ? _buildTagEditor(scheme)
                : _buildLyricsEditor(scheme),
      ),
      actions: _buildActions(scheme),
    );
  }

  List<Widget> _buildActions(ColorScheme scheme) {
    switch (_mode) {
      case _InfoMode.view:
        return [
          if (widget.editable)
            TextButton(
              onPressed: () =>
                  setState(() { _mode = _InfoMode.edit; _error = null; }),
              child: const Text('编辑信息'),
            ),
          if (widget.editable)
            TextButton(
              onPressed: _enterLyricsMode,
              child: const Text('编辑歌词'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ];
      case _InfoMode.edit:
        return [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _saving ? null : _saveTags,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存'),
          ),
        ];
      case _InfoMode.lyrics:
        return [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _saving ? null : _saveLyrics,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存'),
          ),
        ];
    }
  }

  Widget _buildView(ColorScheme scheme) {
    final item = widget.item;

    String sizeText = '--';
    String quality = item.onlineQuality ?? '--';
    String pathText = item.path;
    String sourceText = '在线音源';

    if (!item.isOnline) {
      sourceText = '本地音乐';
      quality = '原始音质';
      try {
        final f = File(item.path);
        if (f.existsSync()) {
          final bytes = f.lengthSync();
          sizeText = '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
          if (item.durationMs > 0) {
            final kbps = bytes * 8 ~/ item.durationMs;
            quality = '$kbps kbps';
          }
        }
      } catch (_) {}
      final ext = item.path.split('.').last.toLowerCase();
      if (ext.isNotEmpty && ext.length <= 5) {
        sourceText = '本地音乐 · ${ext.toUpperCase()}';
      }
    } else if (item.path.startsWith('lx://')) {
      sourceText = '洛雪音源 · ${item.source ?? ''}';
    } else {
      sourceText = 'MusicFree 插件';
    }

    final duration = item.durationMs ~/ 1000;
    final durationText =
        '${(duration ~/ 60).toString().padLeft(2, '0')}:${(duration % 60).toString().padLeft(2, '0')}';

    final rows = <Widget>[
      _row('标题', item.title, scheme),
      _row('歌手', item.artist.isEmpty ? '未知歌手' : item.artist, scheme),
      _row('专辑', item.album.isEmpty ? '未知专辑' : item.album, scheme),
      _row('时长', durationText, scheme),
      _row('来源', sourceText, scheme),
      _row('音质', quality, scheme),
      _row('大小', sizeText, scheme),
    ];

    // 本地歌曲补充详情（流派/年份/音轨/碟号）
    final detail = _detail;
    if (detail != null) {
      final genre = detail['genre'] as String?;
      final year = detail['year'] as String?;
      final track = detail['trackNumber'] as String?;
      final disc = detail['discNumber'] as String?;
      if (genre != null && genre.isNotEmpty) {
        rows.add(_row('流派', genre, scheme));
      }
      if (year != null && year.isNotEmpty) rows.add(_row('年份', year, scheme));
      if (track != null && track.isNotEmpty) {
        rows.add(_row('音轨', track, scheme));
      }
      if (disc != null && disc.isNotEmpty) rows.add(_row('碟号', disc, scheme));
    }

    rows.add(_row('路径', pathText, scheme, selectable: true));

    if (_error != null) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(_error!,
            style: TextStyle(color: scheme.error, fontSize: 12)),
      ));
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Widget _buildTagEditor(ColorScheme scheme) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _field('标题', _titleCtrl),
          const SizedBox(height: 10),
          _field('歌手', _artistCtrl),
          const SizedBox(height: 10),
          _field('专辑', _albumCtrl),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _field('音轨号', _trackCtrl, number: true)),
              const SizedBox(width: 10),
              Expanded(child: _field('碟号', _discCtrl, number: true)),
              const SizedBox(width: 10),
              Expanded(child: _field('年份', _yearCtrl, number: true)),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!,
                  style: TextStyle(color: scheme.error, fontSize: 12)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '修改将写入音频文件标签（ID3/Vorbis/MP4）',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLyricsEditor(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.lyrics_outlined,
                size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              _lyricsLoaded ? _sourceLabel() : '读取歌词中…',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 300,
          child: TextField(
            controller: _lyricsCtrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: InputDecoration(
              hintText: '[00:00.00] 歌词内容…',
              border: const OutlineInputBorder(),
              isDense: true,
              enabled: !_saving,
            ),
            style: const TextStyle(fontSize: 12.5, height: 1.5),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_error!,
                style: TextStyle(color: scheme.error, fontSize: 12)),
          ),
      ],
    );
  }

  Widget _field(String label, TextEditingController ctrl, {bool number = false}) {
    return TextField(
      controller: ctrl,
      enabled: !_saving,
      keyboardType: number ? TextInputType.number : null,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      style: const TextStyle(fontSize: 13),
    );
  }
}

Widget _row(String label, String value, ColorScheme scheme,
    {bool selectable = false}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 48,
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: selectable
              ? SelectableText(
                  value,
                  style: const TextStyle(fontSize: 12.5),
                )
              : Text(
                  value,
                  style: const TextStyle(fontSize: 12.5),
                ),
        ),
      ],
    ),
  );
}
