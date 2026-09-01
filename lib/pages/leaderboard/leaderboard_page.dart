import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/account_api.dart';
import '../../src/core/app_colors.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/auth/server_models.dart';
import '../../src/core/db_path.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/user_avatar.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/i18n/i18n.dart';

/// 听歌排行榜：日榜/周榜/总榜切换，Top 列表 + 底部个人排名。
/// [embedded]=true 时作为横屏右侧「内容」容器内嵌（无自绘顶栏，顶部让位
/// 为 0——容器外层 FlatTopBar 已承接返回与标题）。
class LeaderboardPage extends ConsumerStatefulWidget {
  const LeaderboardPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends ConsumerState<LeaderboardPage>
    with SingleTickerProviderStateMixin {
  // 注意：必须显式标注返回类型——无类型的 static get 在本工具链下会被推断为
  // dynamic（strict_top_level_inference 提示），.indexed 等扩展成员随之变成
  // 动态分发，运行时直接 NoSuchMethodError（扩展成员不会出现在实例上）。
  static List<({String value, String label})> get _periods => [
    (value: 'daily', label: tr('日榜')),
    (value: 'weekly', label: tr('周榜')),
    (value: 'total', label: tr('总榜')),
  ];

  /// 日/周/总三榜：TabBarView 横滑切换 + 点 tab 动画（300ms
  /// fastLinearToSlowEaseIn，与顶栏内容 tab 一致）。
  late final TabController _tab = TabController(length: 3, vsync: this);

  @override
  void initState() {
    super.initState();
    _tab.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  int get _periodIndex =>
      (_tab.animation?.value ?? _tab.index.toDouble()).round().clamp(0, 2);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(
                top: widget.embedded ? 0 : GlassTopBar.height(context)),
            child: Column(
              children: [
                // 周期切换（标签与选中态随横滑实时同步）
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: AnimatedBuilder(
                    animation: _tab.animation ?? _tab,
                    builder: (context, _) {
                      final idx = _periodIndex;
                      final label = switch (idx) {
                        0 => tr('单日听歌时长排行'),
                        1 => tr('本周听歌时长排行'),
                        _ => tr('累计听歌时长排行'),
                      };
                      return Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: appCardFill(context, ref),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final (i, p) in _periods.indexed)
                                  _PeriodTab(
                                    label: p.label,
                                    active: idx == i,
                                    onTap: () => _tab.animateTo(i),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tab,
                    children: [
                      for (final p in _periods)
                        _PeriodBoard(key: ValueKey(p.value), period: p.value),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (!widget.embedded)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title: Text(tr('听歌排行榜')),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单个周期榜（日/周/总）：独立加载与缓存，TabBarView 横滑往返不重复请求。
class _PeriodBoard extends ConsumerStatefulWidget {
  const _PeriodBoard({super.key, required this.period});
  final String period;

  @override
  ConsumerState<_PeriodBoard> createState() => _PeriodBoardState();
}

class _PeriodBoardState extends ConsumerState<_PeriodBoard>
    with SingleTickerProviderStateMixin {
  List<LeaderboardEntry> _entries = [];
  bool _loading = true;
  bool _error = false;
  int _requestId = 0;

  /// 逐条入场控制器（桌面端同款 stagger 节奏，见 _StaggerIn）。
  late final AnimationController _enter = AnimationController(
      vsync: this, duration: const Duration(milliseconds: _StaggerIn.totalMs));

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  /// 排名徽章弹性放大：行入场 +200ms，400ms back-out（对齐桌面 rankPop）。
  Animation<double> _popFor(int index) {
    final t0 = (index * _StaggerIn.staggerMs + 200) / _StaggerIn.totalMs;
    return CurvedAnimation(
      parent: _enter,
      curve: Interval(
        t0,
        (t0 * _StaggerIn.totalMs + 400) / _StaggerIn.totalMs,
        curve: const Cubic(0.34, 1.15, 0.64, 1),
      ),
    );
  }

  Future<void> _load() async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      // 听歌时长取自数据库（日/周/总，与桌面端 getListenDurations 对齐），
      // 播放器落库后据此上报，保证排行榜与首页统计一致。
      Map<String, int> durations;
      try {
        final dbPath = await ref.read(dbPathProvider.future);
        final dj = jsonDecode(await statsGetListenDurations(dbPath: dbPath))
            as Map<String, dynamic>;
        durations = {
          'daily': (dj['daily'] as num?)?.toInt() ?? 0,
          'weekly': (dj['weekly'] as num?)?.toInt() ?? 0,
          'total': (dj['total'] as num?)?.toInt() ?? 0,
        };
      } catch (_) {
        durations = {'daily': 0, 'weekly': 0, 'total': 0};
      }
      if (!mounted || requestId != _requestId) return;
      final data = await ref
          .read(accountApiProvider)
          .fetchLeaderboard(
              limit: 15, period: widget.period, durations: durations);
      if (!mounted || requestId != _requestId) return;
      final list = List<LeaderboardEntry>.from(data.leaderboard);
      if (data.me != null && !list.any((e) => e.isMe)) {
        list.add(data.me!);
      }
      setState(() {
        _entries = list;
        _loading = false;
      });
      _enter.forward(from: 0);
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _entries = [];
        _loading = false;
        _error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loggedIn = ref.watch(authProvider).isLoggedIn;

    if (_loading) {
      // 骨架行复用同一原型：prototypeItem 让 Sliver 直接按固定行高估算滚动范围，
      // 避免首帧逐行测量再布局（对齐 PiliNara 的 prototypeItem 骨架屏）。
      final skeleton = Container(
        height: 56,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: appCardFill(context, ref),
          borderRadius: BorderRadius.circular(12),
        ),
        child: _skeletonRow(scheme),
      );
      return ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: 8,
        prototypeItem: skeleton,
        itemBuilder: (_, i) => skeleton,
      );
    }
    if (_error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 44, color: scheme.outline),
            const SizedBox(height: 12),
            Text(tr('排行榜加载失败'),
                style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child:   Text(tr('点击重试'))),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text(tr('暂无排行榜数据'),
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
      );
    }

    final top = _entries.take(15).toList();
    final me = _entries.where((e) => e.isMe).firstOrNull;

    // 桌面端同款：Top 列表滚动，「自己的排名/未登录」固定悬浮在底部，
    // 不随列表滚走；入场 stagger 顺位接在最后一行之后（跟随列表加载）。
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            children: [
              for (final (i, e) in top.indexed)
                _StaggerIn(
                  controller: _enter,
                  index: i,
                  child: _LeaderboardRow(
                    entry: e,
                    isMe: e.isMe,
                    highlight: e.rank <= 3,
                    rankPop: _popFor(i),
                  ),
                ),
            ],
          ),
        ),
        if (me != null) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Center(
              child: Text('···',
                  style: TextStyle(
                      fontSize: 12, letterSpacing: 2, color: Colors.grey)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: _StaggerIn(
              controller: _enter,
              index: top.length,
              child: _LeaderboardRow(
                entry: me,
                isMe: true,
                highlight: me.rank <= 3,
                rankPop: _popFor(top.length),
              ),
            ),
          ),
        ] else if (!loggedIn) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Center(
              child: Text('···',
                  style: TextStyle(
                      fontSize: 12, letterSpacing: 2, color: Colors.grey)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: _StaggerIn(
              controller: _enter,
              index: top.length,
              child: _LoginRow(onTap: () => context.push('/account')),
            ),
          ),
        ],
      ],
    );
  }

