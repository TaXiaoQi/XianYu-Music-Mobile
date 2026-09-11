import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../src/core/app_colors.dart';
import '../../src/rust/api.dart' as frb;
import '../../src/widgets/glass_appbar.dart';
import '../../src/i18n/i18n.dart';

enum _ConvertStatus { pending, running, done, failed }

class _ConvertResult {
  final String fileName;
  final String inputPath;
  String? outputPath;
  _ConvertStatus status = _ConvertStatus.pending;
  String? error;
  double durationSecs = 0;

  _ConvertResult({required this.fileName, required this.inputPath});
}

class AudioConvertPage extends ConsumerStatefulWidget {
  const AudioConvertPage({super.key});

  @override
  ConsumerState<AudioConvertPage> createState() => _AudioConvertPageState();
}

class _AudioConvertPageState extends ConsumerState<AudioConvertPage> {
  final List<_ConvertResult> _results = [];
  bool _busy = false;
  String _targetFormat = 'mp3';
  final List<String> _formatOptions = ['mp3', 'wav', 'flac'];
  String? _outDir;

  @override
  void initState() {
    super.initState();
    _initOutDir();
  }

  Future<void> _initOutDir() async {
    final dir = await getTemporaryDirectory();
    setState(() => _outDir = '${dir.path}/audio_convert_output');
  }

  Future<void> _pickAndConvert() async {
    if (_busy) return;
    if (_outDir == null) {
      await _initOutDir();
      if (_outDir == null) return;
    }

    final files = await FilePicker.pickFiles(type: FileType.audio, allowMultiple: true);
    if (files.isEmpty) return;

    final dir = await getTemporaryDirectory();
    final items = <_ConvertResult>[];
    for (final f in files) {
      String? path = f.path;
      if (path == null || path.isEmpty || !File(path).existsSync()) {
        final bytes = await f.readAsBytes();
        if (bytes.isEmpty) continue;
        final safeName = f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final tmp = File('${dir.path}/$safeName');
        await tmp.writeAsBytes(bytes);
        path = tmp.path;
      }
      items.add(_ConvertResult(
        fileName: f.name.isNotEmpty ? f.name : path.split(RegExp(r'[\\/]')).last,
        inputPath: path,
      ));
    }
    if (items.isEmpty) return;

    setState(() {
      _results
        ..clear()
        ..addAll(items);
      _busy = true;
    });

    try {
      final json = await frb.convertAudioBatch(
        inputPaths: items.map((e) => e.inputPath).toList(),
        outDir: _outDir!,
        optionsJson: jsonEncode({'targetFormat': _targetFormat}),
      );
      final list = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < items.length && i < list.length; i++) {
        final r = list[i];
        final item = items[i];
        if (r['success'] == true) {
          item.status = _ConvertStatus.done;
          item.outputPath = r['outputPath'] as String?;
          item.durationSecs = (r['durationSecs'] as num?)?.toDouble() ?? 0;
        } else {
          item.status = _ConvertStatus.failed;
          item.error = r['error'] as String?;
        }
      }
    } catch (e) {
      for (final item in items) {
        item.status = _ConvertStatus.failed;
        item.error = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      }
    }

    if (mounted) setState(() => _busy = false);
  }

  Future<void> _share(_ConvertResult item) async {
    final path = item.outputPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: tr('已转换：{name}', {'name': item.fileName})),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: GlassTopBar.height(context)),
            child: RepaintBoundary(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                children: [
                  Container(
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
                            tr('选择音频文件批量转换格式。支持 WAV、FLAC、MP3 输入；输出可选 MP3 (CBR 192kbps)、WAV (PCM int16)、FLAC (无损)。'),
                            style: TextStyle(
                                fontSize: 12.5, color: scheme.onSurfaceVariant,
                                height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(tr('输出格式'),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _formatOptions.map((fmt) {
                            final selected = _targetFormat == fmt;
                            return ChoiceChip(
                              label: Text(fmt.toUpperCase()),
                              selected: selected,
                              onSelected: (_) => setState(() => _targetFormat = fmt),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _pickAndConvert,
                          icon: _busy
                              ? const SizedBox(
                                  width: 16, height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.folder_open, size: 18),
                          label: Text(_busy ? tr('转换中…') : tr('选择文件并转换')),
                        ),
                      ),
                    ],
                  ),
                  if (_results.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildSummary(scheme),
                    const SizedBox(height: 10),
                    for (final item in _results) _buildResultCard(scheme, item),
                  ],
                ],
              ),
            ),
          ),
          Positioned(
            top: 0, left: 0, right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(tr('音频格式转换')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(ColorScheme scheme) {
    final ok = _results.where((r) => r.status == _ConvertStatus.done).length;
    final fail = _results.where((r) => r.status == _ConvertStatus.failed).length;
    return Text(
      tr('共 {total} 个文件：成功 {ok}', {'total': _results.length, 'ok': ok}) +
      (fail > 0 ? tr('，失败 {fail}', {'fail': fail}) : ''),
      style: TextStyle(
          fontSize: 12.5, color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
    );
  }

  Widget _buildResultCard(ColorScheme scheme, _ConvertResult item) {
    final (icon, color, text) = switch (item.status) {
      _ConvertStatus.pending => (Icons.schedule, scheme.outline, tr('等待转换')),
      _ConvertStatus.running => (Icons.sync, scheme.primary, tr('转换中…')),
      _ConvertStatus.done => (
        Icons.check_circle, Colors.green.shade600,
        tr('转换成功（{secs}s）', {'secs': item.durationSecs.toStringAsFixed(1)}),
      ),
      _ConvertStatus.failed => (
        Icons.error_outline, scheme.error,
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
                child: Text(
                  item.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              if (item.status == _ConvertStatus.done)
                TextButton.icon(
                  onPressed: () => _share(item),
                  icon: const Icon(Icons.share_outlined, size: 17),
                  label: Text(tr('分享')),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 29, right: 8),
            child: item.status == _ConvertStatus.done && item.outputPath != null
                ? Text(
                    item.outputPath!.split(RegExp(r'[\\/]')).last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: scheme.outline),
                  )
                : Text(
                    text,
                    style: TextStyle(fontSize: 11.5, color: color),
                  ),
          ),
        ],
      ),
    );
  }
}
