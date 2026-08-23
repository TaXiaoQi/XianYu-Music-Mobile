import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/player/player_provider.dart';
import '../../src/recognize/recognize_service.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/online_cover.dart';

/// 听歌识曲页：麦克风采集 10 秒 → 酷狗指纹识别 → 结果列表。
class RecognizePage extends ConsumerStatefulWidget {
  const RecognizePage({super.key});

  @override
  ConsumerState<RecognizePage> createState() => _RecognizePageState();
}

enum _Phase { idle, recording, recognizing, done }

class _RecognizePageState extends ConsumerState<RecognizePage>
    with SingleTickerProviderStateMixin {
  final RecognizeService _service = RecognizeService();
  _Phase _phase = _Phase.idle;
  double _progress = 0;
  List<RecognizeMatch> _matches = const [];
  String? _error;

  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    _service.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_phase == _Phase.recording || _phase == _Phase.recognizing) return;
    setState(() {
      _phase = _Phase.recording;
      _progress = 0;
      _error = null;
      _matches = const [];
    });
    try {
      final matches = await _service.recordAndRecognize(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onRecorded: () {
          if (mounted) setState(() => _phase = _Phase.recognizing);
        },
      );
      if (!mounted) return;
      setState(() {
        _matches = matches;
        _phase = _Phase.done;
        if (matches.isEmpty && _error == null) {
          _error = '没有识别到匹配的歌曲，请靠近音源重试';
        }
      });
    } on RecognizeException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _error = '识别失败：$e';
      });
    }
  }

  Future<void> _cancel() async {
    await _service.cancel();
    // recordAndRecognize 会以「识别已取消」异常返回，由 _start 的 catch 处理状态
  }

  /// 用 LX 协议播放识别结果（需要已安装支持 kg 音源的 LX 插件）。
  Future<void> _play(RecognizeMatch m) async {
    final musicInfo = <String, dynamic>{
      'name': m.name,
      'singer': m.singer,
      'albumName': m.albumName,
      'songmid': m.songmid,
      'source': 'kg',
      'interval': m.interval,
      'img': m.img,
      'hash': m.hash,
      'types': [
        for (final e in m.types.entries) {'type': e.key, 'size': '', 'hash': (e.value as Map)['hash']},
      ],
      '_types': m.types,
    };
    final item = QueueItem(
      path: 'lx://kg/${m.songmid}',
      title: m.name,
      artist: m.singer,
      album: m.albumName,
      durationMs: 0,
      onlineSongJson: jsonEncode(musicInfo),
      onlineQuality: _bestQuality(m),
      coverUrl: m.img,
      source: 'kg',
    );
    await ref.read(playerProvider.notifier).playQueue([item]);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在解析播放链接…'), duration: Duration(seconds: 1)),
      );
    }
  }

  String _bestQuality(RecognizeMatch m) {
    for (final q in ['flac', '320k', '128k']) {
      if (m.types.containsKey(q)) return q;
    }
    return '320k';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final player = ref.watch(playerProvider);
    final hasSong = player.current != null;

    return Scaffold(
      appBar: AppBar(title: const Text('听歌识曲')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            children: [
              _buildMicSection(scheme),
              if (_error != null && _matches.isEmpty) ...[
                const SizedBox(height: 20),
                Center(
                  child: Text(_error!,
                      style:
                          TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                ),
              ],
              if (_matches.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text('识别结果（${_matches.length}）',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                for (final (i, m) in _matches.indexed)
                  _MatchCard(match: m, rank: i + 1, onPlay: () => _play(m)),
              ],
            ],
          ),
          if (hasSong)
            Positioned(
              left: 14,
              right: 14,
              bottom: MediaQuery.of(context).padding.bottom + 12,
              child: const MiniPlayerBar(),
            ),
        ],
      ),
    );
  }

  Widget _buildMicSection(ColorScheme scheme) {
    final active =
        _phase == _Phase.recording || _phase == _Phase.recognizing;
    final statusText = switch (_phase) {
      _Phase.recording => '正在聆听 ${(RecognizeService.maxSeconds * _progress).round()}s / ${RecognizeService.maxSeconds}s',
      _Phase.recognizing => '正在识别…',
      _Phase.done => _matches.isEmpty ? '未识别到结果' : '识别完成',
      _Phase.idle => '点击按钮，靠近音源开始识别',
    };

    return Column(
      children: [
        const SizedBox(height: 24),
        SizedBox(
          width: 132,
          height: 132,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 进度环
              if (active)
                SizedBox(
                  width: 132,
                  height: 132,
                  child: CircularProgressIndicator(
                    value: _phase == _Phase.recording ? _progress : null,
                    strokeWidth: 3,
                    color: scheme.primary.withValues(alpha: 0.35),
                  ),
                ),
              // 脉冲光环
              if (active)
                ScaleTransition(
                  scale: Tween(begin: 0.92, end: 1.06).animate(
                      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
                  child: Container(
                    width: 116,
                    height: 116,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary.withValues(alpha: 0.10),
                    ),
                  ),
                ),
              Material(
                color: scheme.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: active ? _cancel : _start,
                  child: SizedBox(
                    width: 92,
                    height: 92,
                    child: Icon(
                      active
                          ? Icons.stop_rounded
                          : Icons.graphic_eq_rounded,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(statusText,
            style: TextStyle(
                fontSize: 14,
                color: active ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
        const SizedBox(height: 6),
        Text(
          active ? '点击停止' : '识别外放中的音乐，需安装支持酷狗音源的插件后播放',
          style: TextStyle(fontSize: 11.5, color: scheme.outline),
        ),
      ],
    );
  }
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.match, required this.rank, required this.onPlay});
  final RecognizeMatch match;
  final int rank;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final confidencePercent = (match.confidence * 100).round();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: OnlineCover(
            url: match.img,
            size: 52,
          ),
        ),
        title: Text(
          match.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              '${match.singer} · ${match.albumName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                Text('相似度 $confidencePercent%',
                    style: TextStyle(
                        fontSize: 11,
                        color: confidencePercent >= 80
                            ? scheme.primary
                            : scheme.outline)),
                const SizedBox(width: 8),
                if (match.interval != '00:00')
                  Text(match.interval,
                      style:
                          TextStyle(fontSize: 11, color: scheme.outline)),
              ],
            ),
          ],
        ),
        trailing: IconButton(
          icon: Icon(Icons.play_circle_fill, size: 34, color: scheme.primary),
          onPressed: onPlay,
        ),
      ),
    );
  }
}
