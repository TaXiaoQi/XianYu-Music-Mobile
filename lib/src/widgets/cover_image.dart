import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../library/saf_channel.dart';
import '../online/cover_proxy.dart';
import '../rust/api.dart';

/// 封面加载组件。
///
/// 传入 [networkUrl] 时加载在线封面（带磁盘缓存）；
/// 传入 [thumbPath]（扫描期回写的缓存路径）时直接展示；
/// 否则经 Rust 缩略图接口取本地封面。全部失败时回退渐变占位。
class CoverImage extends ConsumerStatefulWidget {
  const CoverImage({
    super.key,
    required this.songPath,
    this.networkUrl,
    this.thumbPath,
    this.width = 48,
    this.height = 48,
    this.radius = 12,
    this.gradient,
    this.icon = Icons.music_note,
    this.placeholder,
  });

  final String songPath;

  /// 在线封面 URL；非空时优先使用，跳过本地提取。
  final String? networkUrl;

  /// 已知缩略图路径（如 songs.cover_thumb_path）；文件存在时直接展示，
  /// 跳过 Rust 提取，列表滚动时零额外开销。
  final String? thumbPath;
  final double width;
  final double height;
  final double radius;

  /// 占位渐变；null 时跟随主题色（primary → 深化 primary）。
  final List<Color>? gradient;
  final IconData icon;

  /// 自定义占位（如全屏背景需要无图标占位）；null 时用默认渐变+图标。
  final Widget? placeholder;

  @override
  ConsumerState<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends ConsumerState<CoverImage> {
  // 按歌曲路径缓存缩略图路径，避免重复触发 Rust 提取。
  static final Map<String, String> _cache = {};
  String? _path;

  /// 经后端代理取回的在线封面字节。
  Uint8List? _proxied;

  @override
  void initState() {
    super.initState();
    _load();
    _maybeProxy();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songPath != widget.songPath ||
        oldWidget.networkUrl != widget.networkUrl ||
        oldWidget.thumbPath != widget.thumbPath) {
      _path = null;
      _proxied = null;
      _load();
      _maybeProxy();
    }
  }

  /// 在线封面需要代理时异步拉取。
  void _maybeProxy() {
    final url = widget.networkUrl;
    if (url == null || url.isEmpty) return;
    if (!CoverProxy.needsProxy(url)) return;

    final hit = CoverProxy.cached(url);
    if (hit != null) {
      _proxied = hit;
      return;
    }
    if (CoverProxy.hasFailed(url)) return;

    CoverProxy.fetch(url).then((bytes) {
      if (!mounted || bytes == null) return;
      if (widget.networkUrl != url) return; // 期间已切歌
      setState(() => _proxied = bytes);
    });
  }

  Future<void> _load() async {
    // 在线封面直接走网络，无需 Rust 本地提取。
    if (widget.networkUrl != null && widget.networkUrl!.isNotEmpty) return;
    // 已知缩略图（扫描期回写）直接展示，避免列表滚动时逐行触发 Rust 查询。
    final direct = widget.thumbPath;
    if (direct != null && direct.isNotEmpty && File(direct).existsSync()) {
      _cache[widget.songPath] = direct;
      if (mounted) setState(() => _path = direct);
      return;
    }
    final cached = _cache[widget.songPath];
    if (cached != null) {
      if (mounted) setState(() => _path = cached.isEmpty ? null : cached);
      return;
    }
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final cacheRoot = await ref.read(coverCacheRootProvider.future);
      var p = await getSongCoverThumbnail(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: widget.songPath,
      );
      if (p.isEmpty && SafChannel.isSafPath(widget.songPath)) {
        // SAF 歌曲缓存未命中时无法从 content:// 路径重新提取，
        // 经 fd 自愈提取一次后重查（顺带回写数据库）。
        final healed = await SafChannel.extractCoverToCache(
            widget.songPath, cacheRoot);
        if (healed.isNotEmpty) {
          p = await getSongCoverThumbnail(
            dbPath: dbPath,
            cacheRoot: cacheRoot,
            path: widget.songPath,
          );
        }
      }
      _cache[widget.songPath] = p;
      if (mounted) setState(() => _path = p.isEmpty ? null : p);
    } catch (_) {
      _cache[widget.songPath] = '';
      if (mounted) setState(() => _path = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.networkUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: (url != null && url.isNotEmpty)
            ? _networkImage(url)
            : _localImage(),
      ),
    );
  }

  /// 在线封面：防盗链域名经后端代理，其余直连并走磁盘缓存。
  Widget _networkImage(String url) {
    if (_proxied != null) {
      return Image.memory(
        _proxied!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    }
    // 需要代理但未就绪时显示占位，避免渲染必然失败的请求。
    if (CoverProxy.needsProxy(url)) return _placeholder();
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (_, _) => _placeholder(),
      errorWidget: (_, _, _) => _placeholder(),
    );
  }

  Widget _localImage() {
    final path = _path;
    if (path == null || !File(path).existsSync()) return _placeholder();
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => _placeholder(),
    );
  }

  Widget _placeholder() {
    if (widget.placeholder != null) return widget.placeholder!;
    final scheme = Theme.of(context).colorScheme;
    final colors = widget.gradient ??
        [scheme.primary, Color.lerp(scheme.primary, Colors.black, 0.35)!];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
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
