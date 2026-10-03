part of 'effects_page.dart';

class _EqSection extends ConsumerWidget {
  const _EqSection({required this.settings, required this.notifier});
  final SoundEffectSettings settings;
  final SoundEffectManager notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final customPresets =
        ref.watch(soundEffectProvider).customEqPresets;
    final manager = ref.read(soundEffectProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  avatar: Icon(Icons.add, size: 18, color: scheme.primary),
                  label:   Text(tr('保存')),
                  onPressed: () => _savePreset(context, manager),
                ),
              ),
              for (final p in eqPresets)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(p.name),
                    selected: _isPresetActive(settings, p.gains),
                    onSelected: (_) => notifier.applyEqPreset(p.name),
                  ),
                ),
              if (customPresets.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _dividerDot(context),
                ),
                for (final p in customPresets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onLongPress: () => _editPreset(context, manager, p.name),
                      child: ChoiceChip(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.person_pin, size: 14),
                            const SizedBox(width: 4),
                            Text(p.name),
                          ],
                        ),
                        selected: _isPresetActive(settings, p.gains),
                        onSelected: (_) =>
                            manager.applyCustomEqPreset(p.name),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 16, 6),
          child: Text(
            customPresets.isEmpty ? tr('长按自定义预设可重命名或删除') : tr('预设 · 点按应用 · 长按编辑'),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        SizedBox(
          height: 180,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (var i = 0; i < eqFreqLabels.length; i++)
                _EqBand(
                  value: settings.eqGains[i],
                  freqLabel: eqFreqLabels[i],
                  onCommit: (v) => notifier.setEqGain(i, v),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dividerDot(BuildContext context) => Center(
        child: Container(
          width: 1,
          height: 20,
          color: Theme.of(context)
              .colorScheme
              .onSurfaceVariant
              .withValues(alpha: 0.3),
        ),
      );

  bool _isPresetActive(SoundEffectSettings s, List<double> gains) {
    if (s.eqGains.length != gains.length) return false;
    for (var i = 0; i < s.eqGains.length; i++) {
      if ((s.eqGains[i] - gains[i]).abs() > 0.01) return false;
    }
    return true;
  }

  Future<void> _savePreset(BuildContext context, SoundEffectManager manager) async {
    final scheme = Theme.of(context).colorScheme;
    final controller = TextEditingController();
    final name = await showSheetDialog<String>(
      context,
      (dialogContext) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('保存均衡器预设'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(tr('将当前 EQ 增益保存为自定义预设，同名将覆盖'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration:   InputDecoration(
                labelText: tr('预设名称'),
                hintText: tr('例如：我的流行'),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child:   Text(tr('取消')),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(dialogContext, controller.text.trim());
                  },
                  child:   Text(tr('保存')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      await manager.saveCustomEqPreset(name);
      if (context.mounted) {
        showXianYuToast(context, tr('已保存预设「{name}」', {'name': name}),
            duration: const Duration(seconds: 1));
      }
    }
  }

  Future<void> _editPreset(
      BuildContext context, SoundEffectManager manager, String name) async {
    final scheme = Theme.of(context).colorScheme;
    final action = await showSheetDialog<String>(
      context,
      (dialogContext) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(tr('预设「{name}」', {'name': name}),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title:   Text(tr('重命名')),
              onTap: () => Navigator.pop(dialogContext, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text(tr('删除'), style: TextStyle(color: scheme.error)),
              onTap: () => Navigator.pop(dialogContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'rename') {
      if (!context.mounted) return;
      final controller = TextEditingController(text: name);
      final newName = await showSheetDialog<String>(
        context,
        (dialogContext) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('重命名预设'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration:   InputDecoration(
                  labelText: tr('预设名称'),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) =>
                    Navigator.pop(dialogContext, v.trim()),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child:   Text(tr('取消')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext, controller.text.trim()),
                    child:   Text(tr('保存')),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      controller.dispose();
      if (newName != null && newName.isNotEmpty) {
        await manager.renameCustomEqPreset(name, newName);
      }
    } else if (action == 'delete') {
      await manager.deleteCustomEqPreset(name);
      if (context.mounted) {
        showXianYuToast(context, tr('已删除预设「{name}」', {'name': name}),
            duration: const Duration(seconds: 1));
      }
    }
  }
}
