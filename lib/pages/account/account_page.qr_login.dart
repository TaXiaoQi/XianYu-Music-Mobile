part of 'account_page.dart';

/// 登录页「扫码登录」视图：本机作为「被扫端」（车机/平板/电视等输入不便的
/// 设备）展示二维码，由已登录的手机 App 扫码并确认后本机自动登录。
/// 与桌面端共用 generate_tv_login_code / poll_tv_login_status 服务端接口，
/// 二维码内容与桌面端一致（`xianyumusic://tvlogin/<code>`）。
class _QrLoginView extends ConsumerStatefulWidget {
  const _QrLoginView();

  @override
  ConsumerState<_QrLoginView> createState() => _QrLoginViewState();
}

class _QrLoginViewState extends ConsumerState<_QrLoginView> {
  static const _qrPrefix = 'xianyumusic://tvlogin/';

  Timer? _pollTimer;
  String _code = '';
  int _expireAtMs = 0;

  /// loading | pending | scanned | expired | error | logged
  String _status = 'loading';
  String _error = '';

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }

  Future<void> _generate() async {
    _pollTimer?.cancel();
    setState(() {
      _status = 'loading';
      _error = '';
      _code = '';
    });
    try {
      final info = await ref.read(authProvider.notifier).generateTvLoginCode();
      if (!mounted) return;
      setState(() {
        _code = info.code;
        _expireAtMs =
            DateTime.now().millisecondsSinceEpoch + info.expireSeconds * 1000;
        _status = 'pending';
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'error';
        _error = e is AuthException ? e.message : tr('二维码获取失败，请重试');
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_code.isEmpty || _status == 'logged') return;
    if (DateTime.now().millisecondsSinceEpoch > _expireAtMs) {
      _pollTimer?.cancel();
      if (mounted) setState(() => _status = 'expired');
      return;
    }
    try {
      final r = await ref.read(authProvider.notifier).pollTvLoginStatus(_code);
      if (!mounted) return;
      if (r.isLoggedIn) {
        _pollTimer?.cancel();
        if (mounted) setState(() => _status = 'logged');
        // authProvider 登录态更新后，账号页会自动切换到已登录资料视图
      } else if (r.status != _status) {
        setState(() => _status = r.status);
      }
    } catch (_) {
      // 单次轮询失败（网络抖动等）忽略，继续轮询，本地过期时间兜底
    }
  }

  String get _statusText {
    switch (_status) {
      case 'loading':
        return tr('正在获取二维码...');
      case 'scanned':
        return tr('已扫码，请在手机上确认登录');
      case 'expired':
        return tr('二维码已过期，请重新生成');
      case 'error':
        return _error;
      default:
        return tr('使用已登录的弦予音乐 App 扫一扫快捷登录');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        const SizedBox(height: 16),
        // 二维码卡片固定白底（深色模式下也保证扫码对比度）
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: _buildQr(context, scheme),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _statusText,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            color: _status == 'error'
                ? scheme.error
                : scheme.onSurfaceVariant.withValues(alpha: 0.85),
          ),
        ),
        if (_status == 'expired' || _status == 'error') ...[
          const SizedBox(height: 12),
          PressableScale(
            pressScale: 0.95,
            child: FilledButton.icon(
              onPressed: _generate,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(tr('重新生成')),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildQr(BuildContext context, ColorScheme scheme) {
    if (_status == 'loading') {
      return const SizedBox(
        width: 200,
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_code.isEmpty) {
      return SizedBox(
        width: 200,
        height: 200,
        child: Center(
          child: Icon(
            Icons.qr_code_2,
            size: 64,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
        ),
      );
    }
    return QrImageView(
      data: '$_qrPrefix$_code',
      size: 200,
      backgroundColor: Colors.white,
    );
  }
}
