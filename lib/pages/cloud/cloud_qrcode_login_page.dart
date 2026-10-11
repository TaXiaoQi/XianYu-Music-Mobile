import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/i18n/i18n.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/press_scale.dart';

/// 扫码登录页（qrCode 范式）。
///
/// createQrLogin 拿二维码内容渲染，2s 轮询 pollQrLogin；
/// 抛 CloudException（过期/已取消）时停止轮询并提供刷新入口。
class CloudQrcodeLoginPage extends ConsumerStatefulWidget {
  const CloudQrcodeLoginPage({super.key, required this.providerId});

  final String providerId;

  @override
  ConsumerState<CloudQrcodeLoginPage> createState() =>
      _CloudQrcodeLoginPageState();
}

class _CloudQrcodeLoginPageState extends ConsumerState<CloudQrcodeLoginPage> {
  late final CloudProvider _provider;
  CloudQrLoginSession? _session;
  Timer? _timer;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    _create();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    _timer?.cancel();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await _provider.createQrLogin();
      if (!mounted) return;
      setState(() {
        _session = s;
        _loading = false;
      });
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} 二维码获取失败: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is CloudException ? e.message : tr('二维码获取失败');
      });
    }
  }

  Future<void> _poll() async {
    final s = _session;
    if (s == null || _saving || _timer == null) return;
    try {
      final account = await _provider.pollQrLogin(s);
      if (account == null || !mounted) return;
      _timer?.cancel();
      setState(() => _saving = true);
      await CloudCredentialsStore.instance.saveAccount(account);
      if (!mounted) return;
      showXianYuToast(context, tr('绑定成功'));
      context.pop();
    } on CloudException catch (e) {
      _timer?.cancel();
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      // 网络抖动等瞬时错误：保持轮询。
      AppLog.debug('cloud', '${_provider.id} 扫码轮询异常: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      tr('使用{name}App 扫码登录', {'name': _provider.displayName}),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: _buildQr(context, scheme),
                    ),
                    const SizedBox(height: 20),
                    if (_error != null) ...[
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: scheme.error),
                      ),
                      const SizedBox(height: 12),
                      PressableScale(
                        pressScale: 0.95,
                        child: FilledButton(
                          onPressed: _create,
                          child: Text(tr('刷新二维码')),
                        ),
                      ),
                    ] else
                      Text(
                        _loading ? tr('正在获取二维码...') : tr('扫码后在手机上确认登录'),
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(_provider.displayName),
            ),
          ),
          if (_saving)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black26,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQr(BuildContext context, ColorScheme scheme) {
    if (_loading) {
      return const SizedBox(
        width: 220,
        height: 220,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final s = _session;
    if (s == null) {
      return SizedBox(
        width: 220,
        height: 220,
        child: Center(
          child: Text(
            _error ?? tr('二维码获取失败'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: scheme.error),
          ),
        ),
      );
    }
    return QrImageView(
      data: s.qrContent,
      size: 220,
      backgroundColor: Colors.white,
    );
  }
}
