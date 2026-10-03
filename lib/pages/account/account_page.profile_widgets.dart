part of 'account_page.dart';

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.status,
    required this.pendingText,
    required this.rejectedText,
    required this.onRefresh,
    required this.refreshing,
  });
  final String status;
  final String pendingText;
  final String rejectedText;
  final VoidCallback onRefresh;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    if (status != 'pending' && status != 'rejected') {
      return const SizedBox(height: 4);
    }
    final isPending = status == 'pending';
    final color = isPending ? const Color(0xFFB45309) : const Color(0xFFE11D48);
    final bg = isPending
        ? const Color(0x1AB45309)
        : const Color(0x1AE11D48);
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isPending ? Icons.hourglass_top : Icons.close,
                size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              isPending ? pendingText : rejectedText,
              style: TextStyle(fontSize: 11, color: color),
            ),
            if (isPending) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: refreshing ? null : onRefresh,
                child: refreshing
                    ? SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: color),
                      )
                    : Icon(Icons.refresh, size: 13, color: color),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileHeaderCard extends ConsumerWidget {
  const _ProfileHeaderCard({
    required this.user,
    required this.onCopy,
    this.avatarUploading = false,
    this.onAvatarTap,
    this.onNicknameTap,
  });

  final AuthUser user;
  final Function(BuildContext, String, String) onCopy;
  final bool avatarUploading;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onNicknameTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      decoration: BoxDecoration(
        color: appCardFill(context, ref),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: onAvatarTap,
            child: Stack(
              children: [
                _Avatar(user: user),
                if (onAvatarTap != null)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 2),
                      ),
                      child: avatarUploading
                          ? Padding(
                              padding: const EdgeInsets.all(6),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.onPrimary),
                            )
                          : Icon(Icons.photo_camera,
                              size: 15, color: scheme.onPrimary),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          InkWell(
            onTap: onNicknameTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      user.nickname.isEmpty ? tr('弦予用户') : user.nickname,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onNicknameTap != null) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.edit, size: 16, color: scheme.onSurfaceVariant),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.verified_user_rounded,
                      size: 14,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      user.role.isNotEmpty ? user.role : tr('标准会员'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              if (user.ciyuanxiId != null && user.ciyuanxiId!.isNotEmpty) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => onCopy(context, user.ciyuanxiId!, tr('弦予号')),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'ID: ${user.ciyuanxiId}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.copy_rounded,
                          size: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.user});
  final AuthUser user;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = user.avatar;
    final hasAvatar = avatar != null && avatar.isNotEmpty;
    final fallbackChar = user.nickname.isEmpty
        ? '?'
        : String.fromCharCode(user.nickname.runes.first);

    return Container(
      width: 92,
      height: 92,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            scheme.primary,
            scheme.primary.withValues(alpha: 0.6),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.35),
            blurRadius: 28,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(2.5),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.surface,
        ),
        clipBehavior: Clip.antiAlias,
        child: hasAvatar
            ? UserAvatarImage(
                avatar: avatar,
                fallback: _fallback(fallbackChar, scheme.primary, scheme.onPrimary),
                size: 87,
              )
            : _fallback(fallbackChar, scheme.primary, scheme.onPrimary),
      ),
    );
  }

  Widget _fallback(String char, Color bg, Color fg) {
    return Container(
      color: bg,
      child: Center(
        child: Text(
          char.toUpperCase(),
          style: TextStyle(
            fontSize: 38,
            fontWeight: FontWeight.bold,
            color: fg,
          ),
        ),
      ),
    );
  }
}
