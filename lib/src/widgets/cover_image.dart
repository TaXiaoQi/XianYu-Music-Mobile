import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../rust/api.dart';

/// 封面加载组件：经 Rust 缩略图接口取本地缓存封面，无封面/失败时回退渐变占位。
class CoverImage extends ConsumerStatefulWidget {
  const CoverImage({
    super.key,
    required this.songPath,
    this.width = 48,
    this.height = 48,
    this.radius = 12,
    this.gradient = const [Color(0xFFEC4141), Color(0xFFFF8A5C)],
    this.icon = Icons.music_note,
  });

  final String songPath;
  final double width;
  final double height;
  final double radius;
  final List<Color> gradient;
  final IconData icon;

  @override
  ConsumerState<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends ConsumerState<CoverImage> {
  // 按歌曲路径缓存缩略图路径，避免重复触发 Rust 提取。
  static final Map<String, String> _cache = {};
  String? _path;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songPath != widget.songPath) {
      _path = null;
      _load();
    }
  }

  Future<void> _load() async {
    final cached = _cache[widget.songPath];
    if (cached != null) {
      if (mounted) setState(() => _path = cached.isEmpty ? null : cached);
      return;
    }
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final cacheRoot = await ref.read(appDataDirProvider.future);
      final p = await getSongCoverThumbnail(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: widget.songPath,
      );
      _cache[widget.songPath] = p;
      if (mounted) setState(() => _path = p.isEmpty ? null : p);
    } catch (_) {
      _cache[widget.songPath] = '';
      if (mounted) setState(() => _path = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: (path != null && File(path).existsSync())
            ? Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(),
              )
            : _placeholder(),
      ),
    );
  }

  Widget _placeholder() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: widget.gradient,
        ),
      ),
      child: Center(
        child: Icon(
          widget.icon,
          color: Colors.white.withValues(alpha: 0.85),
          size: widget.width.clamp(0, 200) * 0.4,
        ),
      ),
    );
  }
}
