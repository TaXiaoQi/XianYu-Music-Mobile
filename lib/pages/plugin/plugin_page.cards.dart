part of 'plugin_page.dart';

class _SubscriptionSection extends ConsumerWidget {
  const _SubscriptionSection({
    required this.subscriptions,
    required this.onReinstall,
  });

  final List<PluginSubscription> subscriptions;
  final Future<void> Function(String url) onReinstall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.rss_feed, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Text(
              tr('订阅链接 · {n}', {'n': subscriptions.length}),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          tr('随插件同步到云端，点击可重新导入最新版本'),
          style: TextStyle(fontSize: 11, color: appSecondaryFg(scheme)),
        ),
        const SizedBox(height: 8),
        for (final sub in subscriptions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: PressableScale(
              // 订阅条与插件/云盘卡同款磨砂面（settings.group 槽位，
              // 跟随主题与毛玻璃档位），替代半透明纯色
              child: frostedCardSurface(
                context: context,
                ref: ref,
                radius: 14,
                themeSlot: 'settings.group',
                child: Material(
                  color: Colors.transparent,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide.none,
                  ),
                  child: InkWell(
                    onTap: () => onReinstall(sub.url),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Icon(
                              Icons.link,
                              size: 18,
                              color: scheme.primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  sub.name,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  sub.url,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: appSecondaryFg(scheme),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: appSecondaryFg(scheme),
                            ),
                            tooltip: tr('移除订阅'),
                            onPressed: () async {
                              // 云端订阅为各端并集，本地移除前先显式删云端；
                              // 未登录/离线时仅删本地（云端留存的会被下次下载合并回来）
                              try {
                                await ref
                                    .read(accountApiProvider)
                                    .deleteCloudSubscriptions([sub.url]);
                              } catch (_) {}
                              await ref
                                  .read(pluginSubscriptionsProvider.notifier)
                                  .remove(sub.id);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onInstall});
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.extension_outlined, size: 56, color: appSecondaryFg(scheme)),
          const SizedBox(height: 12),
          Text(tr('还没有安装插件'), style: TextStyle(color: appSecondaryFg(scheme))),
          const SizedBox(height: 4),
          Text(
            tr('支持 LX / MusicFree 格式插件'),
            style: TextStyle(fontSize: 12, color: appSecondaryFg(scheme)),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onInstall,
            icon: const Icon(Icons.add),
            label: Text(tr('安装插件')),
          ),
        ],
      ),
    );
  }
}

