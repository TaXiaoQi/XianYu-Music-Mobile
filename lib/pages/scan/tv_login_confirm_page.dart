import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/user_agreement.dart';
import '../../src/i18n/i18n.dart';

/// 扫码确认登录页：展示被扫桌面端（应用名/设备ID/位置）与当前登录账号，
/// 勾选同意用户协议后点击确认，为桌面端签发登录凭证。
///
/// 样式对齐 QQ/微信扫码登录确认。成功确认后以 `Navigator.pop(true)` 返回扫码页。
class TvLoginConfirmPage extends ConsumerStatefulWidget {
  const TvLoginConfirmPage({super.key, required this.code, required this.info});

  final String code;
  final TvLoginScanInfo info;

  @override
  ConsumerState<TvLoginConfirmPage> createState() => _TvLoginConfirmPageState();
}

class _TvLoginConfirmPageState extends ConsumerState<TvLoginConfirmPage> {
  bool _agreed = false;
  bool _loading = false;

  String get _appName {
    final n = widget.info.appName.trim();
    return n.isNotEmpty ? n : tr('弦予.桌面版');
  }

  String get _deviceId {
    final d = widget.info.deviceId.trim();
    return d.isNotEmpty ? d : tr('未知');
  }

  String get _location {
    final l = widget.info.location.trim();
    return l.isNotEmpty ? l : tr('未知');
  }

  Future<void> _confirm() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await ref.read(authProvider.notifier).confirmTvLogin(widget.code);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e is AuthException ? e.message : tr('登录失败')),
        duration: const Duration(seconds: 2),
      ));
      return;
    }
    if (!mounted) return;
    context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = ref.watch(authProvider).user;
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: SafeArea(
        child: Column(
          children: [
            GlassTopBar(
              leading: const BackButton(),
              title: Text(tr('扫码确认登录')),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 应用品牌
                    Center(
                      child: Column(
                        children: [
                          Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  scheme.primary,
                                  scheme.primary.withValues(alpha: 0.72),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: scheme.primary.withValues(alpha: 0.26),
                                  blurRadius: 18,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Icon(Icons.desktop_windows_rounded,
                                size: 38, color: scheme.onPrimary),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            _appName,
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            tr('扫描到二维码，确认后该设备将登录你的账号'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 13.5,
                                color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    // 设备信息卡片
                    Container(
                      decoration: BoxDecoration(
                        color: appCardColor(context),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          _infoRow(scheme,
                              label: tr('登录账号'),
                              value: user?.nickname.isNotEmpty == true
                                  ? user!.nickname
                                  : widget.info.nickname),
                          Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                              color: scheme.outlineVariant.withValues(alpha: 0.4)),
                          _infoRow(scheme,
                              label: tr('设备ID'), value: _deviceId),
                          Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                              color: scheme.outlineVariant.withValues(alpha: 0.4)),
                          _infoRow(scheme,
                              label: tr('位置'), value: _location),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    UserAgreementCheckbox(
                      initialAgreed: _agreed,
                      onChanged: (v) => setState(() => _agreed = v),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _agreed && !_loading ? _confirm : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: scheme.primary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(tr('确认登录'),
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(ColorScheme scheme,
      {required String label, required String value}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 14, color: scheme.onSurfaceVariant)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w500, color: scheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}