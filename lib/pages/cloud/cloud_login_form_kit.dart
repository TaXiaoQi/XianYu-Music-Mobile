// 网盘自绘登录表单公共组件库（弦予号登录同款样式）。
//
// cloud_password_login_page.dart（Cookie/账密页）与
// cloud_webview_fields_login_page.dart（webviewFields 页）等自绘
// 登录页共用：输入框、密码小眼睛、记住密码行、提交按钮，以及
// 嵌入态玻璃卡片与全屏页两套骨架。样式口径：填充底色 5% + 16
// 圆角 + 聚焦主题色描边 + 20px 前图标 + 通栏「登录并绑定」按钮。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/cloud/cloud_types.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/i18n/i18n.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/predictive_dialog_route.dart';
import '../../src/widgets/press_scale.dart';

/// 登录输入框默认态边框：16 圆角无边框（填充底色裸露）。
OutlineInputBorder cloudLoginBorder() =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    );

/// 登录输入框聚焦态边框：16 圆角主题色描边。
OutlineInputBorder cloudLoginFocusedBorder(BuildContext context) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide:
          BorderSide(color: Theme.of(context).colorScheme.primary, width: 1.5),
    );

/// 弦予号登录同款输入框：填充底色、无默认边框、聚焦主题色描边。
class CloudLoginFieldBox extends StatelessWidget {
  const CloudLoginFieldBox(
    this.controller, {
    super.key,
    required this.label,
    this.icon,
    this.obscure = false,
    this.keyboard,
    this.suffixIcon,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboard;
  final Widget? suffixIcon;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // 26px：给浮出的 label 留出上探空间，避免与上方内容视觉重叠
      padding: const EdgeInsets.only(bottom: 26),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboard,
        autocorrect: false,
        enableSuggestions: !obscure,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: scheme.onSurface.withValues(alpha: 0.05),
          prefixIcon: icon == null
              ? null
              : Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          suffixIcon: suffixIcon,
          border: cloudLoginBorder(),
          enabledBorder: cloudLoginBorder(),
          focusedBorder: cloudLoginFocusedBorder(context),
        ),
      ),
    );
  }
}

/// 密码框小眼睛后缀：点击切换明文/密文。
class CloudLoginEyeToggle extends StatelessWidget {
  const CloudLoginEyeToggle({
    super.key,
    required this.obscured,
    required this.onToggle,
  });

  final bool obscured;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      pressScale: 0.88,
      child: IconButton(
        icon: Icon(obscured ? Icons.visibility : Icons.visibility_off),
        onPressed: onToggle,
      ),
    );
  }
}

/// 「记住密码」勾选行：账号默认记住，勾选后密码一并保存到本机，
/// 下次会话失效重登自动回填，免重复输入。
class CloudLoginRememberRow extends StatelessWidget {
  const CloudLoginRememberRow({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Transform.translate(
            offset: const Offset(-6, 0),
            child: Checkbox(
              value: value,
              activeColor: scheme.primary,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => onChanged(v ?? false),
            ),
          ),
          Text(
            tr('记住密码'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tr('账号默认记住，勾选后密码也保存在本机'),
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 弦予号登录同款提交按钮：通栏圆角 + 按压缩放，提交中转圈。
class CloudLoginSubmitButton extends StatelessWidget {
  const CloudLoginSubmitButton({
    super.key,
    required this.label,
    required this.submitting,
    required this.onPressed,
  });

  final String label;
  final bool submitting;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      pressScale: 0.92,
      child: FilledButton(
        onPressed: submitting ? null : onPressed,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: submitting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                label,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
      ),
    );
  }
}

/// 网页登录兜底入口：自绘/自动填表通道之外留官方网页登录退路。
/// 全屏页有顶栏 actions 位不渲染本按钮；嵌入面板无顶栏位，放表单
/// 尾部（provider 无 webviewLoginUrl 时不展示）。
class CloudLoginWebFallbackButton extends StatelessWidget {
  const CloudLoginWebFallbackButton({super.key, required this.providerId});

  final String providerId;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: PressableScale(
        pressScale: 0.92,
        child: TextButton(
          onPressed: () => context.push('/cloud/webview-login/$providerId'),
          child: Text(tr('网页登录')),
        ),
      ),
    );
  }
}

/// 登录说明文案（「登录{name}后即可播放网盘内的音乐」）。
class CloudLoginHintText extends StatelessWidget {
  const CloudLoginHintText({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
      ),
    );
  }
}

/// 横屏设置面板嵌入态骨架：整块表单收进玻璃胶囊卡片（反馈页 TabBar
/// 带同款材质），标题由统一带 head 位承载。列表底部加键盘高度空白：
/// 宿主面板不随键盘缩放，靠底部内边距让内容可滚出键盘遮挡。
Widget cloudLoginEmbeddedCard({
  required BuildContext context,
  required WidgetRef ref,
  required Widget child,
}) {
  final mq = MediaQuery.of(context);
  return ListView(
    padding: EdgeInsets.fromLTRB(
      16,
      landscapePanelBand(context, ref) + 12,
      16,
      24 + mq.padding.bottom + mq.viewInsets.bottom,
    ),
    children: [
      GlassBand(
        // 独立回读：宿主左列带先画，同组会复用其制备纹理
        sharedNavGroup: false,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: child,
        ),
      ),
    ],
  );
}

