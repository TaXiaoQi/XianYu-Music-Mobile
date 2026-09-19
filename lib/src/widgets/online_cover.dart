import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../online/cover_proxy.dart';
import 'fade_in.dart';

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

  int _attempts = 0;
  Timer? _retryTimer;

  static const _maxAttempts = 4;

  @override
  void initState() {
    super.initState();
    _maybeProxy();
  }

  @override
  void didUpdateWidget(OnlineCover old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _attempts = 0;
      _bytes = null;
      _maybeProxy();
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  void _maybeProxy() {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    if (!CoverProxy.needsProxy(url)) return;

    final hit = CoverProxy.cached(url);
    if (hit != null) {
      _bytes = hit;
      return;
    }
    if (CoverProxy.hasFailed(url)) {
      _scheduleRetryIfPossible(url);
      return;
    }

    CoverProxy.fetch(url).then((bytes) {
      if (!mounted) return;
      if (widget.url != url) return;
      if (bytes != null) {
        _attempts = 0;
        setState(() => _bytes = bytes);
        return;
      }
      _scheduleRetryIfPossible(url);
    });
  }

  void _scheduleRetryIfPossible(String url) {
    if (_attempts >= _maxAttempts) return;
    _attempts++;
    _retryTimer?.cancel();
    _retryTimer = Timer(CoverProxy.retryAfter, () {
      if (!mounted || widget.url != url) return;
      _maybeProxy();
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
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
