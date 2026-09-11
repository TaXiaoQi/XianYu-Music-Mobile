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
    this.cacheWidth,
    this.highQuality = false,
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

  /// 固定解码宽度（像素）；非空时覆盖按显示尺寸自动计算的 cacheWidth。
  /// 用于飞封面等宽度逐帧变化的场景，避免每帧重解码导致闪烁/模糊。
  final int? cacheWidth;

  /// 高清模式：本地封面走 800px 高清提取（详情页大封面），默认缩略图 150px。
  final bool highQuality;

  /// 占位渐变；null 时跟随主题色（primary → 深化 primary）。
  final List<Color>? gradient;
  final IconData icon;

  /// 自定义占位（如全屏背景需要无图标占位）；null 时用默认渐变+图标。
  final Widget? placeholder;

  /// 后台预取封面：委托 State 侧静态实现（封面路径/字节缓存挂在 State 上）。
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
  // 按歌曲路径缓存缩略图路径，避免重复触发 Rust 提取。
  // 高清模式用独立 key，避免与缩略图缓存互相污染。
  static final Map<String, String> _cache = {};
  // 已预取的封面 key（本地 full key / 在线代理 URL），防止重复提取。
  static final Set<String> _prewarmed = {};
  String? _path;

  /// 经后端代理取回的在线封面字节。
  Uint8List? _proxied;

  /// 缩略图过渡位（高清模式专用）：高清图提取/解码未就绪时先展示，
  /// 避免播放页大封面切歌闪默认音符占位。
  String? _thumbPath;

  /// 已锁定的解码宽度（像素）：歌未变时保持首次计算值。播放页横屏顶/底栏
  /// 进退（AutoHideChrome 的 AnimatedSize 收缩让位）会使封面显示尺寸逐帧
  /// 变化，若 cacheWidth 跟着变会触发图片重新解码 + CoverFadeIn 重新淡入，
  /// 表现为封面闪烁；锁定后仅做显示缩放、不重解码。
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
    // 高清模式不直接使用扫描期缩略图，需走高清提取。
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
    // 高清大封面（播放页）：正式图走 800px 提取，较慢。先并行确保缩略图
    // 过渡位，高清图就绪前先出缩略图，避免切歌闪默认音符占位。
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
        // SAF 歌曲缓存未命中时无法从 content:// 路径重新提取，
        // 经 fd 自愈提取一次后重查（顺带回写数据库）。
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

  /// 解析缩略图过渡位（仅高清模式）：优先静态缓存与扫描期缩略图路径
  /// （同步命中零开销），否则走一次 150px 快速提取；提取失败不写负缓存，
  /// 交给正式加载链路自愈，避免污染列表渲染。
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

  /// 设定缩略图路径并更新 UI；解析成功后把渲染端同款 provider 送入 Flutter
  /// 图片缓存做预解码，使行还在 cacheExtent（滚动即将进入可视区）时解码就已
  /// 完成，避免首次绘制时的解码卡顿。post-frame 回调内 MediaQuery 依赖已就绪。
  ///
  /// 高清模式（详情页大图）与网络封面按需解码，不预载。
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
    // 仅对有限宽高套紧约束的 SizedBox；无穷宽高（如 Hero 飞行封面、全屏占满卡片）
    // 用 Align 填充：父级有界则填满，父级无界（0.0<=h<=Infinity）则收缩子级，
    // 避免 RenderConstrainedBox 拿到无限尺寸触发布局断言。
    final finiteW = widget.width.isFinite ? widget.width : null;
    final finiteH = widget.height.isFinite ? widget.height : null;
    final box = (finiteW == null && finiteH == null)
        ? Align(alignment: Alignment.center, child: content)
        : SizedBox(
            width: finiteW,
            height: finiteH,
            child: content,
          );
    // radius <= 0 时没必要套 ClipRRect（全屏背景等整张展示），省一层剪裁。
    if (widget.radius <= 0) return box;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      clipBehavior: Clip.antiAlias,
      child: box,
    );
  }

  /// 在线封面：防盗链域名经后端代理，其余直连并走磁盘缓存。
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
    // 需要代理但未就绪时显示占位，避免渲染必然失败的请求。
    if (CoverProxy.needsProxy(url)) return _placeholder();
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      // 与本地封面一致按显示尺寸低清解码，避免在线大图全分辨率解码
      // 拖垮列表滚动内存与 GPU 上采样。
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
      // 正式图未就绪：已有缩略图先行展示（高清模式切歌过渡）。
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

  /// 正式图解码期间的过渡占位：优先已就绪的缩略图（缩略图 → 高清图无缝
  /// 衔接，不回退默认音符），其次默认渐变+音符占位。
  Widget _thumbOrPlaceholder() {
    final thumb = _thumbPath;
    if (thumb != null && File(thumb).existsSync()) {
      return Image.file(File(thumb), fit: BoxFit.cover, gaplessPlayback: true);
    }
    return _placeholder();
  }

  /// 生效的解码宽度：外部显式指定优先；否则取已锁定的首次计算值
  /// （首次访问时按当时显示尺寸计算并锁定，歌不变则不随显示尺寸重算）。
  int? get _cacheWidth {
    if (widget.cacheWidth != null) return widget.cacheWidth;
    return _loadedCacheWidth ??= _computeCacheWidth();
  }

  /// 按“显示尺寸 × 屏幕密度”解码，避免把整张高清封面解码后再缩放到小格子，
  /// 大幅降低列表滚动的内存与 GPU 上采样开销（RWAS 同款“按显示尺寸解码”）。
  ///
  /// 全屏/占满卡片会以 `double.infinity` 作宽度（本组件的下沉安全网，如首页
  /// 正在播放轮播图、全屏背景封面）：此时尺寸不可用于解码，返回 null 表示
  /// 交给引擎按原图解码，否则 `Infinity.round()` 会抛 UnsupportedError。
  ///
  /// 非高清（列表缩略图）模式强制封顶低清解码宽度：即使封面在网格/大行里
  /// 显示得较大，也最多按 256px 解码，滚动时只搬运低清图层；高清模式
  /// （详情页大封面）不封顶，保留清晰度。
  ///
  /// 缩略图宽度量化到尺寸槽位（就近取大的幂次档），使同一封面在列表行/网格/
  /// 歌手头像等“尺寸相近”的位置共用 Flutter 图片缓存里同一张解码图，避免按
  /// 每个精确显示宽度分别解码多份（RwaS SizeSlotCache 同款“就近复用大图”）。
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
    // 就近取大的槽位（RwaS 口径：相同距离取更大的槽，避免 256 解码被旧 192 命中发糊）。
    int slot = px.round().clamp(1, 256);
    for (final s in _sizeSlots) {
      if (slot <= s) {
        slot = s;
        break;
      }
    }
    return slot.clamp(1, 256);
  }

  /// 后台预取封面实现（无 UI 依赖）：本地歌解析高清封面路径写入静态
  /// [_cache]，在线歌预拉封面字节（防盗链域）或磁盘缓存（直连域）。供
  /// 播放引擎在起播后预取「下一首」封面，切歌时封面组件同步命中，
  /// 不闪默认音符占位。
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
      // 直连封面：触发一次下载写入 flutter_cache_manager 磁盘缓存（与渲染端
      // CachedNetworkImage 共用），切歌时渲染端磁盘命中，免网络等待期占位。
      await _warmNetworkImage(url);
      return;
    }
    final fullKey = '$songPath\u0000full';
    final hadFull = _cache[fullKey] != null;
    if (!hadFull && !_prewarmed.add(fullKey)) return;
    // 缩略图过渡位始终确保就绪：切歌瞬间高清图解码期间也要有真封面可看。
    unawaited(_prewarmThumbPath(songPath, dbPath, cacheRoot));
    if (hadFull) return;
    try {
      final p = await getSongCover(
          dbPath: dbPath, cacheRoot: cacheRoot, path: songPath);
      if (p.isNotEmpty) _cache[fullKey] = p;
    } catch (_) {}
  }

  /// 预热直连网络封面：经 [CachedNetworkImageProvider] 触发一次下载，使
  /// 字节进入 flutter_cache_manager 磁盘缓存（与渲染端共用），渲染端挂载
  /// 时直接磁盘命中。
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
      // 超时/失败：放弃本次预热，渲染端按原链路自理。
    } finally {
      stream.removeListener(listener);
    }
  }

  /// 预取缩略图路径；仅成功结果入缓存（不写负缓存，避免影响列表自愈链路）。
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
