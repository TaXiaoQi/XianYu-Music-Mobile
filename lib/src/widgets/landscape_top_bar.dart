import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pages/search/search_page.dart';
import '../auth/account_api.dart';
import '../i18n/i18n.dart';
import '../navigation/shell.dart'
    show
        landscapeDownloadOpenProvider,
        landscapeLibraryProvider,
        landscapePlaylistOpenProvider;
import 'glass_appbar.dart';
import 'floating_search_bar.dart';
import 'glass_settings.dart';
import 'page_search_bar.dart';
import 'skin_icon.dart';

/// 横屏全局搜索胶囊：搜索框（点击在右侧容器打开搜索，不开二级路由）+
/// 听歌识曲入口（mic）。由壳层在右侧容器顶部统一渲染，首页/我的等页面继承使用。
/// 样式与竖屏首页/我的页共用同一组件 [PageSearchBar]。
class LandscapeSearchBar extends ConsumerWidget {
  const LandscapeSearchBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 参考桌面端：点击顶栏搜索框即在右侧容器打开搜索页（历史+热搜）。
    // 注意：不要在这里 postFrame 里对输入框 requestFocus——胶囊在容器打开
    // 的同一帧即被卸载，延迟回调里 ref 已失效会抛异常、焦点永远不会建立。
    // 聚焦逻辑由输入框自身挂载时处理（见 _LandscapeSearchField）。
    return PageSearchBar(
      onTap: () =>
          ref.read(landscapeSearchOpenProvider.notifier).state = true,
      onRecognize: () => context.push('/recognize'),
    );
  }
}

/// 横屏全局顶栏：搜索框填满主体（自动收缩/填充），右侧皮肤(壁纸)+设置。
/// 首页/我的等右侧容器页面全局共享这一根顶栏，各页不再渲染自己的顶栏。
///
/// 两种形态（跟随「悬浮顶部栏」开关，与竖屏首页/我的页口径一致）：
/// - 默认模式：返回/皮肤/设置为普通 IconButton 直接显示在顶栏条内；
/// - 悬浮模式：无整条顶栏底，返回键为玻璃圆钮 + 搜索胶囊（液态/毛玻璃材质）
///   + 玻璃圆钮各自独立悬浮显示，内容从其下方穿过。
///
/// 返回按钮（`<`）常驻显示（参考桌面端侧边栏路由逻辑：从首页起为根路由，
/// 其后的所有容器都可逐步回退）。回退链：搜索容器 > 歌单详情 > 下载 >
/// 音乐库容器 > 我的 → 首页；停在首页根上（无容器可关）时按钮置灰不可点。
class LandscapeGlobalTopBar extends ConsumerWidget {
  const LandscapeGlobalTopBar({
    super.key,
    this.currentIndex = 0,
    this.floating = false,
  });

  /// 当前主 tab 索引（0=首页根路由，1=我的），由壳层传入。
  final int currentIndex;

  /// 悬浮模式：控件独立悬浮显示（无整条顶栏底），默认 false 直接显示在顶栏内。
  final bool floating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadOpen = ref.watch(landscapeDownloadOpenProvider);
    final playlistOpenId = ref.watch(landscapePlaylistOpenProvider);
    final libSel = ref.watch(landscapeLibraryProvider);
    // 搜索容器打开时，标题区切换为搜索输入框（顶栏即搜索输入，参考桌面端）。
    final searchOpen = ref.watch(landscapeSearchOpenProvider);
    // 回退链是否还有上一级：容器打开，或当前不在首页根路由上。
    final canBack = searchOpen ||
        playlistOpenId != null ||
        downloadOpen ||
        libSel != null ||
        currentIndex != 0;

    void handleBack() {
      // 搜索容器最上层：结果页先退回搜索默认页，默认页再关闭容器
      // （对齐原「搜索页 ← 结果页」两级路由回退）。
      if (ref.read(landscapeSearchOpenProvider.notifier).state) {
        final rs = ref.read(landscapeSearchResultsProvider.notifier);
        if (rs.state) {
          rs.state = false;
        } else {
          ref.read(landscapeSearchOpenProvider.notifier).state = false;
        }
        return;
      }
      final pl = ref.read(landscapePlaylistOpenProvider.notifier);
      if (pl.state != null) {
        pl.state = null;
        return;
      }
      final dl = ref.read(landscapeDownloadOpenProvider.notifier);
      if (dl.state) {
        dl.state = false;
        return;
      }
      final lib = ref.read(landscapeLibraryProvider.notifier);
      if (lib.state != null) {
        lib.state = null;
        return;
      }
      // 无内嵌容器：从「我的」回退到首页根路由（分支状态保留，动效走
      // PageSwitchTabView 的横屏 out-in）。
      if (currentIndex != 0) {
        context.go('/home');
        return;
      }
      if (context.canPop()) context.pop();
    }