  Widget _skeletonRow(ColorScheme scheme) {

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: appCardFill(context, ref),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: appCardFill(context, ref),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 120,
                  height: 12,
                  decoration: BoxDecoration(
                    color: appCardFill(context, ref),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 80,
                  height: 10,
                  decoration: BoxDecoration(
                    color: appCardFill(context, ref),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面端排行榜同款逐条入场：每行 600ms easeOutExpo 上浮淡入
/// （透明度 0→1、上移 20px→0、模糊 4px→0），相邻行错峰 60ms；
/// 排名徽章的放大动画由行内 rankPop 单独承担。
class _StaggerIn extends StatelessWidget {
  const _StaggerIn({
    required this.controller,
    required this.index,
    required this.child,
  });

  /// 相邻行错峰（ms）。
  static const int staggerMs = 60;

  /// 单行入场时长（ms）。
  static const int rowMs = 600;

  /// 控制器总时长（ms）：覆盖最后一行入场 + 徽章弹性收尾。
  static const int totalMs = 2000;

  final Animation<double> controller;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final start = (index * staggerMs).clamp(0, totalMs - rowMs);
    final anim = CurvedAnimation(
      parent: controller,
      curve: Interval(
        start / totalMs,
        (start + rowMs) / totalMs,
        curve: Curves.easeOutExpo,
      ),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) {
        final t = anim.value;
        if (t <= 0) return const SizedBox.shrink();
        Widget content = Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - t)),
            child: child,
          ),
        );
        // 入场途中的轻模糊（4px→0），结束后直出，避免常驻滤镜开销。
        if (t < 1) {
          final sigma = 4 * (1 - t);
          content = ImageFiltered(
            imageFilter:
                ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: content,
          );
        }
        return content;
      },
      child: child,
    );
  }
}

