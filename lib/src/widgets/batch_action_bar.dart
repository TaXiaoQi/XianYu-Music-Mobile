import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mini_player_bar.dart';
import '../i18n/i18n.dart';

class SongBatchController extends ChangeNotifier {
  bool _batchMode = false;
  bool get batchMode => _batchMode;

  final Set<String> _selected = {};
  Set<String> get selected => _selected;
  int get selectedCount => _selected.length;

  void enter() {
    _batchMode = true;
    notifyListeners();
  }

  void exit() {
    _batchMode = false;
    _selected.clear();
    notifyListeners();
  }

  void toggle(String path) {
    if (!_selected.remove(path)) _selected.add(path);
    notifyListeners();
  }

  bool isSelected(String path) => _selected.contains(path);

  void toggleSelectAll(Set<String> all) {
    if (all.isNotEmpty && _selected.length == all.length) {
      _selected.clear();
    } else {
      _selected
        ..clear()
        ..addAll(all);
    }
    notifyListeners();
  }
}

Widget wrapBatchRow(
  BuildContext context, {
  required Widget row,
  required bool selected,
  required VoidCallback onToggle,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Stack(
    children: [
      Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.07)
            : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.only(left: 44),
          child: row,
        ),
      ),
      Positioned(
        left: 8,
        top: 0,
        bottom: 0,
        width: 36,
        child: Center(
          child: SongBatchCheckbox(selected: selected, onTap: onToggle),
        ),
      ),
    ],
  );
}

class SongBatchCheckbox extends StatelessWidget {
  const SongBatchCheckbox({
    super.key,
    required this.selected,
    required this.onTap,
  });

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? scheme.primary : Colors.transparent,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: 1.4,
          ),
        ),
        child: selected
            ? Icon(Icons.check, size: 13, color: scheme.onPrimary)
            : null,
      ),
    );
  }
}

class SongBatchRow extends StatelessWidget {
  const SongBatchRow({
    super.key,
    required this.cover,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.selected,
    required this.onToggle,
    this.verticalPadding = 8,
  });

  final Widget cover;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final bool selected;
  final VoidCallback onToggle;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.07)
          : Colors.transparent,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: verticalPadding,
          ),
          child: Row(
            children: [
              cover,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title,
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      subtitle!,
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 44),
          child: row,
        ),
        Positioned(
          left: 8,
          top: 0,
          bottom: 0,
          width: 36,
          child: Center(
            child: SongBatchCheckbox(selected: selected, onTap: onToggle),
          ),
        ),
      ],
    );
  }
}

class BatchActionBar extends ConsumerStatefulWidget {
  const BatchActionBar({
    super.key,
    required this.selectedCount,
    required this.totalCount,
    this.showPlay = false,
    this.showFavorite = false,
    this.showPlaylist = false,
    this.showDownload = false,
    this.showRemove = true,
    required this.onSelectAll,
    this.onPlay,
    this.onFavorite,
    this.onPlaylist,
    this.onDownload,
    required this.onRemove,
    required this.onDone,
  });

  final int selectedCount;
  final int totalCount;

  final bool showPlay;
  final bool showFavorite;
  final bool showPlaylist;
  final bool showDownload;
  final bool showRemove;

  final VoidCallback onSelectAll;
  final VoidCallback? onPlay;
  final VoidCallback? onFavorite;
  final VoidCallback? onPlaylist;
  final VoidCallback? onDownload;
  final VoidCallback onRemove;
  final VoidCallback onDone;

  @override
  ConsumerState<BatchActionBar> createState() => _BatchActionBarState();
}

class _BatchActionBarState extends ConsumerState<BatchActionBar> {
  final GlobalKey _rootKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportLift();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportLift();
    });
  }

  @override
  void dispose() {
    ref.read(batchBarLiftProvider.notifier).state = 0;
    super.dispose();
  }

  void _reportLift() {
    final render = _rootKey.currentContext?.findRenderObject();
    if (render is RenderBox) {
      ref.read(batchBarLiftProvider.notifier).state = render.size.height;
    }
  }

  bool get _allSelected =>
      widget.selectedCount >= widget.totalCount && widget.totalCount > 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.selectedCount > 0;

    Widget action({
      required IconData icon,
      required String label,
      required VoidCallback? onTap,
      bool danger = false,
    }) {
      final on = onTap != null && enabled;
      final color = on
          ? (danger ? const Color(0xFFEC4141) : scheme.onSurface)
          : scheme.onSurface.withValues(alpha: 0.32);
      return InkWell(
        onTap: on ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 21, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(fontSize: 10.5, color: color),
              ),
            ],
          ),
        ),
      );
    }

    final bar = SafeArea(
      key: _rootKey,
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  tr('已选 {n} 首', {'n': widget.selectedCount}),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: widget.onSelectAll,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  ),
                  child: Text(
                    _allSelected ? tr('取消全选') : tr('全选'),
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: widget.onDone,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  ),
                  child: Text(
                    tr('完成'),
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: 58,
              child: ListView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                children: [
                  action(
                    icon: Icons.play_arrow_rounded,
                    label: tr('播放'),
                    onTap: widget.showPlay ? widget.onPlay : null,
                  ),
                  if (widget.showFavorite)
                    action(
                      icon: Icons.favorite_border_rounded,
                      label: tr('收藏'),
                      onTap: widget.onFavorite,
                    ),
                  if (widget.showPlaylist)
                    action(
                      icon: Icons.playlist_add_rounded,
                      label: tr('歌单'),
                      onTap: widget.onPlaylist,
                    ),
                  if (widget.showDownload)
                    action(
                      icon: Icons.download_rounded,
                      label: tr('下载'),
                      onTap: widget.onDownload,
                    ),
                  if (widget.showRemove)
                    action(
                      icon: Icons.delete_outline_rounded,
                      label: tr('移除'),
                      onTap: widget.onRemove,
                      danger: true,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return playbarGlassSurface(context, ref, radius: 18, child: bar);
  }
}
