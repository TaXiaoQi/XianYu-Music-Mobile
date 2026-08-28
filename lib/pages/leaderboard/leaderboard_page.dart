import 'dart:convert';

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
class LeaderboardPage extends ConsumerStatefulWidget {
  const LeaderboardPage({super.key});

  @override
  ConsumerState<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends ConsumerState<LeaderboardPage> {
  static get _periods => [
    (value: 'daily', label: tr('日榜')),
    (value: 'weekly', label: tr('周榜')),
    (value: 'total', label: tr('总榜')),
  ];

  String _period = 'daily';
  List<LeaderboardEntry> _entries = [];
  bool _loading = true;
  bool _error = false;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _load();
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
          .fetchLeaderboard(limit: 15, period: _period, durations: durations);
      if (!mounted || requestId != _requestId) return;
      final list = List<LeaderboardEntry>.from(data.leaderboard);
      if (data.me != null && !list.any((e) => e.isMe)) {
        list.add(data.me!);
      }
      setState(() {
        _entries = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _entries = [];
        _loading = false;
        _error = true;
      });
    }
  }

  void _switchPeriod(String period) {
    if (period == _period) return;
    setState(() => _period = period);
    _load();
  }

  String get _periodLabel => switch (_period) {
        'daily' => tr('单日听歌时长排行'),
        'weekly' => tr('本周听歌时长排行'),
        _ => tr('累计听歌时长排行'),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = ref.watch(authProvider);
    final loggedIn = auth.isLoggedIn;
    final glass = ref.watch(wallpaperActiveProvider);

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: GlassTopBar.height(context)),
            child: Column(
              children: [
                // 周期切换
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _periodLabel,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: glass ? glassControlFill : appCardColor(context),
                          borderRadius: BorderRadius.circular(10),
                          border: glass
                              ? Border.all(color: glassControlBorder)
                              : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final p in _periods)
                              _PeriodTab(
                                label: p.label,
                                active: _period == p.value,
                                onTap: _loading
                                    ? null
                                    : () => _switchPeriod(p.value),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _buildBody(scheme, loggedIn)),
              ],
            ),
          ),
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

  Widget _buildBody(ColorScheme scheme, bool loggedIn) {
    final glass = ref.watch(wallpaperActiveProvider);
    if (_loading) {
      // 骨架行复用同一原型：prototypeItem 让 Sliver 直接按固定行高估算滚动范围，
      // 避免首帧逐行测量再布局（对齐 PiliNara 的 prototypeItem 骨架屏）。
      final skeleton = Container(
        height: 56,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: glass ? glassControlFill : appCardColor(context),
          borderRadius: BorderRadius.circular(12),
          border: glass ? Border.all(color: glassControlBorder) : null,
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        for (final e in top)
          _LeaderboardRow(
            entry: e,
            isMe: e.isMe,
            highlight: e.rank <= 3,
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
          _LeaderboardRow(entry: me, isMe: true, highlight: me.rank <= 3),
        ] else if (!loggedIn) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Center(
              child: Text('···',
                  style: TextStyle(
                      fontSize: 12, letterSpacing: 2, color: Colors.grey)),
            ),
          ),
          _LoginRow(onTap: () => context.push('/account')),
        ],
      ],
    );
  }

  Widget _skeletonRow(ColorScheme scheme) {
    final glass = ref.watch(wallpaperActiveProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: glass ? glassControlFill : appCardColor(context),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: glass ? glassControlFill : appCardColor(context),
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
                    color: glass ? glassControlFill : appCardColor(context),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 80,
                  height: 10,
                  decoration: BoxDecoration(
                    color: glass ? glassControlFill : appCardColor(context),
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
  });
  final LeaderboardEntry entry;
  final bool isMe;
  final bool highlight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final glass = ref.watch(wallpaperActiveProvider);
    final name = entry.nickname.isNotEmpty ? entry.nickname : entry.username;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isMe
            ? scheme.primary.withValues(alpha: 0.08)
            : (highlight
                ? scheme.primary.withValues(alpha: 0.04)
                : (glass ? glassControlFill : appCardColor(context))),
        borderRadius: BorderRadius.circular(12),
        border: isMe
            ? Border.all(color: scheme.primary.withValues(alpha: 0.3))
            : (glass ? Border.all(color: glassControlBorder) : null),
      ),
      child: Row(
        children: [
          _RankBadge(rank: entry.rank),
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
    final glass = ref.watch(wallpaperActiveProvider);
    final (Color bg, Color fg) = switch (rank) {
      1 => (const Color(0xFFFFA500), Colors.white),
      2 => (const Color(0xFFA8A8A8), Colors.white),
      3 => (const Color(0xFFA0522D), Colors.white),
      _ => (glass ? glassControlFill : appCardColor(context), scheme.onSurfaceVariant),
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
    final glass = ref.watch(wallpaperActiveProvider);
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
                fallback: _fallback(context, scheme, glass, char),
                size: 36,
              )
            : _fallback(context, scheme, glass, char),
      ),
    );
  }

  Widget _fallback(
      BuildContext context, ColorScheme scheme, bool glass, String char) {
    return Container(
      color: glass ? glassControlFill : appCardColor(context),
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
    final glass = ref.watch(wallpaperActiveProvider);
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
                  color: glass ? glassControlFill : appCardColor(context),
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
                  color: glass ? glassControlFill : appCardColor(context),
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
