import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/i18n/i18n.dart';
import '../../src/widgets/predictive_dialog_route.dart';

/// 扫码登录：扫描桌面端登录页二维码，确认后在该桌面端完成登录。
///
/// 扫描到二维码后暂停相机，走「标记已扫描 → 弹窗确认 → 服务端签发凭证」流程；
/// 未登录时引导先登录账号。
class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});

  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage> {
  MobileScannerController? _controller;
  bool _permissionDenied = false;
  bool _handling = false;
  bool _torchOn = false;
  String? _lastCode;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// 从扫码结果中解析登录 code（桌面端二维码内容）。
  String? _extractCode(String? raw) {
    if (raw == null) return null;
    final t = raw.trim();
    const prefix = 'xianyumusic://tvlogin/';
    final source = t.startsWith(prefix) ? t.substring(prefix.length).trim() : t;
    // 服务端 random_hex(16) 实际生成 32 位 hex，兼容 16/32 位。
    if (!RegExp(r'^[0-9a-fA-F]{16,32}$').hasMatch(source)) return null;
    return source.toLowerCase();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handling) return;
    for (final barcode in capture.barcodes) {
      final code = _extractCode(barcode.rawValue);
      if (code == null) continue;
      if (code == _lastCode) return;
      _lastCode = code;
      _handleCode(code);
      return;
    }
  }

  Future<void> _resume() async {
    final c = _controller;
    if (c == null || !mounted) return;
    try {
      await c.start();
    } catch (_) {}
    if (mounted) {
      setState(() => _permissionDenied = false);
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
        await c.stop();
      } catch (_) {}
    }
    if (!mounted) {
      _handling = false;
      return;
    }
    final notifier = ref.read(authProvider.notifier);
    final user = ref.read(authProvider).user;

    // 未登录：引导去登录。
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

    // 标记已扫描，拿到被扫桌面端信息。
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

    // 进入确认登录页（展示设备信息 + 同意协议 + 确认）。
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

    // 确认成功：桌面端已登录，提示后返回。
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
    if (c == null) return;
    try {
      final next = !_torchOn;
      await c.toggleTorch();
      setState(() => _torchOn = next);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).user;
    // 未登录时不启动相机，改为登录引导，杜绝「未登录也可调用扫码框」。
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
                    : MobileScanner(
                        controller: _controller,
                        onDetect: _onDetect,
                        errorBuilder: (context, error) {
                          // 相机权限被拒时切换到授权引导视图。
                          if (error.errorCode ==
                              MobileScannerErrorCode.permissionDenied) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted && !_permissionDenied) {
                                setState(() => _permissionDenied = true);
                              }
                            });
                            return _permissionView(context);
                          }
                          return _genericErrorView(context);
                        },
                      ),
          ),
          // 顶部栏
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
          // 取景框遮罩
          if (loggedIn)
            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _ScanMaskPainter()))),
          // 底部提示
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

  /// 未登录引导：禁止扫码，提示先登录账号。
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
                // 打开系统设置；返回后尝试重跑相机
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

  /// 非权限类相机错误（初始化失败等）。
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
                setState(() => _permissionDenied = false);
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

/// 取景框遮罩：四周压暗、中央留透明方形扫码区，四角画红色高亮框。
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

    // 四周压暗（减去中央取景区）。
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(rrect),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    // 四角高亮框。
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
      // 横边
      p
        ..moveTo(right ? c.dx - cornerLen : c.dx, c.dy)
        ..lineTo(right ? c.dx : c.dx + cornerLen, c.dy);
      // 竖边
      p
        ..moveTo(c.dx, bottom ? c.dy - cornerLen : c.dy)
        ..lineTo(c.dx, bottom ? c.dy : c.dy + cornerLen);
      canvas.drawPath(p, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}