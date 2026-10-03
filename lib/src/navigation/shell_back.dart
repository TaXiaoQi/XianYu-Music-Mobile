part of 'shell.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _ShellBack on _AppShellState {

  void _handleBack() {
    final router = GoRouter.of(context);
    AppLogger.instance.log(
      'back',
      'onBack tab=${widget.navigationShell.currentIndex} routerCanPop=${router.canPop()}',
    );

    if (router.canPop()) {
      AppLogger.instance.log('back', '手动 pop 二级页面');
      router.pop();
      return;
    }

    if (widget.navigationShell.currentIndex != 0) {
      AppLogger.instance.log('back', '切回主界面 tab');
      widget.navigationShell.goBranch(0);
      return;
    }

    final now = DateTime.now();
    if (_lastBackTime == null ||
        now.difference(_lastBackTime!) > const Duration(seconds: 2)) {
      _lastBackTime = now;
      AppLogger.instance.log('back', '提示再按一次退出');
      showXianYuToast(
        context,
        tr('再按一次退出应用'),
        duration: const Duration(seconds: 2),
      );
      return;
    }

    AppLogger.instance.log('back', 'SystemNavigator.pop 退出应用');
    SystemNavigator.pop();
  }
}
