import 'package:flutter/material.dart';

import '../widgets/modern_dialog.dart';
import '../widgets/predictive_dialog_route.dart';
import '../i18n/i18n.dart';

/// 冲突解决方向：保留本地 / 保留云端。
enum SyncDirection { local, cloud }

/// 按类别的同步选择（设置/歌单/插件）。
class SyncCategoryChoices {
  final SyncDirection settings;
  final SyncDirection playlists;
  final SyncDirection plugins;

  const SyncCategoryChoices({
    required this.settings,
    required this.playlists,
    required this.plugins,
  });

  SyncCategoryChoices copyWith({
    SyncDirection? settings,
    SyncDirection? playlists,
    SyncDirection? plugins,
  }) {
    return SyncCategoryChoices(
      settings: settings ?? this.settings,
      playlists: playlists ?? this.playlists,
      plugins: plugins ?? this.plugins,
    );
  }
}

/// 展示设置同步冲突弹窗（两段式：先整体选择方向，再按类别精细调整）。
///
/// 与桌面端 SettingsConflictDialog 对齐：第一弹窗展示本地/云端时间并让用户
/// 选择整体保留方向；第二弹窗按类别（设置/歌单/插件）分别选择保留本地或云端。
/// 返回 null 表示用户取消。
Future<SyncCategoryChoices?> showSettingsConflictDialog({
  required BuildContext context,
  required DateTime localTime,
  required DateTime cloudTime,
}) async {
  // 先取 root Navigator，避免跨 async 使用 BuildContext。
  final navigator = Navigator.of(context, rootNavigator: true);
  final direction = await navigator.push<SyncDirection>(
    PredictiveBackDialogRoute<SyncDirection>(
      builder: (ctx) => _ConflictOverallDialog(
        localTime: localTime,
        cloudTime: cloudTime,
      ),
    ),
  );
  if (direction == null) return null;
  return navigator.push<SyncCategoryChoices>(
    PredictiveBackDialogRoute<SyncCategoryChoices>(
      builder: (ctx) => _ConflictCategoryDialog(initialDirection: direction),
    ),
  );
}

String _formatTime(DateTime t) {
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${pad(t.month)}-${pad(t.day)} ${pad(t.hour)}:${pad(t.minute)}';
}

/// 第一弹窗：整体冲突选择（保留本地 / 保留云端 / 取消）。
class _ConflictOverallDialog extends StatelessWidget {
  const _ConflictOverallDialog({
    required this.localTime,
    required this.cloudTime,
  });

  final DateTime localTime;
  final DateTime cloudTime;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ModernDialogCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.sync_problem_rounded,
                      color: scheme.error, size: 22),
                ),
                const SizedBox(width: 14),
                  Expanded(
                  child: Text(
                    tr('设置同步冲突'),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              tr('检测到本地设置与云端设置不一致，请选择要保留的版本。下一步可按类别精细调整。'),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            _TimeRow(
              icon: Icons.smartphone_rounded,
              label: tr('本地设置'),
              time: _formatTime(localTime),
            ),
            const SizedBox(height: 8),
            _TimeRow(
              icon: Icons.cloud_rounded,
              label: tr('云端设置'),
              time: _formatTime(cloudTime),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child:   Text(tr('取消')),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () =>
                      Navigator.of(context).pop(SyncDirection.cloud),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child:   Text(tr('保留云端')),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(SyncDirection.local),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 11,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child:   Text(tr('保留本地')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 时间信息行（本地/云端）。
class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.icon,
    required this.label,
    required this.time,
  });

  final IconData icon;
  final String label;
  final String time;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
          const Spacer(),
          Text(
            time,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 第二弹窗：按类别精细调整（设置/歌单/插件各自选择本地或云端）。
class _ConflictCategoryDialog extends StatefulWidget {
  const _ConflictCategoryDialog({required this.initialDirection});

  final SyncDirection initialDirection;

  @override
  State<_ConflictCategoryDialog> createState() =>
      _ConflictCategoryDialogState();
}

class _ConflictCategoryDialogState extends State<_ConflictCategoryDialog> {
  late SyncCategoryChoices _choices = SyncCategoryChoices(
    settings: widget.initialDirection,
    playlists: widget.initialDirection,
    plugins: widget.initialDirection,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ModernDialogCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.tune_rounded,
                      color: scheme.primary, size: 22),
                ),
                const SizedBox(width: 14),
                  Expanded(
                  child: Text(
                    tr('按类别选择'),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              tr('请为每类数据选择保留本地还是云端。'),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            _CategoryRow(
              icon: Icons.settings_rounded,
              label: tr('设置'),
              desc: tr('播放、歌词、外观等偏好配置'),
              direction: _choices.settings,
              onChanged: (d) => setState(() => _choices = _choices.copyWith(settings: d)),
            ),
            const SizedBox(height: 10),
            _CategoryRow(
              icon: Icons.queue_music_rounded,
              label: tr('歌单'),
              desc: tr('本地创建与编辑的歌单'),
              direction: _choices.playlists,
              onChanged: (d) => setState(() => _choices = _choices.copyWith(playlists: d)),
            ),
            const SizedBox(height: 10),
            _CategoryRow(
              icon: Icons.extension_rounded,
              label: tr('插件'),
              desc: tr('已安装的插件配置'),
              direction: _choices.plugins,
              onChanged: (d) => setState(() => _choices = _choices.copyWith(plugins: d)),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child:   Text(tr('取消')),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_choices),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 11,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child:   Text(tr('确认同步')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 类别行：图标 + 名称 + 描述 + 本地/云端切换。
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.icon,
    required this.label,
    required this.desc,
    required this.direction,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String desc;
  final SyncDirection direction;
  final ValueChanged<SyncDirection> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  desc,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _DirectionToggle(
            direction: direction,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// 本地/云端二选一切换（软色胶囊高亮，对齐移动端选择控件风格）。
class _DirectionToggle extends StatelessWidget {
  const _DirectionToggle({
    required this.direction,
    required this.onChanged,
  });

  final SyncDirection direction;
  final ValueChanged<SyncDirection> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToggleChip(
            label: tr('本地'),
            selected: direction == SyncDirection.local,
            onTap: () => onChanged(SyncDirection.local),
          ),
          const SizedBox(width: 3),
          _ToggleChip(
            label: tr('云端'),
            selected: direction == SyncDirection.cloud,
            onTap: () => onChanged(SyncDirection.cloud),
          ),
        ],
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  const _ToggleChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