    // 悬浮模式：独立悬浮控件行（返回玻璃圆钮 + 搜索胶囊 + 玻璃圆钮），
    // 与竖屏悬浮顶部栏（FloatingTopBar）同一套控件与材质口径。
    if (floating) {
      return Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              BiliPaiIconButton(
                icon: Icons.arrow_back,
                tooltip: tr('返回'),
                color: canBack ? null : Theme.of(context).disabledColor,
                onTap: canBack ? handleBack : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: searchOpen
                    ? const _LandscapeSearchField(floating: true)
                    : FloatingSearchBar(
                        onTap: () => ref
                            .read(landscapeSearchOpenProvider.notifier)
                            .state = true,
                        onRecognize: () => context.push('/recognize'),
                      ),
              ),
              const SizedBox(width: 10),
              BiliPaiIconButton(
                iconChild: const SkinIcon(),
                tooltip: tr('皮肤'),
                onTap: () => context.push('/wallpaper'),
              ),
              const SizedBox(width: 8),
              BiliPaiIconButton(
                icon: Icons.settings_outlined,
                tooltip: tr('设置'),
                onTap: () => context.push('/settings'),
              ),
            ],
          ),
        ),
      );
    }

    // 默认模式：普通 IconButton 直接显示在顶栏条内（与竖屏非悬浮顶栏一致）。
    return GlassTopBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: tr('返回'),
        color: canBack ? null : Theme.of(context).disabledColor,
        onPressed: canBack ? handleBack : null,
      ),
      title: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: DefaultTextStyle(
          style: const TextStyle(fontWeight: FontWeight.w400),
          child: SizedBox(
            width: double.infinity,
            child: searchOpen
                ? const _LandscapeSearchField()
                : const LandscapeSearchBar(),
          ),
        ),
      ),
      actions: [
        IconButton(
          icon: const SkinIcon(),
          tooltip: tr('皮肤'),
          onPressed: () => context.push('/wallpaper'),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: tr('设置'),
          onPressed: () => context.push('/settings'),
        ),
        const SizedBox(width: 16),
      ],
    );
  }
}

/// 横屏搜索容器打开时的顶栏输入框：直接在顶栏输入回车搜索，结果显示在
/// 右侧搜索容器内（参考桌面端 TitleBar 搜索框交互）。控制器全局共享，
/// 搜索默认页/结果页之间往返不丢输入内容。
///
/// [floating]（悬浮顶部栏模式）：材质与悬浮搜索胶囊（[FloatingSearchBar]）
/// 同一套玻璃口径（液态/伪液态/毛玻璃），进搜索页/结果页材质连续不跳变；
/// 默认模式保持对比底色胶囊，与 [PageSearchBar] 一致。
class _LandscapeSearchField extends ConsumerStatefulWidget {
  const _LandscapeSearchField({this.floating = false});

  final bool floating;

  @override
  ConsumerState<_LandscapeSearchField> createState() =>
      _LandscapeSearchFieldState();
}

class _LandscapeSearchFieldState extends ConsumerState<_LandscapeSearchField> {
  late final TextEditingController _ctrl =
      ref.read(landscapeSearchCtrlProvider);

  // 输入统计：1.5s 无新输入后批量上报新增字符数（与搜索页口径一致）。
  int _pendingCharCount = 0;
  int _lastQueryLength = 0;
  Timer? _inputFlushTimer;

  @override
  void initState() {
    super.initState();
    _lastQueryLength = _ctrl.text.length;
    // 挂载后下一帧请求焦点：第一次点顶栏搜索框键盘就弹出（聚焦逻辑必须
    // 放在本框内——顶栏胶囊在容器打开同帧卸载，其 ref 已失效不可用）。
    // 若节点已持有焦点（顶栏实例切换导致本框为重挂载的新实例），EditableText
    // 只在焦点「变化」时建立输入法连接，先断开再重连驱动其弹出键盘。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = ref.read(landscapeSearchFocusProvider);
      if (node.hasFocus) {
        node.unfocus();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) node.requestFocus();
        });
      } else {
        node.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _inputFlushTimer?.cancel();
    super.dispose();
  }

  void _onChanged(String keyword) {
    setState(() {}); // 更新清除按钮显隐。

    final len = keyword.length;
    final delta = len - _lastQueryLength;
    _lastQueryLength = len;
    if (delta > 0) {
      _pendingCharCount += delta;
      _inputFlushTimer?.cancel();
      _inputFlushTimer = Timer(const Duration(milliseconds: 1500), () {
        final count = _pendingCharCount;
        _pendingCharCount = 0;
        if (count > 0) {
          ref.read(accountApiProvider).reportInputStats(count);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = _ctrl.text.isNotEmpty;
    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 44,
        padding: const EdgeInsets.fromLTRB(18, 0, 6, 0),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                focusNode: ref.watch(landscapeSearchFocusProvider),
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 15),
                onChanged: _onChanged,
                onSubmitted: (q) => submitLandscapeSearch(ref, q),
                decoration: InputDecoration(
                  hintText: tr('搜索音乐、歌手、专辑、歌单'),
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                ),
              ),
            ),
            if (hasText)
              GestureDetector(
                onTap: () {
                  _ctrl.clear();
                  setState(() {});
                },
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.clear,
                    size: 17,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(width: 6),
            // 听歌识曲入口：保留话筒图标。
            GestureDetector(
              onTap: () => context.push('/recognize'),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFEC4141).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.mic_none,
                  size: 17,
                  color: Color(0xFFEC4141),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // 悬浮模式：与悬浮搜索胶囊同一套玻璃材质（液态/伪液态/毛玻璃），进入
    // 搜索页/结果页材质连续不跳变；默认模式保持对比底色胶囊（PageSearchBar）。
    if (widget.floating) {
      return FloatingGlassSurface(child: content);
    }
    return Material(
      color: contrastSearchColor(context),
      borderRadius: BorderRadius.circular(999),
      child: content,
    );
  }
}