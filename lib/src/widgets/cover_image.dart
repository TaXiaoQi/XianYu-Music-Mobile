import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../library/saf_channel.dart';
import '../online/cover_proxy.dart';
import '../rust/api.dart';
import 'fade_in.dart';

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
    this.cacheWidth,
    this.highQuality = false,
  });

  final String songPath;

  final String? networkUrl;

  final String? thumbPath;
  final double width;
  final double height;
  final double radius;

  final int? cacheWidth;

  final bool highQuality;

  final List<Color>? gradient;
  final IconData icon;

  final Widget? placeholder;

  static Future<void> prewarm({
    required String songPath,
    String? networkUrl,
    required String dbPath,
    required String cacheRoot,
  }) =>
      _CoverImageState._prewarm(
          songPath: songPath,
          networkUrl: networkUrl,
          dbPath: dbPath,
          cacheRoot: cacheRoot);

  @override
  ConsumerState<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends ConsumerState<CoverImage> {
  static final Map<String, String> _cache = {};
  static final Set<String> _prewarmed = {};
  String? _path;

  Uint8List? _proxied;

  String? _thumbPath;

  int? _loadedCacheWidth;

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
        oldWidget.thumbPath != widget.thumbPath ||
        oldWidget.highQuality != widget.highQuality) {
      _path = null;
      _proxied = null;
      _thumbPath = null;
      _loadedCacheWidth = null;
      _load();
      _maybeProxy();
    }
  }

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
      if (widget.networkUrl != url) return;
      setState(() => _proxied = bytes);
    });
  }

  Future<void> _load() async {
    if (widget.networkUrl != null && widget.networkUrl!.isNotEmpty) return;
    final direct = widget.thumbPath;
    if (!widget.highQuality &&
        direct != null &&
        direct.isNotEmpty &&
        File(direct).existsSync()) {
      _cache[widget.songPath] = direct;
      _setPath(direct);
      return;
    }
    final cacheKey =
        widget.highQuality ? '${widget.songPath}\u0000full' : widget.songPath;
    if (widget.highQuality) unawaited(_ensureThumbPath());
    final cached = _cache[cacheKey];
    if (cached != null) {
      _setPath(cached.isEmpty ? null : cached);
      return;
    }
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final cacheRoot = await ref.read(coverCacheRootProvider.future);
      Future<String> Function({
        required String dbPath,
        required String cacheRoot,
        required String path,
      }) fetch = widget.highQuality ? getSongCover : getSongCoverThumbnail;
      var p = await fetch(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: widget.songPath,
      );
      if (p.isEmpty && SafChannel.isSafPath(widget.songPath)) {
        final healed = await SafChannel.extractCoverToCache(
            widget.songPath, cacheRoot);
        if (healed.isNotEmpty) {
          p = await fetch(
            dbPath: dbPath,
            cacheRoot: cacheRoot,
            path: widget.songPath,
          );
        }
      }
      _cache[cacheKey] = p;
      _setPath(p.isEmpty ? null : p);
    } catch (_) {
      _cache[cacheKey] = '';
      _setPath(null);
    }
  }

  Future<void> _ensureThumbPath() async {
    if (_thumbPath != null) return;
    final cached = _cache[widget.songPath];
    if (cached != null) {
      if (cached.isNotEmpty && File(cached).existsSync()) {
        if (mounted) setState(() => _thumbPath = cached);
      }
      return;
    }
    final direct = widget.thumbPath;
    if (direct != null && direct.isNotEmpty && File(direct).existsSync()) {
      if (mounted) setState(() => _thumbPath = direct);
      return;
    }
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final cacheRoot = await ref.read(coverCacheRootProvider.future);
      final p = await getSongCoverThumbnail(
          dbPath: dbPath, cacheRoot: cacheRoot, path: widget.songPath);
      if (p.isEmpty) return;
      _cache[widget.songPath] = p;
      if (mounted && File(p).existsSync()) setState(() => _thumbPath = p);
    } catch (_) {}
  }

  void _setPath(String? p) {
    if (!mounted) return;
    setState(() => _path = p);
    if (p == null || p.isEmpty || widget.highQuality) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _path == null || _path!.isEmpty) return;
      final provider = ResizeImage.resizeIfNeeded(
        _cacheWidth,
        null,
        FileImage(File(_path!)),
      );
      precacheImage(provider, context).catchError((_) => <void>[]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.networkUrl;
    final content = (url != null && url.isNotEmpty)
        ? _networkImage(url)
        : _localImage();
    final finiteW = widget.width.isFinite ? widget.width : null;
    final finiteH = widget.height.isFinite ? widget.height : null;
    final box = (finiteW == null && finiteH == null)
        ? Align(alignment: Alignment.center, child: content)
        : SizedBox(
            width: finiteW,
            height: finiteH,
            child: content,
          );
    if (widget.radius <= 0) return box;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      clipBehavior: Clip.antiAlias,
      child: box,
    );
  }

  Widget _networkImage(String url) {
    if (_proxied != null) {
      return Image.memory(
        _proxied!,
        fit: BoxFit.cover,
        cacheWidth: _cacheWidth,
        frameBuilder: CoverFadeIn.frameBuilder(placeholder: _placeholder()),
        errorBuilder: (_, _, _) => _placeholder(),
      );
    }
    if (CoverProxy.needsProxy(url)) return _placeholder();
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: _cacheWidth,
      fadeInDuration: CoverFadeIn.duration,
      fadeInCurve: Curves.easeOut,
      fadeOutDuration: const Duration(milliseconds: 250),
      placeholder: (_, _) => _placeholder(),
      errorWidget: (_, _, _) => _placeholder(),
    );
  }

  Widget _localImage() {
    final path = _path;
    if (path == null || !File(path).existsSync()) {
      final thumb = _thumbPath;
      if (thumb != null && File(thumb).existsSync()) {
        return Image.file(
          File(thumb),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          frameBuilder: CoverFadeIn.frameBuilder(placeholder: _placeholder()),
          errorBuilder: (_, _, _) => _placeholder(),
        );
      }
      return _placeholder();
    }
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      cacheWidth: _cacheWidth,
      gaplessPlayback: true,
      frameBuilder: CoverFadeIn.frameBuilder(placeholder: _thumbOrPlaceholder()),
      errorBuilder: (_, _, _) => _placeholder(),
    );
  }

  Widget _thumbOrPlaceholder() {
    final thumb = _thumbPath;
    if (thumb != null && File(thumb).existsSync()) {
      return Image.file(File(thumb), fit: BoxFit.cover, gaplessPlayback: true);
    }
    return _placeholder();
  }

  int? get _cacheWidth {
    if (widget.cacheWidth != null) return widget.cacheWidth;
    return _loadedCacheWidth ??= _computeCacheWidth();
  }

  static const List<int> _sizeSlots = <int>[
    32,
    48,
    64,
    96,
    128,
    192,
    256,
  ];

  int? _computeCacheWidth() {
    final w = widget.width;
    if (!w.isFinite || w <= 0) return null;
    final px = w * MediaQuery.of(context).devicePixelRatio;
    if (!px.isFinite) return null;
    if (widget.highQuality) return px.round();
    int slot = px.round().clamp(1, 256);
    for (final s in _sizeSlots) {
      if (slot <= s) {
        slot = s;
        break;
      }
    }
    return slot.clamp(1, 256);
  }

  static Future<void> _prewarm({
    required String songPath,
    String? networkUrl,
    required String dbPath,
    required String cacheRoot,
  }) async {
    final url = networkUrl;
    if (url != null && url.isNotEmpty) {
      if (url.startsWith('data:')) return;
      if (!_prewarmed.add('url\u0000$url')) return;
      if (CoverProxy.needsProxy(url)) {
        if (CoverProxy.cached(url) != null || CoverProxy.hasFailed(url)) return;
        await CoverProxy.fetch(url);
        return;
      }
      await _warmNetworkImage(url);
      return;
    }
    final fullKey = '$songPath\u0000full';
    final hadFull = _cache[fullKey] != null;
    if (!hadFull && !_prewarmed.add(fullKey)) return;
    unawaited(_prewarmThumbPath(songPath, dbPath, cacheRoot));
    if (hadFull) return;
    try {
      final p = await getSongCover(
          dbPath: dbPath, cacheRoot: cacheRoot, path: songPath);
      if (p.isNotEmpty) _cache[fullKey] = p;
    } catch (_) {}
  }

  static Future<void> _warmNetworkImage(String url) async {
    final c = Completer<void>();
    final stream =
        CachedNetworkImageProvider(url).resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (_, _) {
        if (!c.isCompleted) c.complete();
      },
      onError: (_, _) {
        if (!c.isCompleted) c.complete();
      },
    );
    stream.addListener(listener);
    try {
      await c.future.timeout(const Duration(seconds: 15));
    } catch (_) {
    } finally {
      stream.removeListener(listener);
    }
  }

  static Future<void> _prewarmThumbPath(
      String songPath, String dbPath, String cacheRoot) async {
    if (_cache[songPath] != null) return;
    try {
      final p = await getSongCoverThumbnail(
          dbPath: dbPath, cacheRoot: cacheRoot, path: songPath);
      if (p.isNotEmpty) _cache[songPath] = p;
    } catch (_) {}
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
