part of 'plugin_page.dart';

class _PluginDetailSheet extends ConsumerStatefulWidget {
  const _PluginDetailSheet({required this.source});
  final PluginSource source;

  @override
  ConsumerState<_PluginDetailSheet> createState() => _PluginDetailSheetState();
}

class _PluginDetailSheetState extends ConsumerState<_PluginDetailSheet> {
  List<PluginUserVar> _vars = [];
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _selectValues = {};
  final Set<String> _visiblePasswords = {};
  bool _loading = true;
  bool _saving = false;

  PluginSource get source => widget.source;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final manager = ref.read(pluginManagerProvider.notifier);
      final vars = await manager.getUserVars(source.id);
      if (!mounted) return;
      if (vars.isEmpty) {
        setState(() {
          _vars = const [];
          _loading = false;
        });
        return;
      }
      final values = await PluginUserVarStore().getValues(source.id);
      for (final v in vars) {
        final existing = values[v.name] ?? '';
        if (v.isSelect) {
          _selectValues[v.name] = existing.isNotEmpty
              ? existing
              : (v.defaultValue ??
                  (v.options.isNotEmpty ? v.options.first : ''));
        } else {
          _controllers[v.name] = TextEditingController(
              text: existing.isNotEmpty ? existing : (v.defaultValue ?? ''));
        }
      }
      if (!mounted) return;
      setState(() {
        _vars = vars;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _vars = const [];
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    for (final v in _vars) {
      if (!v.required) continue;
      final value = v.isSelect
          ? (_selectValues[v.name] ?? '')
          : (_controllers[v.name]?.text.trim() ?? '');
      if (value.isEmpty) {
        showXianYuToast(context, tr('「{name}」为必填项', {'name': v.title ?? v.name}));
        return;
      }
    }
    setState(() => _saving = true);
    final values = <String, String>{};
    for (final v in _vars) {
      values[v.name] = v.isSelect
          ? (_selectValues[v.name] ?? '')
          : (_controllers[v.name]?.text.trim() ?? '');
    }
    try {
      await ref
          .read(pluginManagerProvider.notifier)
          .saveUserVars(source.id, values);
      if (!mounted) return;
      showXianYuToast(context, tr('已保存用户变量，开始生效'));
    } catch (e) {
      if (!mounted) return;
      showXianYuToast(context, tr('保存失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final formatLabel = switch (source.format) {
      PluginFormat.lx => tr('落雪格式'),
      PluginFormat.anime => 'anime 格式',
      _ => tr('MusicFree 格式'),
    };

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 64,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              ),
              Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
            ],
          ),
        );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      source.format == PluginFormat.lx
                          ? Icons.music_note
                          : Icons.extension,
                      color: scheme.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(pluginDisplayName(source),
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(formatLabel,
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(height: 24),
              row(tr('版本'), source.version.isEmpty ? '—' : 'v${source.version}'),
              row(tr('作者'), source.author.isEmpty ? '—' : source.author),
              if (source.description.isNotEmpty) row(tr('描述'), source.description),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(tr('音源'),
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurfaceVariant)),
                    ),
                    Expanded(
                      child: source.sources.isEmpty
                          ? const Text('—')
                          : Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final s in source.sources)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: scheme.primary
                                          .withValues(alpha: 0.10),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(s,
                                        style: TextStyle(
                                            fontSize: 11.5,
                                            color: scheme.primary)),
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(tr('插件链接'),
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurfaceVariant)),
                    ),
                    Expanded(
                      child: source.sourceUrl.isEmpty
                          ? const Text('—', style: TextStyle(fontSize: 13))
                          : InkWell(
                              onTap: () async {
                                await Clipboard.setData(
                                    ClipboardData(text: source.sourceUrl));
                                if (context.mounted) {
                                  showXianYuToast(context, tr('插件链接已复制'));
                                }
                              },
                              borderRadius: BorderRadius.circular(4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(source.sourceUrl,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: scheme.primary)),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(Icons.copy_rounded,
                                      size: 13, color: scheme.primary),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              if (!_loading && _vars.isNotEmpty) ...[
                const Divider(height: 8),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.tune_outlined,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                      Expanded(
                      child: Text(tr('用户变量'),
                          style: TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600)),
                    ),
                    if (_saving)
                      const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      FilledButton(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 14),
                          textStyle: const TextStyle(fontSize: 13),
                        ),
                        onPressed: _save,
                        child:   Text(tr('保存')),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(tr('保存后插件将重新加载并应用新的变量值'),
                    style: TextStyle(fontSize: 12, color: scheme.outline)),
                const SizedBox(height: 12),
                for (final v in _vars) _buildField(context, v),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(BuildContext context, PluginUserVar v) {
    final scheme = Theme.of(context).colorScheme;
    final label = v.title ?? v.name;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              if (v.required)
                const Text(' *', style: TextStyle(color: Color(0xFFEC4141), fontSize: 13.5)),
              const Spacer(),
              Text(v.name,
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
            ],
          ),
          if (v.description != null && v.description!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(v.description!,
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 7),
          if (v.isSelect)
            DropdownButtonFormField<String>(
              initialValue: _selectValues[v.name],
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: v.placeholder,
              ),
              items: [
                for (final opt in v.options)
                  DropdownMenuItem(
                      value: opt,
                      child: Text(opt, style: const TextStyle(fontSize: 14))),
              ],
              onChanged: (val) {
                if (val != null) setState(() => _selectValues[v.name] = val);
              },
            )
          else
            TextField(
              controller: _controllers[v.name],
              obscureText: v.isPassword && !_visiblePasswords.contains(v.name),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: v.placeholder,
                suffixIcon: v.isPassword
                    ? IconButton(
                        icon: Icon(
                          _visiblePasswords.contains(v.name)
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 20,
                        ),
                        onPressed: () => setState(() {
                          _visiblePasswords.contains(v.name)
                              ? _visiblePasswords.remove(v.name)
                              : _visiblePasswords.add(v.name);
                        }),
                      )
                    : null,
              ),
              style: const TextStyle(fontSize: 14),
            ),
        ],
      ),
    );
  }
}
