import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zxing2/qrcode.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/i18n/i18n.dart';
import '../../src/widgets/predictive_dialog_route.dart';

class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});

  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage> {
  CameraController? _controller;
  bool _permissionDenied = false;
  bool _initFailed = false;
  bool _initializing = false;
  bool _handling = false;
  bool _torchOn = false;
  String? _lastCode;
  DateTime? _lastDecodeAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(authProvider).user != null) _initCamera();
    });
    ref.listen(authProvider, (prev, next) {
      final wasIn = prev?.user != null;
      final nowIn = next.user != null;
      if (nowIn && !wasIn) _initCamera();
      if (!nowIn && wasIn) _disposeCamera();
    });
  }

  @override
  void dispose() {
    _disposeCamera();
    super.dispose();
  }

  Future<void> _initCamera() async {
    if (_initializing || _controller != null) return;
    _initializing = true;
    if (mounted) setState(() {});
    try {
      final status = await Permission.camera.request();
      if (status.isDenied || status.isPermanentlyDenied) {
        if (mounted) setState(() => _permissionDenied = true);
        return;
      }
      if (!mounted) return;
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _initFailed = true);
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      _controller = controller;
      await controller.initialize();
      await controller.startImageStream(_onImageStream);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _initFailed = true);
    } finally {
      _initializing = false;
    }
  }

  Future<void> _disposeCamera() async {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  String? _extractCode(String? raw) {
    if (raw == null) return null;
    final t = raw.trim();
    const prefix = 'xianyumusic://tvlogin/';
    final source = t.startsWith(prefix) ? t.substring(prefix.length).trim() : t;
    if (!RegExp(r'^[0-9a-fA-F]{16,32}$').hasMatch(source)) return null;
    return source.toLowerCase();
  }

  void _onImageStream(CameraImage image) {
    if (_handling || image.planes.isEmpty) return;
    final now = DateTime.now();
    final last = _lastDecodeAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastDecodeAt = now;
    try {
      final plane = image.planes.first;
      final source = _YPlaneLuminanceSource(
        plane.bytes,
        image.width,
        image.height,
        plane.bytesPerRow,
      );
      final result = QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source)));
      final code = _extractCode(result.text);
      if (code == null || code == _lastCode) return;
      _lastCode = code;
      _handleCode(code);
    } catch (_) {}
  }

  Future<void> _resume() async {
    final c = _controller;
    if (c != null && c.value.isInitialized) {
      try {
        if (!c.value.isStreamingImages) await c.startImageStream(_onImageStream);
      } catch (_) {}
    } else {
      await _initCamera();
    }
    if (mounted) {
      setState(() {
        _permissionDenied = false;
        _initFailed = false;
      });
      _lastCode = null;
    }
  }

  Future<bool> _confirm(String title, String content, {String ok = '确定', String cancel = '取消', bool danger = false}) async {
    return await showPredictiveDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(cancel),
              ),
              danger
                  ? TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text(ok),
                    )
                  : FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text(ok),
                    ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _handleCode(String code) async {
    _handling = true;
    final c = _controller;
    if (c != null) {
      try {
        if (c.value.isStreamingImages) await c.stopImageStream();
      } catch (_) {}
    }
    if (!mounted) {
      _handling = false;
      return;
    }
    final notifier = ref.read(authProvider.notifier);
    final user = ref.read(authProvider).user;

    if (user == null) {
      final go = await showPredictiveDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) => AlertDialog(
          title: Text(tr('请先登录')),
          content: Text(tr('扫码确认登录桌面端，需要先登录你的弦予音乐账号。')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: Text(tr('去登录')),
            ),
          ],
        ),
      );
      _handling = false;
      if (!mounted) return;
      if (go == true) {
        context.pop();
        context.push('/account');
        return;
      }
      await _resume();
      return;
    }

    TvLoginScanInfo? info;
    String? scanError;
    try {
      info = await notifier.scanTvLogin(code);
    } catch (e) {
      scanError = e.toString();
    }
    if (!mounted) {
      _handling = false;
      return;
    }
    if (scanError != null || info == null) {
      await showPredictiveDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) => AlertDialog(
          title: Text(tr('扫码失败')),
          content: Text(scanError ?? tr('二维码无效或已过期')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: Text(tr('知道了')),
            ),
          ],
        ),
      );
      _handling = false;
      if (mounted) await _resume();
      return;
    }

    final confirmed = await context.push<bool>('/tv-login-confirm', extra: {
      'code': code,
      'info': info,
    });
    if (!mounted) {
      _handling = false;
      return;
    }
    if (confirmed != true) {
      _handling = false;
      await _resume();
      return;
    }

    await showPredictiveDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        title: Text(tr('登录成功')),
        content: Text(tr('桌面端已登录你的弦予音乐账号。')),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(dctx).pop();
              if (mounted) context.pop();
            },
            child: Text(tr('完成')),
          ),
        ],
      ),
    );
  }

  void _toggleTorch() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      final next = !_torchOn;
      await c.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchOn = next);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).user;
    final loggedIn = user != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: !loggedIn
                ? _loginRequiredView(context)
                : _permissionDenied
                    ? _permissionView(context)
                    : _initFailed
                        ? _genericErrorView(context)
                        : _cameraPreview(context),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => context.pop(),
                    icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                    tooltip: tr('返回'),
                  ),
                  Expanded(
                    child: Text(
                      tr('扫码登录'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (loggedIn)
                    IconButton(
                      onPressed: _toggleTorch,
                      icon: Icon(
                        _torchOn ? Icons.flash_on : Icons.flash_off,
                        color: Colors.white,
                      ),
                      tooltip: tr('闪光灯'),
                    )
                  else
                    const SizedBox(width: 48),
                ],
              ),
            ),
          ),
          if (loggedIn)
            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _ScanMaskPainter()))),
          if (loggedIn)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.qr_code_2, color: Colors.white70, size: 28),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 48),
                        child: Text(
                          tr('将桌面端登录页的二维码对准取景框'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cameraPreview(BuildContext context) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final ar = c.value.aspectRatio;
    final boxAspect = portrait ? (ar == 0 ? 1 : 1 / ar) : ar;
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: 1000,
          height: boxAspect == 0 ? 1000 : 1000 / boxAspect,
          child: CameraPreview(c),
        ),
      ),
    );
  }

  Widget _loginRequiredView(BuildContext context) {
    return Container(
      color: Colors.black,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock_outline, color: Colors.white60, size: 52),
          const SizedBox(height: 16),
          Text(
            tr('请先登录'),
            style: const TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            tr('请登录你的弦予音乐账号后，再扫描桌面端二维码确认登录。'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
            ),
            onPressed: () {
              context.pop();
              context.push('/account');
            },
            child: Text(tr('去登录')),
          ),
        ],
      ),
    );
  }

  Widget _permissionView(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography_outlined, color: Colors.white54, size: 48),
          const SizedBox(height: 16),
          Text(
            tr('需要相机权限才能扫码'),
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            tr('请在系统设置中允许弦予音乐访问相机。'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              final ok = await _confirm(tr('重新授权'), tr('前往系统设置开启相机权限？'), ok: tr('去设置'));
              if (!mounted) return;
              if (ok) {
                await openAppSettings();
                if (mounted) await _resume();
              }
            },
            child: Text(tr('授权相机')),
          ),
        ],
      ),
    );
  }

  Widget _genericErrorView(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_off_outlined, color: Colors.white54, size: 48),
          const SizedBox(height: 16),
          Text(
            tr('无法启动相机'),
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            tr('请稍后重试，或返回后重新进入扫码。'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () async {
              if (mounted) {
                setState(() {
                  _permissionDenied = false;
                  _initFailed = false;
                });
                await _resume();
              }
            },
            child: Text(tr('重试')),
          ),
        ],
      ),
    );
  }
}