/// 全屏登录页骨架：毛玻璃顶栏 + 横屏表单收窄 560 居中（登录表单口径），
/// 竖屏照旧全幅。键盘随 Scaffold 缩放（账号页同款避让：列表自动上移，
/// 焦点框滚出键盘遮挡）。
Widget cloudLoginScaffold({
  required BuildContext context,
  required WidgetRef ref,
  required String title,
  required Widget body,
  List<Widget>? actions,
}) {
  final landscape =
      MediaQuery.of(context).orientation == Orientation.landscape;
  return Scaffold(
    backgroundColor: appScaffoldBackground(context, ref),
    resizeToAvoidBottomInset: true,
    body: Stack(
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: landscape ? 560 : double.infinity,
            ),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                24,
                GlassTopBar.height(context) + 24,
                24,
                40 + MediaQuery.of(context).padding.bottom,
              ),
              children: [body],
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: GlassTopBar(
            // 横屏时挖孔在左缘，返回钮内推避让（与设置统一带同口径）
            leadingIndent: MediaQuery.paddingOf(context).left,
            leading: const BackButton(),
            title: Text(title),
            actions: actions,
          ),
        ),
      ],
    ),
  );
}

/// 短信验证码 / 二次验证弹窗（天翼 -133 风控同款，各手机号登录盘
/// 统一交互）：打开时不自动发码，弹窗内「发送验证码」手动触发
/// （[onSend] 由调用方接发码动作），60 秒冷却防连点；确认返回输入码
/// （取消返回 null），提交/后续动作由调用方执行。
///
/// [webviewHost] 非空时升级为滑块二次验证形态：弹窗内嵌 WebView 小窗
/// 承载官方盾/发码区域（需要滑块的盘把登录页 WebView 挂进来，协议原
/// 样跑、视觉全自绘），下方仍是验证码输入行；null 为纯收码形态
/// （139/天翼等纯 HTTP 盘）。[hint] 覆盖默认说明行。
Future<String?> showCloudSmsCodeDialog(
  BuildContext context, {
  required Future<void> Function() onSend,
  String? hint,
  Widget? webviewHost,
}) async {
  final controller = TextEditingController();
  // 弹窗内状态放外层闭包：StatefulBuilder 重建不会重置。
  var cooldown = 0;
  var sending = false;
  Timer? timer;
  var setDlg = null as void Function(void Function())?;
  void safeSet(void Function() fn) => setDlg?.call(fn);

  Future<void> send() async {
    if (sending || cooldown > 0) return;
    safeSet(() => sending = true);
    try {
      await onSend();
      if (!context.mounted) return;
      showXianYuToast(context, tr('验证码已发送'));
      safeSet(() => cooldown = 60);
      timer?.cancel();
      timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!context.mounted) {
          t.cancel();
          return;
        }
        safeSet(() {
          if (--cooldown <= 0) {
            cooldown = 0;
            t.cancel();
          }
        });
      });
    } catch (e) {
      AppLog.warn('cloud', '发送验证码失败: $e');
      if (!context.mounted) return;
      showXianYuToast(
        context,
        e is CloudException ? e.message : tr('验证码发送失败'),
      );
    } finally {
      safeSet(() => sending = false);
    }
  }

  try {
    return await showPredictiveDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(webviewHost == null ? '输入短信验证码' : '完成安全验证')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (webviewHost != null) ...[
              Text(hint ?? tr('若出现滑块请在下方页面内拖动，然后发送验证码')),
              const SizedBox(height: 10),
              // 官方盾/发码区域小窗：脚本已缩放并滚动到发码/盾位置。
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  height: 230,
                  width: double.maxFinite,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: webviewHost,
                ),
              ),
              const SizedBox(height: 12),
            ] else
              Text(hint ??
                  tr('检测到新设备登录，验证码将发送至 {username}',
                      {'username': ''})),
            TextField(
              controller: controller,
              autofocus: webviewHost == null,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: InputDecoration(hintText: tr('短信验证码')),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          PressableScale(
            pressScale: 0.92,
            child: TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('取消')),
            ),
          ),
          PressableScale(
            pressScale: 0.92,
            child: StatefulBuilder(
              builder: (ctx, setSb) {
                setDlg = setSb;
                return TextButton(
                  onPressed: (sending || cooldown > 0) ? null : send,
                  child: Text(
                    sending
                        ? tr('发送中…')
                        : (cooldown > 0
                            ? tr('{s} 秒', {'s': '$cooldown'})
                            : tr('发送验证码')),
                  ),
                );
              },
            ),
          ),
          PressableScale(
            pressScale: 0.92,
            child: FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(tr('确定')),
            ),
          ),
        ],
      ),
    );
  } finally {
    timer?.cancel();
  }
}
