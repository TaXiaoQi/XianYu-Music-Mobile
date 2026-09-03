import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_api.dart';
import '../auth/server_models.dart';
import '../i18n/i18n.dart';
import 'predictive_dialog_route.dart';

/// 用户协议（对齐桌面端 Auth.vue 的 defaultAgreementContent）。
const kUserAgreementDefaultContent = '''一、协议范围
本协议适用于弦予音乐客户端账号系统及相关云端同步、资料管理、统计上报、风控安全服务。用户注册、登录或继续使用账号功能，即表示已阅读并同意本协议。

二、账号注册与使用
请使用真实、有效的邮箱完成注册，并妥善保管账号、密码和邮箱验证码。因主动泄露、共享账号或使用非官方客户端造成的损失，由用户自行承担。

三、本地数据读取说明
为提供账号登录、设备安全识别、播放统计、同步和故障排查功能，账号系统可能读取或生成以下本地数据：本机设备标识、客户端版本、操作系统版本、设备厂商与型号、登录状态凭证、用户主动上传的头像、本地收藏、歌单、播放历史、听歌时长等音乐使用数据，以及软件运行错误日志。上述数据仅用于账号服务、安全风控、功能同步、异常定位和产品维护。

四、数据上报与安全
客户端启动、登录、注册、搜索、播放统计、错误反馈等行为可能向服务器上报必要信息，包括设备ID、IP地址、账号ID、客户端版本、操作系统版本、设备厂商、设备型号、行为时间和必要的请求参数。为便于准确排查和定位问题，提交问题反馈或错误日志时，客户端还会一并上报当前设备的具体厂商、型号及系统版本等详细信息（例如手机厂商与机型、系统版本号；桌面端操作系统版本与设备型号）。我们将尽合理努力保护数据安全，不会主动出售用户个人信息。

五、禁止行为
不得利用账号系统进行恶意攻击、批量注册、刷量、破解、逆向、绕过限制、上传违法违规内容、干扰服务器稳定性或侵犯他人权益。发现异常行为时，平台有权限制、封禁账号或设备。

六、封禁与申诉
若账号或设备因违反协议、安全风控或恶意行为被封禁，登录时将提示封禁状态及原因。如认为处理有误，可联系管理员并提供账号、设备ID及相关说明进行核查。

七、协议更新
平台可根据功能调整、安全要求或法律合规需要更新本协议。更新后继续使用账号功能，视为接受更新后的协议内容。''';

const kUserAgreementDefaultTitle = '弦予音乐用户协议';

/// 拉取用户协议（服务端下发），失败回退默认内容。
Future<UserAgreement> fetchUserAgreement(WidgetRef ref) async {
  try {
    final a = await ref.read(accountApiProvider).getUserAgreement();
    return UserAgreement(
      title: a.title.trim().isNotEmpty ? a.title.trim() : kUserAgreementDefaultTitle,
      content: a.content.trim().isNotEmpty ? a.content.trim() : kUserAgreementDefaultContent,
    );
  } catch (_) {
    return const UserAgreement(
      title: kUserAgreementDefaultTitle,
      content: kUserAgreementDefaultContent,
    );
  }
}

/// 用户协议勾选行：点击勾选时弹出协议详情，需滚动到底部并点「同意」后才算勾选。
///
/// 状态由父级通过 [initialAgreed] 传入、[onChanged] 回调同步，组件内部仅管理
/// 协议内容的加载与弹窗交互。对齐桌面端：未滚动到底不允许同意。
class UserAgreementCheckbox extends ConsumerStatefulWidget {
  const UserAgreementCheckbox({
    super.key,
    this.initialAgreed = false,
    required this.onChanged,
    this.textAlign = TextAlign.left,
  });

  final bool initialAgreed;
  final ValueChanged<bool> onChanged;
  final TextAlign textAlign;

  @override
  ConsumerState<UserAgreementCheckbox> createState() =>
      _UserAgreementCheckboxState();
}

class _UserAgreementCheckboxState extends ConsumerState<UserAgreementCheckbox> {
  late bool _agreed = widget.initialAgreed;
  UserAgreement? _agreement;
  bool _loading = false;

  void _setAgreed(bool v) {
    if (_agreed == v) return;
    _agreed = v;
    widget.onChanged(v);
  }

  Future<void> _openModal() async {
    if (_loading) return;
    setState(() => _loading = true);
    final agreement = _agreement ??= await fetchUserAgreement(ref);
    if (!mounted) return;
    setState(() => _loading = false);
    final ok = await showUserAgreementModal(
      context: context,
      agreement: agreement,
    );
    if (!mounted) return;
    if (ok) {
      _setAgreed(true);
    } else {
      _setAgreed(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final linkStyle = TextStyle(
      color: scheme.primary,
      fontWeight: FontWeight.w600,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Transform.translate(
          offset: const Offset(-8, 2),
          child: Checkbox(
            value: _agreed,
            activeColor: scheme.primary,
            onChanged: (v) {
              if (v == true) {
                _openModal();
              } else {
                _setAgreed(false);
              }
            },
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: tr('我已阅读并同意')),
                  TextSpan(text: ' '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: GestureDetector(
                      onTap: _openModal,
                      child: Text('《${tr(kUserAgreementDefaultTitle)}》',
                          style: linkStyle),
                    ),
                  ),
                ],
              ),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              textAlign: widget.textAlign,
            ),
          ),
        ),
      ],
    );
  }
}

/// 协议详情弹窗：滚动到底部才可「同意」。回调返回是否已同意。
Future<bool> showUserAgreementModal({
  required BuildContext context,
  required UserAgreement agreement,
  bool requireScrollToBottom = true,
}) {
  return showPredictiveDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AgreementDialog(
      agreement: agreement,
      requireScrollToBottom: requireScrollToBottom,
    ),
  ).then((v) => v ?? false);
}

class _AgreementDialog extends StatefulWidget {
  const _AgreementDialog({
    required this.agreement,
    required this.requireScrollToBottom,
  });

  final UserAgreement agreement;
  final bool requireScrollToBottom;

  @override
  State<_AgreementDialog> createState() => _AgreementDialogState();
}

class _AgreementDialogState extends State<_AgreementDialog> {
  final _scroll = ScrollController();
  bool _atEnd = false;

  @override
  void initState() {
    super.initState();
    _atEnd = !widget.requireScrollToBottom;
    if (_atEnd) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _scroll.addListener(_onScroll);
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final el = _scroll.position;
    if (!el.hasContentDimensions) return;
    final atEnd =
        el.maxScrollExtent <= 0 || el.pixels >= el.maxScrollExtent - 6;
    if (_atEnd != atEnd) setState(() => _atEnd = atEnd);
  }

  void _refresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final el = _scroll.position;
      if (!el.hasContentDimensions) {
        setState(() => _atEnd = true);
        return;
      }
      setState(() => _atEnd =
          el.maxScrollExtent <= 0 || el.pixels >= el.maxScrollExtent - 6);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enable = widget.requireScrollToBottom ? _atEnd : true;
    return AlertDialog(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      title: Row(
        children: [
          Icon(Icons.description_outlined, size: 22, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.agreement.title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              widget.agreement.content,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('取消')),
        ),
        FilledButton(
          onPressed: enable ? () => Navigator.of(context).pop(true) : null,
          child: Text(widget.requireScrollToBottom && !_atEnd
              ? tr('请滚动至底部')
              : tr('同意')),
        ),
      ],
    );
  }
}