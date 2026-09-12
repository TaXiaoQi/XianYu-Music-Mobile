import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../src/core/app_colors.dart';
import '../../src/i18n/i18n.dart';
import '../../src/widgets/glass_appbar.dart';

enum _OutMode {
  // 原格式无损剪切（-c copy，最快，保留封面/歌词/元数据）
  original,
  // 指定格式重编码剪切
  recode,
}

class AudioTrimPage extends ConsumerStatefulWidget {
  const AudioTrimPage({super.key});
  @override
  ConsumerState<AudioTrimPage> createState() => _AudioTrimPageState();
}

class _AudioTrimPageState extends ConsumerState<AudioTrimPage> {
  String? _filePath;
  String? _originalDir; // 选文件时真正的原目录
  String _fileName = '';
  double _duration = 0; // 秒
  bool _probing = false;
  bool _trimming = false;

  double _start = 0;
  double _end = 0;

  // 试听
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  bool _isLoading = false;
  double _playProgress = 0; // 当前播放位置
  double _playBuffered = 0;
  double _playStartOffset = 0; // 试听从哪里开始（_start）
  bool _previewRange = true; // true = 试听 [_start, _end]，false = 全文件

  _OutMode _mode = _OutMode.original;
  String _recodeFmt = 'mp3'; // 与 audio_convert 保持一致的集合
  bool _keepCover = true;
  bool _keepLyrics = true;

  String? _outPath;
  String? _error;

  final _controllerStart = TextEditingController();
  final _controllerEnd = TextEditingController();

  static const _RECODE_FORMATS = ['mp3', 'aac', 'm4a', 'wav', 'flac', 'ogg', 'opus', 'wma'];

  @override
  void dispose() {
    _player.stop();
    _player.dispose();
    _controllerStart.dispose();
    _controllerEnd.dispose();
    super.dispose();
  }

  // ===== 试听 =====

