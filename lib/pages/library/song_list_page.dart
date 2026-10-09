import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/i18n/i18n.dart';

class SongListArgs {
  const SongListArgs({required this.title, required this.loader});
  final String title;
  final Future<List<Song>> Function() loader;
}

class SongListPage extends ConsumerStatefulWidget {
  final String title;
  final Future<List<Song>> Function() loader;
  const SongListPage({super.key, required this.title, required this.loader});

  @override
  ConsumerState<SongListPage> createState() => _SongListPageState();
}

class _SongListPageState extends ConsumerState<SongListPage> {
  // loader initState 即启动（纯异步 IO，不占转场帧），future 持状态字段：
  // 此前写在 build 里每次重建都会重跑 loader。列表构建推迟到转场落定：
  // 本地库数据秒回，列表在 push 转场中挂载，整列表 build+layout 挤进
  // 转场帧是打开歌曲列表整页掉帧主源（在线页因网络延迟天然错过转场
  // 窗口，观感即「切换页面后才加载动画」）
  late final Future<List<Song>> _future = widget.loader();

  bool _settled = false;
  bool _routeChecking = false;
  int _routeCheckFrames = 0;
  VoidCallback? _routeAnimListener;
  Animation<double>? _routeAnim;
  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
    if (_settled || _routeAnim != null || _routeChecking) return;
    _routeChecking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _verifyRouteSettled());
  }

  // 转场判定必须走 controller 真值：ModalRoute 入场首帧把路由置
  // offstage（Hero 测量终位机制），route.animation 代理临时指向
  // kAlwaysCompleteAnimation 恒读 completed——首读值/status 判定从未
  // 生效，列表仍在转场中挂载（_RouteDeferredBody 实证）。controller 是
  // protected 触不可及，改为 offstage 窗口内逐帧重验 route.animation：
  // offstage 解除后该动画即转场真值，值监听 value>=1 即落定（status
  // 事件存在丢失边角）。重验设上限兜底，防常驻 offstage 时永远等不到
  // 落定。全部判定在帧末执行，setState 合法
  void _verifyRouteSettled() {
    if (!mounted) return;
    final route = _route;
    final anim = route?.animation;
    if (route == null || anim == null) {
      _routeChecking = false;
      setState(() => _settled = true);
      return;
    }
    if (route.offstage) {
      if (++_routeCheckFrames > 12) {
        _routeChecking = false;
        setState(() => _settled = true);
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _verifyRouteSettled());
      return;
    }
    _routeChecking = false;
    if (anim.value >= 1.0) {
      setState(() => _settled = true);
      return;
    }
    _routeAnim = anim;
    _routeAnimListener = () {
      if (_routeAnim!.value < 1.0) return;
      _disarmRoute();
      if (mounted) setState(() => _settled = true);
    };
    _routeAnim!.addListener(_routeAnimListener!);
  }

  void _disarmRoute() {
    final listener = _routeAnimListener;
    if (listener != null) _routeAnim?.removeListener(listener);
    _routeAnimListener = null;
    _routeAnim = null;
  }

  @override
  void dispose() {
    _disarmRoute();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final floating = MediaQuery.of(context).orientation != Orientation.landscape &&
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
            true);
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          if (floating)
            Positioned.fill(child: _body(contentTop: GlassTopBar.height(context) + 6))
          else
            Padding(
              padding: EdgeInsets.only(top: GlassTopBar.height(context)),
              child: _body(),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(widget.title),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body({double? contentTop}) {
    // 转场落定前列表不挂载（加载圈与在线页骨架期同观感，几乎零开销）：
    // 数据此时通常已就绪，落定即刻开错峰入场
    if (!_settled) {
      return const Center(child: CircularProgressIndicator());
    }
    return FutureBuilder<List<Song>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Text(tr('加载失败：{e}', {'e': snap.error.toString()})),
          );
        }
        final songs = snap.data ?? const <Song>[];
        return SongsListView(
          songs: songs,
          staggerEnter: true,
          enableScrollFabs: true,
          padding: contentTop == null
              ? null
              : EdgeInsets.only(
                  top: contentTop,
                  bottom: MediaQuery.paddingOf(context).bottom,
                ),
          onPlay: (list, i) =>
              ref.read(libraryProvider.notifier).playList(list, i),
        );
      },
    );
  }
}