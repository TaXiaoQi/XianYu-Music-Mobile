import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/account_api.dart';
import '../../src/core/app_colors.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/auth/server_models.dart';
import '../../src/stats/listen_stats.dart';
import '../../src/widgets/user_avatar.dart';

/// 听歌排行榜：日榜/周榜/总榜切换，Top 列表 + 底部个人排名。
class LeaderboardPage extends ConsumerStatefulWidget {
  const LeaderboardPage({super.key});

  @override
  ConsumerState<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends ConsumerState<LeaderboardPage> {
  static const _periods = [
    (value: 'daily', label: '日榜'),
    (value: 'weekly', label: '周榜'),
    (value: 'total', label: '总榜'),
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
      final durations = await ref.read(listenStatsProvider).getDurations();
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
        'daily' => '单日听歌时长排行',
        'weekly' => '本周听歌时长排行',
        _ => '累计听歌时长排行',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = ref.watch(authProvider);
    final loggedIn = auth.isLoggedIn;

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(title: const Text('听歌排行榜')),
      body: Column(
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
                    color: appCardColor(context),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final p in _periods)
                        _PeriodTab(
                          label: p.label,
                          active: _period == p.value,
                          onTap: _loading ? null : () => _switchPeriod(p.value),
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
    );
  }

  Widget _buildBody(ColorScheme scheme, bool loggedIn) {
    if (_loading) {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: 8,
        itemBuilder: (_, i) => Container(
          height: 56,
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: appCardColor(context),
            borderRadius: BorderRadius.circular(12),
          ),
          child: _skeletonRow(scheme),
        ),
      );
    }
    if (_error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 44, color: scheme.outline),
            const SizedBox(height: 12),
            Text('排行榜加载失败',
                style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('点击重试')),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text('暂无排行榜数据',
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: appCardColor(context),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: appCardColor(context),
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
                    color: appCardColor(context),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 80,
                  height: 10,
                  decoration: BoxDecoration(
                    color: appCardColor(context),
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

class _LeaderboardRow extends StatelessWidget {
  const _LeaderboardRow({
    required this.entry,
    required this.isMe,
    required this.highlight,
  });
  final LeaderboardEntry entry;
  final bool isMe;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
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
                : appCardColor(context)),
        borderRadius: BorderRadius.circular(12),
        border: isMe
            ? Border.all(color: scheme.primary.withValues(alpha: 0.3))
            : null,
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
                        child: Text('你',
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
    if (h > 0) return m > 0 ? '$h小时$m分' : '$h小时';
    return '$m分钟';
  }
}

class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank});
  final int rank;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = switch (rank) {
      1 => (const Color(0xFFFFA500), Colors.white),
      2 => (const Color(0xFFA8A8A8), Colors.white),
      3 => (const Color(0xFFA0522D), Colors.white),
      _ => (appCardColor(context), scheme.onSurfaceVariant),
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

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.avatar});
  final String name;
  final String avatar;

  @override
  Widget build(BuildContext context) {
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
                fallback: _fallback(context, scheme, char),
              )
            : _fallback(context, scheme, char),
      ),
    );
  }

  Widget _fallback(BuildContext context, ColorScheme scheme, String char) {
    return Container(
      color: appCardColor(context),
      alignment: Alignment.center,
      child: Text(
        char,
        style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w700, color: scheme.primary),
      ),
    );
  }
}

class _LoginRow extends StatelessWidget {
  const _LoginRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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
                  color: appCardColor(context),
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
                  color: appCardColor(context),
                  alignment: Alignment.center,
                  child: Text('未',
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
                    Text('未登录',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text('登录后查看个人排名',
                        style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Text('去登录',
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