  Future<void> _startPreview({bool fromStartPoint = true}) async {
    if (_filePath == null || _duration <= 0) return;
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _playStartOffset = fromStartPoint ? _start : 0;
    });

    try {
      await _player.setFilePath(_filePath!);
      await _player.seek(Duration(milliseconds: (_playStartOffset * 1000).round()));
      // 监听播放位置，到 _end 自动停
      _player.positionStream.listen((pos) {
        final cur = pos.inMilliseconds / 1000.0;
        final max = _previewRange ? _end : _duration;
        if (cur >= max) {
          _player.stop();
          return;
        }
        if (mounted) setState(() => _playProgress = cur);
      });
      _player.playingStream.listen((playing) {
        if (mounted) setState(() => _isPlaying = playing);
      });
      await _player.play();
    } catch (_) {
      // ignore
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _togglePreview() async {
    if (_isPlaying) {
      await _player.pause();
    } else {
      if (_player.sequence != null) {
        // 已经加载过，直接从当前位置或 start 开始
        final curMs = _player.position.inMilliseconds;
        final startMs = (_playStartOffset * 1000).round();
        final maxMs =
            (_previewRange ? _end : _duration).round() * 1000;
        if (curMs >= maxMs - 100) {
          // 已经播完了，重头来
          await _player.seek(Duration(milliseconds: startMs));
        } else if (curMs < startMs - 50) {
          await _player.seek(Duration(milliseconds: startMs));
        }
        await _player.play();
      } else {
        await _startPreview(fromStartPoint: _previewRange);
      }
    }
  }

  Future<void> _stopPreview() async {
    await _player.stop();
    if (mounted) setState(() => _playProgress = 0);
  }

  Future<void> _seekPreview(double secs) async {
    await _player.seek(Duration(milliseconds: (secs * 1000).round()));
    if (mounted) setState(() => _playProgress = secs);
  }

  // ===== 文件选择 + 时长探测 =====

  Future<void> _pickFile() async {
    if (_trimming || _probing) return;
    final files = await FilePicker.pickFiles(
      type: FileType.audio,
      allowMultiple: false,
    );
    if (files.isEmpty) return;
    final f = files.single;

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

    String? path = f.path;
    String originalDir;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      originalDir = Directory(path).parent.path;
    } else {
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return;
      final safe = f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final tmp = File('${tmpDir.path}/$safe');
      await tmp.writeAsBytes(bytes);
      path = tmp.path;
      originalDir = fallbackDir;
    }
    setState(() {
      _filePath = path;
      _originalDir = originalDir;
      _fileName = f.name.isNotEmpty
          ? f.name
          : path!.split(RegExp(r'[\\/]')).last;
      _duration = 0;
      _start = 0;
      _end = 0;
      _outPath = null;
      _error = null;
      _probing = true;
    });
    final d = await _probeDuration(path);
    if (!mounted) return;
    setState(() {
      _duration = d;
      _end = d;
      _controllerStart.text = _fmtSecs(0);
      _controllerEnd.text = _fmtSecs(d);
      _probing = false;
    });
  }

  Future<double> _probeDuration(String path) async {
    try {
      final session = await FFprobeKit.execute(
        '-v error -show_entries format=duration '
        '-of default=nw=1:nk=1 "$path"',
      );
      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc)) {
        final out = await session.getOutput();
        final v = double.tryParse((out ?? '').trim());
        if (v != null && v > 0) return v;
      }
    } catch (_) {}
    // fallback: 简单估算，让界面不至于空
    return 0;
  }

  // ===== 起止点 =====

  void _onStartSlider(double v) {
    setState(() {
      _start = v.clamp(0.0, _end - 0.1);
      _controllerStart.text = _fmtSecs(_start);
    });
  }

  void _onEndSlider(double v) {
    setState(() {
      _end = v.clamp(_start + 0.1, _duration);
      _controllerEnd.text = _fmtSecs(_end);
    });
  }

  void _onStartFieldSubmit() {
    final v = _parseSecs(_controllerStart.text);
    if (v == null) {
      _controllerStart.text = _fmtSecs(_start);
      return;
    }
    _onStartSlider(v);
  }

  void _onEndFieldSubmit() {
    final v = _parseSecs(_controllerEnd.text);
    if (v == null) {
      _controllerEnd.text = _fmtSecs(_end);
      return;
    }
    _onEndSlider(v);
  }

  // ===== 导出 =====

  Future<void> _trim() async {
    if (_trimming || _filePath == null || _duration <= 0) return;
    final outDir = await _pickOutDir();
    if (outDir == null) return;

    setState(() {
      _trimming = true;
      _outPath = null;
      _error = null;
    });

    final base = _fileName.contains('.')
        ? _fileName.substring(0, _fileName.lastIndexOf('.'))
        : _fileName;
    final safeBase = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final dur = (_end - _start).toStringAsFixed(3);

    final String outPath;
    final String cmd;

    if (_mode == _OutMode.original) {
      // 无损 -c copy，输出保持原扩展名
      final ext = _fileName.contains('.')
          ? _fileName.substring(_fileName.lastIndexOf('.') + 1)
          : 'audio';
      outPath = '$outDir${Platform.pathSeparator}${safeBase}_trim.$ext';

      final buf = StringBuffer('-y');
      buf.write(' -ss ${_start.toStringAsFixed(3)}');
      buf.write(' -i "${_filePath}"');
      buf.write(' -t $dur');
      buf.write(' -c copy');
      buf.write(' -avoid_negative_ts make_zero');
      if (_keepLyrics) buf.write(' -map_metadata 0 -map_chapters 0');
      buf.write(' "$outPath"');
      cmd = buf.toString();
    } else {
      // 重编码
      outPath = '$outDir${Platform.pathSeparator}${safeBase}_trim.$_recodeFmt';

      // 复用音频转换页的编码器映射
      const encoders = {
        'mp3': ('libmp3lame', '-b:a 192k'),
        'aac': ('aac', '-b:a 192k'),
        'm4a': ('aac', '-b:a 192k'),
        'wav': ('pcm_s16le', ''),
        'flac': ('flac', ''),
        'ogg': ('libvorbis', '-b:a 192k'),
        'opus': ('libopus', '-b:a 128k'),
        'wma': ('wmav2', '-b:a 192k'),
      };
      final (enc, extra) = encoders[_recodeFmt]!;

      final buf = StringBuffer('-y');
      buf.write(' -ss ${_start.toStringAsFixed(3)}');
      buf.write(' -i "${_filePath}"');
      buf.write(' -t $dur');
      buf.write(' -c:a $enc');
      if (extra.isNotEmpty) buf.write(' $extra');
      if (_keepCover) buf.write(' -map 0:v? -c copy');
      if (_keepLyrics) buf.write(' -map_metadata 0 -map_chapters 0');
      buf.write(' "$outPath"');
      cmd = buf.toString();
    }

    try {
      final sw = Stopwatch()..start();
      final session = await FFmpegKit.execute(cmd);
      sw.stop();
      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc)) {
        setState(() => _outPath = outPath);
        if (mounted) _showSuccessDialog(context, outPath);
      } else {
        final logs = await session.getLogs();
        final err = logs.isNotEmpty ? logs.last.getMessage() : '';
        setState(() {
          _error = err.isEmpty ? 'ffmpeg 返回码 ${rc?.getValue()}' : err;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      });
    }

    if (mounted) setState(() => _trimming = false);
  }

  Future<String?> _pickOutDir() async {
    if (!mounted) return null;
    final defaultDir = _originalDir != null
        ? _originalDir!
        : (await getTemporaryDirectory()).path;

    String? choice;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('选择保存位置')),
        content: Text(tr('剪辑后的文件将保存在哪里？')),
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

  Future<void> _share() async {
    final p = _outPath;
    if (p == null || !File(p).existsSync()) return;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(p)],
      text: tr('已剪辑：{name}', {'name': _fileName}),
    ));
  }

  // ===== 格式化 =====

  static String _fmtSecs(double s) {
    if (s < 0) s = 0;
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final secs = (s % 60);
    final sec = secs.toStringAsFixed(1).padLeft(4, '0');
    return '$m:$sec';
  }

  static double? _parseSecs(String s) {
    try {
      final parts = s.trim().split(':');
      if (parts.length == 2) {
        final m = int.tryParse(parts[0]);
        final sec = double.tryParse(parts[1]);
        if (m != null && sec != null) return m * 60 + sec;
      }
      return double.tryParse(s.trim());
    } catch (_) {
      return null;
    }
  }

  // ===== UI =====

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
                _buildFileCard(scheme),
                if (_filePath != null) ...[
                  const SizedBox(height: 12),
                  _buildRangeCard(scheme),
                  const SizedBox(height: 12),
                  _buildPreviewCard(scheme),
                  const SizedBox(height: 12),
                  _buildOutputCard(scheme),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  _buildErrorCard(scheme),
                ],
                if (_outPath != null) ...[
                  const SizedBox(height: 12),
                  _buildResultCard(scheme),
                ],
              ],
            ),
          ),
          if (_filePath != null && _duration > 0)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: SafeArea(
                child: FilledButton.icon(
                  onPressed: _trimming ? null : _trim,
                  icon: _trimming
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.content_cut, size: 18),
                  label: Text(_trimming
                      ? tr('剪辑中…')
                      : tr('导出剪辑 → {dur}s',
                          {'dur': (_end - _start).toStringAsFixed(1)})),
                ),
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(tr('音频剪辑')),
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
          Icon(Icons.content_cut, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tr('选择一个音频文件，拖选起止点，导出剪辑片段。支持无损剪切（原格式）或重编码为 MP3 / WAV / FLAC 等。'),
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

  Widget _buildFileCard(ColorScheme scheme) {
    if (_filePath == null) {
      return OutlinedButton.icon(
        onPressed: _trimming || _probing ? null : _pickFile,
        icon: const Icon(Icons.audiotrack, size: 18),
        label: Text(tr('选择音频文件')),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.music_note, size: 22, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  _probing
                      ? tr('探测时长中…')
                      : _duration > 0
                          ? tr('总时长 {t}',
                              {'t': _fmtSecs(_duration)})
                          : tr('探测失败'),
                  style: TextStyle(fontSize: 11.5, color: scheme.outline),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _trimming || _probing ? null : _pickFile,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(tr('换一个')),
          ),
        ],
      ),
    );
  }

  Widget _buildRangeCard(ColorScheme scheme) {
    final totalSecs = _fmtSecs(_duration);
    final selectedSecs = _fmtSecs(_end - _start);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(tr('选取区间'),
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(tr('总长 {t} / 选区 {s}', {'t': totalSecs, 's': selectedSecs}),
                  style: TextStyle(fontSize: 11.5, color: scheme.outline)),
            ],
          ),
          const SizedBox(height: 14),
          _labeledSlider(
            scheme: scheme,
            label: tr('开始'),
            value: _start,
            max: _duration,
            controller: _controllerStart,
            onChanged: _onStartSlider,
            onFieldSubmit: _onStartFieldSubmit,
          ),
          const SizedBox(height: 10),
          _labeledSlider(
            scheme: scheme,
            label: tr('结束'),
            value: _end,
            max: _duration,
            controller: _controllerEnd,
            onChanged: _onEndSlider,
            onFieldSubmit: _onEndFieldSubmit,
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(tr('0'),
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
              Text(tr('{dur}s 选区', {'dur': selectedSecs}),
                  style: TextStyle(fontSize: 11.5, color: scheme.primary)),
              Text(tr('{d}', {'d': totalSecs}),
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _labeledSlider({
    required ColorScheme scheme,
    required String label,
    required double value,
    required double max,
    required TextEditingController controller,
    required ValueChanged<double> onChanged,
    required VoidCallback onFieldSubmit,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 32,
          child: Text(label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(0.0, max),
            min: 0,
            max: max > 0 ? max : 1,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 72,
          height: 32,
          child: TextField(
            controller: controller,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.zero,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: scheme.outline),
              ),
            ),
            onSubmitted: (_) => onFieldSubmit(),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewCard(ColorScheme scheme) {
    final previewTotal = _previewRange ? (_end - _start) : _duration;
    final previewPos = _previewRange
        ? (_playProgress - _playStartOffset).clamp(0.0, previewTotal)
        : _playProgress;
    final running = _isPlaying || _isLoading;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.play_circle_outline, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(tr('试听'),
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
              const Spacer(),
              SegmentedButton<bool>(
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: [
                  ButtonSegment(
                    value: true,
                    label: Text(tr('选区'), style: const TextStyle(fontSize: 11)),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text(tr('全曲'), style: const TextStyle(fontSize: 11)),
                  ),
                ],
                selected: {_previewRange},
                onSelectionChanged: running
                    ? null
                    : (sel) {
                        _stopPreview();
                        setState(() => _previewRange = sel.first);
                      },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton.filled(
                onPressed: _togglePreview,
                icon: _isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(_isPlaying ? Icons.pause : Icons.play_arrow, size: 20),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  children: [
                    Slider(
                      value: previewPos.clamp(0.0, previewTotal),
                      min: 0,
                      max: previewTotal > 0 ? previewTotal : 1,
                      onChanged: running
                          ? _seekPreview
                          : null,
                    ),
                    Row(
                      children: [
                        Text(_fmtSecs(_previewRange ? _playStartOffset + previewPos : previewPos),
                            style: TextStyle(fontSize: 10.5, color: scheme.outline)),
                        const Spacer(),
                        Text('/ ${_fmtSecs(_previewRange ? _end : _duration)}',
                            style: TextStyle(fontSize: 10.5, color: scheme.outline)),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _stopPreview,
                icon: Icon(Icons.stop, size: 18, color: scheme.outline),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOutputCard(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.settings_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(tr('输出选项'),
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          _modeRow(scheme),
          if (_mode == _OutMode.recode) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _RECODE_FORMATS.map((f) {
                final selected = _recodeFmt == f;
                return ChoiceChip(
                  label: Text(f.toUpperCase()),
                  selected: selected,
                  onSelected: (_) => setState(() => _recodeFmt = f),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 4),
          SwitchListTile.adaptive(
            dense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            secondary: Icon(Icons.image_outlined, size: 18, color: scheme.primary),
            title: Text(tr('保留内置封面'),
                style: const TextStyle(fontSize: 13)),
            value: _keepCover,
            onChanged: _trimming ? null : (v) => setState(() => _keepCover = v),
          ),
          SwitchListTile.adaptive(
            dense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            secondary: Icon(Icons.subtitles_outlined, size: 18, color: scheme.primary),
            title: Text(tr('保留内置歌词 / 元数据'),
                style: const TextStyle(fontSize: 13)),
            value: _keepLyrics,
            onChanged: _trimming ? null : (v) => setState(() => _keepLyrics = v),
          ),
        ],
      ),
    );
  }

  Widget _modeRow(ColorScheme scheme) {
    return Row(
      children: [
        Expanded(
          child: SegmentedButton<_OutMode>(
            segments: [
              ButtonSegment(
                value: _OutMode.original,
                label: Text(tr('原格式（无损）')),
                icon: const Icon(Icons.bolt, size: 16),
              ),
              ButtonSegment(
                value: _OutMode.recode,
                label: Text(tr('重编码')),
                icon: const Icon(Icons.autorenew, size: 16),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (sel) => setState(() => _mode = sel.first),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorCard(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr('失败：{e}', {'e': _error!}),
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, size: 20, color: Colors.green.shade700),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('剪辑完成'),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  _outPath!.split(RegExp(r'[\\/]')).last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: scheme.outline),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _share,
            icon: const Icon(Icons.share_outlined, size: 17),
            label: Text(tr('分享')),
          ),
        ],
      ),
    );
  }

  Future<void> _showSuccessDialog(BuildContext ctx, String outPath) async {
    await showDialog<void>(
      context: ctx,
      builder: (dctx) {
        return AlertDialog(
          icon: Icon(Icons.check_circle, color: Colors.green.shade700, size: 32),
          title: Text(tr('导出成功')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('文件已保存到：'),
                  style: TextStyle(color: Theme.of(dctx).colorScheme.outline)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(dctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  outPath,
                  style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(dctx);
                await _share();
              },
              child: Text(tr('分享')),
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
