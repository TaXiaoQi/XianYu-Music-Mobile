import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../src/core/app_colors.dart';
import '../../src/i18n/i18n.dart';
import '../../src/rust/api.dart' as frb;
import '../../src/widgets/glass_appbar.dart';

class _Format {
  final String value;
  final String label;
  final bool lossless;
  const _Format({
    required this.value,
    required this.label,
    this.lossless = false,
  });
}

const _FORMATS = [
  _Format(value: 'mp3', label: 'MP3', lossless: false),
  _Format(value: 'wav', label: 'WAV', lossless: true),
  _Format(value: 'flac', label: 'FLAC', lossless: true),
];

enum _Status { pending, running, done, failed }

class _Item {
  final String name;
  final String input;
  final String originalDir;
  _Status status = _Status.pending;
  String? output;
  String? error;
  double secs = 0;
  _Item({required this.name, required this.input, required this.originalDir});
}

class AudioConvertPage extends ConsumerStatefulWidget {
  const AudioConvertPage({super.key});
  @override
  ConsumerState<AudioConvertPage> createState() => _AudioConvertPageState();
}

class _AudioConvertPageState extends ConsumerState<AudioConvertPage> {
  final List<_Item> _selected = [];
  final List<_Item> _results = [];
  bool _busy = false;
  String _format = 'mp3';
  bool _keepCover = true;
  bool _keepLyrics = true;
  int _sampleRate = 0;

  static const _SAMPLE_RATES = [
    (0, '保留原采样率'),
    (22050, '22050 Hz'),
    (32000, '32000 Hz'),
    (44100, '44100 Hz'),
    (48000, '48000 Hz'),
    (96000, '96000 Hz'),
    (192000, '192000 Hz'),
  ];

  _Format get _fmt =>
      _FORMATS.firstWhere((f) => f.value == _format, orElse: () => _FORMATS.first);