class _HoldDragStartListener extends StatefulWidget {
  const _HoldDragStartListener({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_HoldDragStartListener> createState() => _HoldDragStartListenerState();
}

class _DelayedDragRecognizerListener
    extends ReorderableDelayedDragStartListener {
  const _DelayedDragRecognizerListener({
    required super.child,
    required super.index,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() {
    return DelayedMultiDragGestureRecognizer(
      delay: const Duration(milliseconds: 300),
      debugOwner: this,
    );
  }
}

class _HoldDragStartListenerState extends State<_HoldDragStartListener> {
  Timer? _haptic;

  void _onDown(PointerDownEvent _) {
    _haptic?.cancel();
    _haptic = Timer(const Duration(milliseconds: 300), () {
      if (mounted) HapticFeedback.mediumImpact();
    });
  }

  void _clear() {
    _haptic?.cancel();
    _haptic = null;
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      child: _DelayedDragRecognizerListener(
        index: widget.index,
        child: widget.child,
      ),
    );
  }
}

class _CloudCard extends ConsumerWidget {
  const _CloudCard({
    required this.providerId,
    required this.index,
    required this.dragEnabled,
    required this.accountCount,
    required this.enabled,
    required this.onToggle,
    required this.onRemove,
  });

  final String providerId;
  final int index;
  final bool dragEnabled;
  final int accountCount;
  final bool enabled;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    const iconColor = Color(0xFFEC4141);
    final iconBg = const Color(0x1AEC4141);

    final providerName = cloudProviders
        .where((p) => p.id == providerId)
        .map((p) => p.displayName)
        .firstOrNull;
    final name = providerName ?? providerId;
    final desc = enabled
        ? tr('已绑定 {n} 个账号，搜索时可拉取该网盘音乐', {'n': accountCount})
        : tr('已关闭，搜索不再拉取该网盘');

    final icon = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: iconBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.cloud_outlined, color: iconColor, size: 22),
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                tr('网盘'),
                style: const TextStyle(
                  fontSize: 10,
                  color: iconColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'v1.0.0 · 小奇 · $desc',
          style: TextStyle(fontSize: 12, color: appSecondaryFg(scheme)),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    final toggle = Switch(
      value: enabled,
      activeThumbColor: iconColor,
      onChanged: (_) => onToggle(),
    );

    final delete = _action(
      context,
      Icons.delete_outline,
      tr('删除'),
      onRemove,
      color: appSecondaryFg(scheme),
    );

    final isWide = MediaQuery.orientationOf(context) == Orientation.landscape;

    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 14,
      themeSlot: 'settings.group',
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide.none,
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(50, 8, 8, 6),
              child: isWide
                  ? Row(
                      children: [
                        icon,
                        const SizedBox(width: 12),
                        Expanded(child: info),
                        const SizedBox(width: 8),
                        delete,
                        const SizedBox(width: 4),
                        toggle,
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            icon,
                            const SizedBox(width: 12),
                            Expanded(child: info),
                            const SizedBox(width: 6),
                            toggle,
                          ],
                        ),
                        const SizedBox(height: 4),
                        delete,
                      ],
                    ),
            ),
            Positioned(
              left: 4,
              top: 0,
              bottom: 0,
              width: 36,
              child: Center(
                child: dragEnabled
                    ? _HoldDragStartListener(
                        index: index,
                        child: Icon(
                          Icons.drag_indicator,
                          size: 34,
                          color: appSecondaryFg(scheme),
                        ),
                      )
                    : Icon(
                        Icons.drag_indicator,
                        size: 34,
                        color: appSecondaryFg(scheme),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color? color,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? appSecondaryFg(scheme);
    return PressableScale(
      pressScale: 0.88,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: c),
              const SizedBox(width: 5),
              Text(label, style: TextStyle(fontSize: 13, color: c)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PluginCard extends ConsumerWidget {
  const _PluginCard({
    required this.source,
    required this.index,
    required this.dragEnabled,
    required this.hasVars,
    required this.onUpdate,
  });

  final PluginSource source;
  final int index;
  final bool dragEnabled;
  final bool hasVars;
  final Future<void> Function(BuildContext context) onUpdate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    Color iconBg;
    Color iconColor;
    if (source.format == PluginFormat.lx) {
      iconBg = const Color(0x1A22C55E);
      iconColor = const Color(0xFF22C55E);
    } else if (source.format == PluginFormat.anime) {
      iconBg = const Color(0x1AA855F7);
      iconColor = const Color(0xFFA855F7);
    } else if (source.format == PluginFormat.musicfree &&
        source.author.toLowerCase().contains('toskysun')) {
      iconBg = const Color(0x1A3B82F6);
      iconColor = const Color(0xFF3B82F6);
    } else if (source.format == PluginFormat.musicfree) {
      iconBg = const Color(0x1AF97316);
      iconColor = const Color(0xFFF97316);
    } else {
      iconBg = const Color(0x1AEC4141);
      iconColor = const Color(0xFFEC4141);
    }

    final subText = [
      if (source.version.isNotEmpty) 'v${source.version}',
      if (source.author.isNotEmpty) source.author,
      if (source.description.isNotEmpty) source.description,
    ].join(' · ');

    final tagLabel = source.format == PluginFormat.lx
        ? tr('落雪')
        : source.format == PluginFormat.anime
        ? 'anime'
        : source.format == PluginFormat.musicfree
        ? (source.author.toLowerCase().contains('toskysun')
              ? 'BakaMusic'
              : 'MusicFree')
        : tr('未知');

    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 14,
      themeSlot: 'settings.group',
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide.none,
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(50, 8, 8, 6),
              child: _buildBody(
                context,
                ref,
                scheme,
                iconBg,
                iconColor,
                subText,
                tagLabel,
              ),
            ),
            Positioned(
              left: 4,
              top: 0,
              bottom: 0,
              width: 36,
              child: Center(
                child: dragEnabled
                    ? _HoldDragStartListener(
                        index: index,
                        child: Icon(
                          Icons.drag_indicator,
                          size: 34,
                          color: appSecondaryFg(scheme),
                        ),
                      )
                    : Icon(
                        Icons.drag_indicator,
                        size: 34,
                        color: appSecondaryFg(scheme),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    ColorScheme scheme,
    Color iconBg,
    Color iconColor,
    String subText,
    String tagLabel,
  ) {
    final manager = ref.read(pluginManagerProvider.notifier);
    final subTag = pluginSubTagInfo(
      source,
      ref.watch(pluginSubscriptionsProvider),
    );

    final icon = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: iconBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        source.format == PluginFormat.lx ? Icons.music_note : Icons.extension,
        color: iconColor,
        size: 22,
      ),
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                pluginDisplayName(source),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                tagLabel,
                style: TextStyle(
                  fontSize: 10,
                  color: iconColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (subTag != null) ...[
              const SizedBox(width: 6),
              Builder(
                builder: (_) {
                  // 付费来源金色高亮；免费聚合音源（全豆要/次合代）用 baka 配色
                  final dark = scheme.brightness == Brightness.dark;
                  final tagColor = subTag.paid
                      ? const Color(0xFFE6A23C)
                      : (dark
                            ? const Color(0xFF93C5FD)
                            : const Color(0xFF1D4ED8));
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: tagColor.withValues(alpha: dark ? 0.15 : 0.1),
                      borderRadius: BorderRadius.circular(5),
                      border: subTag.paid
                          ? Border.all(
                              color: tagColor.withValues(alpha: 0.4),
                              width: 0.5,
                            )
                          : null,
                    ),
                    child: Text(
                      subTag.label,
                      style: TextStyle(
                        fontSize: 10,
                        color: tagColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                },
              ),
            ],
            if (source.updateAvailable) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.error.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  tr('可更新'),
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (hasVars) ...[
              const SizedBox(width: 6),
              Icon(Icons.tune_outlined, size: 15, color: scheme.primary),
            ],
          ],
        ),
        if (subText.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            subText,
            style: TextStyle(fontSize: 12, color: appSecondaryFg(scheme)),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );

    final toggle = Switch(
      value: source.enabled,
      activeThumbColor: iconColor,
      onChanged: (_) => manager.toggleEnabled(source.id),
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _action(
          context,
          Icons.info_outline,
          tr('详情'),
          () => _openDetail(context, ref),
        ),
        const SizedBox(width: 4),
        _action(
          context,
          Icons.system_update_alt_outlined,
          tr('更新'),
          () => onUpdate(context),
          color: source.updateAvailable ? scheme.error : null,
        ),
        const SizedBox(width: 4),
        _action(
          context,
          Icons.delete_outline,
          tr('删除'),
          () => _confirmRemove(context, ref, manager),
        ),
      ],
    );

    final isWide = MediaQuery.orientationOf(context) == Orientation.landscape;

    if (isWide) {
      return Row(
        children: [
          icon,
          const SizedBox(width: 12),
          Expanded(child: info),
          const SizedBox(width: 8),
          actions,
          const SizedBox(width: 4),
          toggle,
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            icon,
            const SizedBox(width: 12),
            Expanded(child: info),
            const SizedBox(width: 6),
            toggle,
          ],
        ),
        const SizedBox(height: 4),
        actions,
      ],
    );
  }

  Widget _action(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color? color,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? appSecondaryFg(scheme);
    return PressableScale(
      pressScale: 0.88,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: c),
              const SizedBox(width: 5),
              Text(label, style: TextStyle(fontSize: 13, color: c)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openDetail(BuildContext context, WidgetRef ref) async {
    await showSheetDialog<void>(
      context,
      (ctx) => _PluginDetailSheet(source: source),
    );
  }

  void _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    PluginManager manager,
  ) {
    unawaited(confirmRemovePlugin(context, ref, source));
  }
}