class _PeriodTab extends StatelessWidget {
  const _PeriodTab({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.3),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _LeaderboardRow extends ConsumerWidget {
  const _LeaderboardRow({
    required this.entry,
    required this.isMe,
    required this.highlight,
    this.rankPop,
  });
  final LeaderboardEntry entry;
  final bool isMe;
  final bool highlight;

  /// 排名徽章弹性放大动画（跟随整行淡入，避免整行显示后排名“闪”出）。
  final Animation<double>? rankPop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    final name = entry.nickname.isNotEmpty ? entry.nickname : entry.username;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isMe
            ? scheme.primary.withValues(alpha: 0.08)
            : (highlight
                ? scheme.primary.withValues(alpha: 0.04)
                : (appCardFill(context, ref))),
        borderRadius: BorderRadius.circular(12),
        border: isMe
            ? Border.all(color: scheme.primary.withValues(alpha: 0.3))
            : null,
      ),
      child: Row(
        children: [
          _rankBadge(),
          const SizedBox(width: 12),
          _Avatar(name: name, avatar: entry.avatar),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(tr('你'),
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: scheme.onPrimary)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '@$name',
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatDuration(entry.duration),
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  /// 排名徽章：带可选的弹性放大入场（桌面端 rankPop 同款）。
  Widget _rankBadge() {
    final badge = _RankBadge(rank: entry.rank);
    final pop = rankPop;
    if (pop == null) return badge;
    return ScaleTransition(
      scale: Tween<double>(begin: 0.4, end: 1.0).animate(pop),
      child: badge,
    );
  }

  static String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return m > 0 ? tr('{h}小时{m}分', {'h': h, 'm': m}) : tr('{h}小时', {'h': h});
    return tr('{m}分钟', {'m': m});
  }
}

class _RankBadge extends ConsumerWidget {
  const _RankBadge({required this.rank});
  final int rank;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    final (Color bg, Color fg) = switch (rank) {
      1 => (const Color(0xFFFFA500), Colors.white),
      2 => (const Color(0xFFA8A8A8), Colors.white),
      3 => (const Color(0xFFA0522D), Colors.white),
      _ => (appCardFill(context, ref), scheme.onSurfaceVariant),
    };
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        boxShadow: rank <= 3
            ? [
                BoxShadow(
                    color: bg.withValues(alpha: 0.3),
                    blurRadius: 6,
                    offset: const Offset(0, 2)),
              ]
            : null,
      ),
      child: Text(
        '$rank',
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

class _Avatar extends ConsumerWidget {
  const _Avatar({required this.name, required this.avatar});
  final String name;
  final String avatar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    final char = name.isEmpty
        ? '?'
        : String.fromCharCode(name.runes.first).toUpperCase();
    return ClipOval(
      child: SizedBox(
        width: 36,
        height: 36,
        child: avatar.isNotEmpty
            ? UserAvatarImage(
                avatar: avatar,
                fallback: _fallback(context, ref, scheme, char),
                size: 36,
              )
            : _fallback(context, ref, scheme, char),
      ),
    );
  }

  Widget _fallback(
      BuildContext context, WidgetRef ref, ColorScheme scheme, String char) {
    return Container(
      color: appCardFill(context, ref),
      alignment: Alignment.center,
      child: Text(
        char,
        style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w700, color: scheme.primary),
      ),
    );
  }
}

class _LoginRow extends ConsumerWidget {
  const _LoginRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: appCardFill(context, ref),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('—',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)),
              ),
              const SizedBox(width: 12),
              ClipOval(
                child: Container(
                  width: 36,
                  height: 36,
                  color: appCardFill(context, ref),
                  alignment: Alignment.center,
                  child: Text(tr('未'),
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('未登录'),
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(tr('登录后查看个人排名'),
                        style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Text(tr('去登录'),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary)),
            ],
          ),
        ),
      ),
    );
  }
}