  Future<void> _pickFiles() async {
    if (_busy) return;
    final files = await FilePicker.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (files.isEmpty) return;

    final tmpDir = await getTemporaryDirectory();
    String? fallbackDir;
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final m = RegExp(r'(/storage/emulated/\d+)').firstMatch(ext.path);
        if (m != null) fallbackDir = '${m.group(1)}/Music';
      }
    } catch (_) {}
    fallbackDir ??= tmpDir.path;

    final items = <_Item>[];
    for (final f in files) {
      String? path = f.path;
      String originalDir;
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        originalDir = Directory(path).parent.path;
      } else {
        final bytes = await f.readAsBytes();
        if (bytes.isEmpty) continue;
        final safe = f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final tmp = File('${tmpDir.path}/$safe');
        await tmp.writeAsBytes(bytes);
        path = tmp.path;
        originalDir = fallbackDir;
      }
      items.add(_Item(
        name: f.name.isNotEmpty
            ? f.name
            : path.split(RegExp(r'[\\/]')).last,
        input: path,
        originalDir: originalDir,
      ));
    }
    if (items.isEmpty) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(items);
      _results.clear();
    });
  }

  Future<void> _start() async {
    if (_busy || _selected.isEmpty) return;
    final outDir = await _pickOutDir();
    if (outDir == null) return;

    setState(() {
      _results
        ..clear()
        ..addAll(_selected.map((e) => _Item(name: e.name, input: e.input, originalDir: e.originalDir)));
      _busy = true;
    });

    final fmt = _fmt;
    final options = jsonEncode({
      'targetFormat': fmt.value,
      'sampleRate': _sampleRate > 0 ? _sampleRate : null,
      'keepCover': _keepCover,
      'keepLyrics': _keepLyrics,
    });

    for (var i = 0; i < _results.length; i++) {
      final item = _results[i];
      item.status = _Status.running;
      if (mounted) setState(() {});

      final sw = Stopwatch()..start();
      try {
        final raw = await frb.convertAudioBatch(
          inputPaths: [item.input],
          outDir: outDir,
          optionsJson: options,
        );
        sw.stop();
        item.secs = sw.elapsedMilliseconds / 1000;
        final r = (jsonDecode(raw) as List).cast<Map<String, dynamic>>().first;
        if (r['success'] == true) {
          item.output = r['outputPath'] as String?;
          item.status = _Status.done;
        } else {
          item.status = _Status.failed;
          item.error = (r['error'] as String?) ?? tr('未知错误');
        }
      } catch (e) {
        sw.stop();
        item.secs = sw.elapsedMilliseconds / 1000;
        item.status = _Status.failed;
        item.error = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      }

      if (mounted) setState(() {});
    }

    if (mounted) {
      setState(() => _busy = false);
      final okCount = _results.where((r) => r.status == _Status.done).length;
      final failCount = _results.length - okCount;
      if (okCount > 0) _showBatchDoneDialog(context, okCount, failCount, _results);
    }
  }

  Future<String?> _pickOutDir() async {
    if (!mounted) return null;
    final defaultDir = _selected.isNotEmpty
        ? _selected.first.originalDir
        : (await getTemporaryDirectory()).path;

    String? choice;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('选择保存位置')),
        content: Text(tr('转换后的文件将保存在哪里？')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(tr('取消'))),
          TextButton(
            onPressed: () async {
              final d = await FilePicker.getDirectoryPath();
              if (d != null && mounted) {
                choice = d;
                Navigator.pop(ctx);
              }
            },
            child: Text(tr('自定义…')),
          ),
          FilledButton(
            onPressed: () {
              choice = defaultDir;
              Navigator.pop(ctx);
            },
            child: Text(tr('原文件夹')),
          ),
        ],
      ),
    );
    return choice;
  }

  Future<void> _share(_Item item) async {
    final p = item.output;
    if (p == null || p.isEmpty || !File(p).existsSync()) return;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(p)],
      text: tr('已转换：{name}', {'name': item.name}),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: GlassTopBar.height(context)),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              children: [
                _buildBanner(scheme),
                const SizedBox(height: 16),
                _buildFormatPicker(scheme),
                const SizedBox(height: 8),
                _buildSampleRatePicker(scheme),
                const SizedBox(height: 12),
                _buildMetadataOptions(scheme),
                const SizedBox(height: 16),
                _buildPickRow(),
                const SizedBox(height: 12),
                if (_selected.isNotEmpty) ...[
                  Text(
                    tr('已选 {count} 个文件', {'count': _selected.length}),
                    style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < _selected.length; i++)
                    _buildSelectedCard(scheme, _selected[i], i),
                ],
                if (_results.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _buildSummary(scheme),
                  const SizedBox(height: 8),
                  for (final item in _results) _buildResultCard(scheme, item),
                ],
                if (_selected.isEmpty && _results.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: Text(
                        tr('还没有选择文件'),
                        style: TextStyle(color: scheme.outline),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_selected.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: SafeArea(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _start,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow, size: 18),
                  label: Text(_busy
                      ? tr('转换中…')
                      : tr('开始转换 → {fmt} ({count})',
                          {'fmt': _fmt.label, 'count': _selected.length})),
                ),
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(tr('音频格式转换')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBanner(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.autorenew, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tr('选择音频文件批量转换格式。支持输出 MP3 / WAV / FLAC，可保留封面和内嵌歌词。'),
              style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                  height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormatPicker(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('输出格式'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _FORMATS.map((f) {
            final selected = _format == f.value;
            return ChoiceChip(
              label: Text('${f.label}${f.lossless ? ' ⭐' : ''}'),
              selected: selected,
              onSelected: (_) => setState(() => _format = f.value),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildSampleRatePicker(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('采样率'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: _SAMPLE_RATES.map((s) {
            final selected = _sampleRate == s.$1;
            return ChoiceChip(
              label: Text(s.$2),
              selected: selected,
              onSelected: _busy ? null : (_) => setState(() => _sampleRate = s.$1),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildMetadataOptions(ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile.adaptive(
            dense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            secondary: Icon(Icons.image_outlined,
                size: 20, color: scheme.primary),
            title: Text(tr('保留内置封面'),
                style: const TextStyle(fontSize: 13.5)),
            subtitle: Text(tr('复制专辑封面到输出文件'),
                style: TextStyle(fontSize: 11.5, color: scheme.outline)),
            value: _keepCover,
            onChanged: _busy
                ? null
                : (v) => setState(() => _keepCover = v),
          ),
          const Divider(height: 1, indent: 52),
          SwitchListTile.adaptive(
            dense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            secondary: Icon(Icons.subtitles_outlined,
                size: 20, color: scheme.primary),
            title: Text(tr('保留内置歌词'),
                style: const TextStyle(fontSize: 13.5)),
            subtitle: Text(tr('复制内嵌歌词和元数据'),
                style: TextStyle(fontSize: 11.5, color: scheme.outline)),
            value: _keepLyrics,
            onChanged: _busy
                ? null
                : (v) => setState(() => _keepLyrics = v),
          ),
        ],
      ),
    );
  }

  Widget _buildPickRow() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _pickFiles,
            icon: const Icon(Icons.add, size: 18),
            label: Text(tr('选择文件')),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectedCard(ColorScheme scheme, _Item item, int index) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.audiotrack, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5)),
          ),
          IconButton(
            iconSize: 18,
            onPressed: _busy ? null : () => setState(() => _selected.removeAt(index)),
            icon: const Icon(Icons.close),
            color: scheme.outline,
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(ColorScheme scheme) {
    final ok = _results.where((r) => r.status == _Status.done).length;
    final fail = _results.where((r) => r.status == _Status.failed).length;
    return Text(
      tr('共 {total} 个文件：成功 {ok}',
          {'total': _results.length, 'ok': ok}) +
      (fail > 0 ? tr('，失败 {fail}', {'fail': fail}) : ''),
      style: TextStyle(
          fontSize: 12.5,
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600),
    );
  }

  Widget _buildResultCard(ColorScheme scheme, _Item item) {
    final (icon, color, text) = switch (item.status) {
      _Status.pending =>
        (Icons.schedule, scheme.outline, tr('等待转换')),
      _Status.running => (
        Icons.sync,
        scheme.primary,
        tr('转换中…'),
      ),
      _Status.done => (
        Icons.check_circle,
        Colors.green.shade600,
        tr('转换成功（{secs}s）',
            {'secs': item.secs.toStringAsFixed(1)}),
      ),
      _Status.failed => (
        Icons.error_outline,
        scheme.error,
        tr('失败：{error}', {'error': item.error ?? tr('未知错误')}),
      ),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 19, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              if (item.status == _Status.done)
                TextButton.icon(
                  onPressed: () => _share(item),
                  icon: const Icon(Icons.share_outlined, size: 17),
                  label: Text(tr('分享')),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 29, right: 8),
            child: item.status == _Status.done && item.output != null
                ? Text(
                    item.output!.split(RegExp(r'[\\/]')).last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: scheme.outline),
                  )
                : Text(text, style: TextStyle(fontSize: 11.5, color: color)),
          ),
        ],
      ),
    );
  }

  Future<void> _showBatchDoneDialog(
      BuildContext ctx, int okCount, int failCount, List<_Item> results) async {
    final scheme = Theme.of(ctx).colorScheme;
    final ok = results.where((r) => r.status == _Status.done).toList();

    await showDialog<void>(
      context: ctx,
      builder: (dctx) {
        return AlertDialog(
          icon: Icon(Icons.check_circle,
              color: Colors.green.shade700, size: 32),
          title: Text(tr('转换完成')),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: ok.length.clamp(0, 5),
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (_, i) {
                final r = ok[i];
                return Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(r.output ?? '',
                          style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            if (ok.length > 1)
              TextButton.icon(
                onPressed: () async {
                  await _share(ok.first);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                icon: const Icon(Icons.share_outlined, size: 17),
                label: Text(tr('分享第一个')),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(dctx),
              child: Text(tr('完成')),
            ),
          ],
        );
      },
    );
  }
}
