part of 'shell.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _ShellBack on _AppShellState {

  void _handleBack() {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
      return;
    }

    if (widget.navigationShell.currentIndex != 0) {
      widget.navigationShell.goBranch(0);
      return;
    }

    final now = DateTime.now();
    if (_lastBackTime == null ||
        now.difference(_lastBackTime!) > const Duration(seconds: 2)) {
      _lastBackTime = now;
      showXianYuToast(
        context,
        tr('再按一次退出应用'),
        duration: const Duration(seconds: 2),
      );
      return;
    }

    SystemNavigator.pop();
  }
}