class _YPlaneLuminanceSource extends LuminanceSource {
  final Int8List _data;
  final int _rowStride;

  _YPlaneLuminanceSource(Uint8List data, super.width, super.height, this._rowStride)
      : _data = Int8List.fromList(data);

  @override
  Int8List getRow(int y, Int8List? row) {
    final w = width;
    final result = (row != null && row.length >= w) ? row : Int8List(w);
    final start = y * _rowStride;
    for (var x = 0; x < w; x++) {
      result[x] = _data[start + x];
    }
    return result;
  }

  @override
  Int8List getMatrix() {
    final w = width;
    final h = height;
    final result = Int8List(w * h);
    for (var y = 0; y < h; y++) {
      final src = y * _rowStride;
      final dst = y * w;
      for (var x = 0; x < w; x++) {
        result[dst + x] = _data[src + x];
      }
    }
    return result;
  }
}

class _ScanMaskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const box = 258.0;
    final centerX = size.width / 2;
    final centerY = size.height / 2 - 40;
    final rect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: box,
      height: box,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(22));

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(rrect),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    final paint = Paint()
      ..color = const Color(0xFFEC4141)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.square;
    const cornerLen = 28.0;
    final corners = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft];
    for (final c in corners) {
      final right = c.dx >= centerX;
      final bottom = c.dy >= centerY;
      final p = Path();
      p
        ..moveTo(right ? c.dx - cornerLen : c.dx, c.dy)
        ..lineTo(right ? c.dx : c.dx + cornerLen, c.dy);
      p
        ..moveTo(c.dx, bottom ? c.dy - cornerLen : c.dy)
        ..lineTo(c.dx, bottom ? c.dy : c.dy + cornerLen);
      canvas.drawPath(p, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
