// 网盘自绘登录表单公共组件库（弦予号登录同款样式）。
//
// cloud_password_login_page.dart（Cookie/账密页）与
// cloud_webview_fields_login_page.dart（webviewFields 页）等自绘
// 登录页共用：输入框、密码小眼睛、记住密码行、提交按钮，以及
// 嵌入态玻璃卡片与全屏页两套骨架。样式口径：填充底色 5% + 16
// 圆角 + 聚焦主题色描边 + 20px 前图标 + 通栏「登录并绑定」按钮。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/i18n/i18n.dart';
import '../../src/widgets/glass_appbar.dart';
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
