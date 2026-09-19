import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/navigation/shell.dart';

class _Probe extends ConsumerStatefulWidget {
  const _Probe();

  @override
  ConsumerState<_Probe> createState() => _ProbeState();
}

class _ProbeState extends ConsumerState<_Probe> with HidesShellChrome {
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('probe'));
}

void main() {
  int count(WidgetTester tester) {
    final ctx = tester.element(find.byType(Navigator).first);
    return ProviderScope.containerOf(ctx, listen: false)
        .read(navBarHiddenProvider);
  }

  testWidgets('进入二级页面时计数加一，退出后归零', (tester) async {
    late BuildContext navContext;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              navContext = context;
              return const Scaffold(body: Text('root'));
            },
          ),
        ),
      ),
    );
    expect(count(tester), 0, reason: '初始应为 0');

    Navigator.of(navContext).push(
      MaterialPageRoute(builder: (_) => const _Probe()),
    );
    await tester.pumpAndSettle();
    expect(count(tester), 1, reason: '进入后应为 1');

    Navigator.of(navContext).pop();
    await tester.pumpAndSettle();
    expect(count(tester), 0, reason: '退出后必须归零，否则底栏永久消失');
  });

  testWidgets('多层页面叠加时计数正确累加与回落', (tester) async {
    late BuildContext navContext;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              navContext = context;
              return const Scaffold(body: Text('root'));
            },
          ),
        ),
      ),
    );

    Navigator.of(navContext).push(
      MaterialPageRoute(builder: (_) => const _Probe()),
    );
    await tester.pumpAndSettle();
    Navigator.of(navContext).push(
      MaterialPageRoute(builder: (_) => const _Probe()),
    );
    await tester.pumpAndSettle();
    expect(count(tester), 2, reason: '两层页面应为 2');

    Navigator.of(navContext).pop();
    await tester.pumpAndSettle();
    expect(count(tester), 1, reason: '退出一层应回落到 1');

    Navigator.of(navContext).pop();
    await tester.pumpAndSettle();
    expect(count(tester), 0, reason: '全部退出应归零');
  });

  testWidgets('HideShellChrome 包装组件同样正确归零', (tester) async {
    late BuildContext navContext;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              navContext = context;
              return const Scaffold(body: Text('root'));
            },
          ),
        ),
      ),
    );

    Navigator.of(navContext).push(
      MaterialPageRoute(
        builder: (_) => const HideShellChrome(
          child: Scaffold(body: Text('wrapped')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(count(tester), 1);

    Navigator.of(navContext).pop();
    await tester.pumpAndSettle();
    expect(count(tester), 0);
  });

}
