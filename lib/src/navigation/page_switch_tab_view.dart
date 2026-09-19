import 'package:flutter/material.dart';

class PageSwitchTabView extends StatefulWidget {
  const PageSwitchTabView({
    super.key,
    required this.currentIndex,
    required this.children,
    this.onPageSettled,
    this.duration = const Duration(milliseconds: 320),
  });

  final int currentIndex;
  final List<Widget> children;
  final ValueChanged<int>? onPageSettled;
  final Duration duration;

  @override
  State<PageSwitchTabView> createState() => _PageSwitchTabViewState();
}

class _PageSwitchTabViewState extends State<PageSwitchTabView> {
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.currentIndex);
  }

  @override
  void didUpdateWidget(covariant PageSwitchTabView old) {
    super.didUpdateWidget(old);
    if (widget.currentIndex == old.currentIndex) return;
    if (_controller.hasClients &&
        _controller.page?.round() != widget.currentIndex) {
      _controller.animateToPage(
        widget.currentIndex,
        duration: widget.duration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: _controller,
      physics: const _TabPageScrollPhysics(),
      onPageChanged: (page) {
        if (page != widget.currentIndex) {
          widget.onPageSettled?.call(page);
        }
      },
      children: [
        for (final child in widget.children) TabKeepAlivePage(child: child),
      ],
    );
  }
}

class TabKeepAlivePage extends StatefulWidget {
  const TabKeepAlivePage({super.key, required this.child});

  final Widget child;

  @override
  State<TabKeepAlivePage> createState() => _TabKeepAlivePageState();
}

class _TabKeepAlivePageState extends State<TabKeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _TabPageScrollPhysics extends PageScrollPhysics {
  const _TabPageScrollPhysics({super.parent});

  @override
  _TabPageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _TabPageScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring =>
      const SpringDescription(mass: 1.0, stiffness: 150.0, damping: 22.0);
}
