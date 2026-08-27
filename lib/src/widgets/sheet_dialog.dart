import 'package:flutter/material.dart';

import 'predictive_dialog_route.dart';

/// 把原本从底部滑出的上弹窗内容改为居中弹窗展示（对齐「修改弦予号」弹窗风格）。
///
/// - 居中于屏幕，固定最大宽度，过高内容由内容自身滚动
/// - 不可点击遮罩、不可下滑关闭（桌面端语义），但系统返回/预测返回可关闭
/// - 用 [showPredictiveDialog] 建模为参与预测返回的页面路由，
///   使返回手势可关闭弹窗
/// - [builder] 收到的是弹窗自身的 context，可直接 `Navigator.pop(context)` 关闭
Future<T?> showSheetDialog<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool barrierDismissible = true,
}) {
  return showPredictiveDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) => DialogKeyboardLift(
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          // 弹窗是屏幕居中的 Dialog，并不贴着状态栏/底部安全区；若内容里用了
          // SafeArea，会凭空多加一段状态栏高度的顶部/底部空白。这里把安全区内边距
          // 清零（保留 viewInsets，键盘避让仍正常），统一消除所有该风格弹窗的顶部空白。
          child: MediaQuery.removePadding(
            context: dialogContext,
            removeTop: true,
            removeBottom: true,
            child: builder(dialogContext),
          ),
        ),
      ),
    ),
  );
}

/// 键盘避让「仅遮挡才顶起」包装（所有 [showSheetDialog] 弹窗共用）。
///
/// - 默认保持弹窗原位置（居中），不因输入法弹出而移动；
/// - 仅当弹窗底部即将被输入法盖住时才整体上移，上移量精确到「恰好露出底缘」，
///   键盘收起后自动回到原位；
/// - 顶起量是「键盘高度」与「弹窗内容高」的纯函数（弹窗屏幕居中推导），
///   内容高首次布局后一次性缓存；走 [Transform]，不触发重排，键盘动画期间不掉帧。
class DialogKeyboardLift extends StatefulWidget {
  const DialogKeyboardLift({super.key, required this.child});

  final Widget child;

  @override
  State<DialogKeyboardLift> createState() => _DialogKeyboardLiftState();
}

class _DialogKeyboardLiftState extends State<DialogKeyboardLift> {
  final GlobalKey _key = GlobalKey();
  // 弹窗内容高（首次布局后一次性缓存；内容在弹窗展示期内不变）。
  double _dialogH = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureOnce());
  }

  void _measureOnce() {
    if (!mounted || _dialogH > 0) return;
    final ctx = _key.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      _dialogH = box.size.height;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 弹窗由路由 Center 居中。adjustResize 设备上键盘把窗口缩小，Center 会把弹窗
    // 自动抬高（这就是「离输入法很远却仍被顶起」的来源）。这里先用
    // fullH（无键高全屏高）把弹窗钉回自然中央，只在键盘真的会盖住底缘时
    // 才最小上移直到露出。该公式对「窗口会缩小」和「窗口不缩」两类设备都成立，
    // 若不做窗口缩放的设备，下面 naturalTop == currentTop，退化为仅被遮挡才顶起。
    final mq = MediaQuery.of(context);
    final sizeH = mq.size.height;
    final keyboard = mq.viewInsets.bottom;
    double translateY = 0;
    if (keyboard > 0 && _dialogH > 0) {
      final fullH = sizeH + keyboard; // 无键盘时的全屏高
      final naturalTop = (fullH - _dialogH) / 2; // 自然中央（无键盘时的居中位置）
      final currentTop = (sizeH - _dialogH) / 2; // 窗口缩小+居中后的当前位置
      final visibleBottom = sizeH; // 可视区底缘 == 键盘顶缘
      double desiredTop = naturalTop;
      if (desiredTop + _dialogH > visibleBottom) {
        final floor = visibleBottom - _dialogH;
        desiredTop = floor < 0 ? 0.0 : floor;
      }
      // 位移 = 目标位置 - 当前位置；正值表示向下还原，负值表示向上避让。
      translateY = desiredTop - currentTop;
    }
    return Transform.translate(
      offset: Offset(0, translateY),
      // RepaintBoundary：把弹窗内容层缓存为一块位图层，键盘动画期间每帧只做
      // 层位移（GPU 合成），不逐帧重新光栅化弹窗内容，避免顶起掉帧。
      child: RepaintBoundary(
        child: KeyedSubtree(key: _key, child: widget.child),
      ),
    );
  }
}