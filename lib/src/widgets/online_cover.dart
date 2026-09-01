import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../online/cover_proxy.dart';
import 'fade_in.dart';

/// 在线封面。
///
/// 需要防盗链的域名（网易云、B站、QQ、咪咕等）经 Rust 后端代理拉取，
/// 其余直连并走磁盘缓存。加载中或失败时显示占位图标。
class OnlineCover extends StatefulWidget {
  const OnlineCover({
    super.key,
    required this.url,
    this.size = 44,
    this.radius = 6,
  });

  final String? url;
  final double size;
  final double radius;

  @override
  State<OnlineCover> createState() => _OnlineCoverState();
}

class _OnlineCoverState extends State<OnlineCover> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _maybeProxy();
  }

  @override
  void didUpdateWidget(OnlineCover old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _bytes = null;
      _maybeProxy();
    }
  }

  /// 需要代理时异步拉取；直连场景交给 CachedNetworkImage。
  void _maybeProxy() {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    if (!CoverProxy.needsProxy(url)) return;

    // 命中缓存直接同步用，避免闪一下占位。
    final hit = CoverProxy.cached(url);
    if (hit != null) {
      _bytes = hit;
      return;
    }
    if (CoverProxy.hasFailed(url)) return;

    CoverProxy.fetch(url).then((bytes) {
      if (!mounted || bytes == null) return;
      // 拉取期间可能已切换到别的封面。
      if (widget.url != url) return;
      setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    // 按显示尺寸解码：列表行封面很小，整张高清图解码再缩放会拖慢滚动。
    final cw = (widget.size * MediaQuery.of(context).devicePixelRatio).round();

    if (_bytes != null) {
      return _clip(Image.memory(
        _bytes!,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        cacheWidth: cw,
        frameBuilder: CoverFadeIn.frameBuilder(
          placeholder: _placeholder(context),
        ),
        errorBuilder: (_, _, _) => _placeholder(context),
      ));
    }

    if (url == null || url.isEmpty) return _placeholder(context);

    // 需要代理但尚未就绪：显示占位，不渲染会失败的 <img>。
    if (CoverProxy.needsProxy(url)) return _placeholder(context);

    return _clip(CachedNetworkImage(
      imageUrl: url,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.cover,
      memCacheWidth: cw,
      fadeInDuration: CoverFadeIn.duration,
      fadeInCurve: Curves.easeOut,
      fadeOutDuration: const Duration(milliseconds: 250),
      placeholder: (_, _) => _placeholder(context),
      errorWidget: (_, _, _) => _placeholder(context),
    ));
  }

  Widget _clip(Widget child) => ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: child,
      );

  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        size: widget.size * 0.45,
        color: scheme.onPrimaryContainer,
      ),
    );
  }
}
