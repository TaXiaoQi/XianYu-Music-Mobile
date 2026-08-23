import 'dart:async';
import 'dart:convert';

import 'package:record/record.dart';

import '../rust/api.dart' as frb;

/// 单条识别匹配结果（酷狗识曲返回，映射为可播放的歌曲信息）。
class RecognizeMatch {
  final String name;
  final String singer;
  final String albumName;
  final String? img;
  final String hash;
  final String songmid;
  final String interval;
  final double confidence;
  final Map<String, dynamic> types;

  const RecognizeMatch({
    required this.name,
    required this.singer,
    required this.albumName,
    this.img,
    required this.hash,
    required this.songmid,
    required this.interval,
    required this.confidence,
    required this.types,
  });
}

/// 听歌识曲服务：麦克风采集 8000Hz/16bit/单声道 PCM → Rust 酷狗指纹识别。
class RecognizeService {
  static const maxSeconds = 10;

  final AudioRecorder _recorder = AudioRecorder();
  bool _cancelled = false;
  Timer? _timer;
  StreamSubscription? _sub;

  /// 采集 10 秒麦克风音频并识别。
  ///
  /// [onProgress]：0~1 采集进度；[onRecorded]：采集完成、进入识别阶段。
  /// 用户取消时抛出「识别已取消」。
  Future<List<RecognizeMatch>> recordAndRecognize({
    void Function(double progress)? onProgress,
    void Function()? onRecorded,
  }) async {
    _cancelled = false;
    if (!await _recorder.hasPermission()) {
      throw const RecognizeException('需要麦克风权限，请在系统设置中授权');
    }

    // 采集 8000Hz/16bit/单声道 PCM，与 Rust 识别接口要求一致
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 8000,
      numChannels: 1,
    ));

    final chunks = <int>[];
    final completer = Completer<void>();
    final startedAt = DateTime.now();

    _sub = stream.listen((data) {
      chunks.addAll(data);
      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      onProgress?.call((elapsed / (maxSeconds * 1000)).clamp(0.0, 1.0));
    });

    _timer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      onProgress?.call((elapsed / (maxSeconds * 1000)).clamp(0.0, 1.0));
      if (elapsed >= maxSeconds * 1000) {
        completer.complete();
      }
    });

    try {
      await completer.future.timeout(const Duration(seconds: maxSeconds + 2));
    } on TimeoutException {
      // 采集异常超时，直接用已采集数据
    } finally {
      _timer?.cancel();
      _timer = null;
    }
    await _sub?.cancel();
    _sub = null;
    await _recorder.stop();

    if (_cancelled) throw const RecognizeException('识别已取消');

    onRecorded?.call();
    if (chunks.isEmpty) {
      throw const RecognizeException('未采集到音频，请靠近音源重试');
    }

    // Rust 识别（酷狗指纹接口）
    final responseJson = await frb.recognizeWithPcm(pcm: chunks);
    final response = jsonDecode(responseJson) as Map<String, dynamic>;
    final status = (response['status'] as num?)?.toInt() ?? 0;
    if (status != 200) {
      throw RecognizeException('识别请求失败 (HTTP $status)');
    }
    return _parseResponse(response['body'] as String? ?? '');
  }

  /// 取消识别：停止采集并通知 Rust 取消进行中的请求。
  Future<void> cancel() async {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stop();
    } catch (_) {
      // 未在录音时忽略
    }
    try {
      await frb.cancelRecognizeSystemAudio();
    } catch (_) {
      // 忽略
    }
  }

  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _recorder.dispose();
  }

  List<RecognizeMatch> _parseResponse(String body) {
    final dynamic parsed;
    try {
      parsed = jsonDecode(body);
    } catch (_) {
      throw const RecognizeException('识别响应解析失败');
    }
    if (parsed is! Map) return const [];
    // 酷狗成功状态 status === 1；非 1 视为无匹配
    if ((parsed['status'] as num?)?.toInt() != 1) return const [];
    final list = parsed['data'];
    if (list is! List) return const [];

    final matches = <RecognizeMatch>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final match = _mapMatch(raw.cast<String, dynamic>());
      if (match != null) matches.add(match);
    }
    matches.sort((a, b) => b.confidence.compareTo(a.confidence));
    return matches;
  }

  RecognizeMatch? _mapMatch(Map<String, dynamic> item) {
    final distRaw = double.tryParse(item['dist']?.toString() ?? '0') ?? 0;
    final dist = distRaw.clamp(0.0, 1.0);
    final name = _pickString(
        [item['songname'], item['filename'], item['name'], '未知歌曲']);
    final singer = _pickString(
        [item['singername'], item['author_name'], item['singer'], '未知歌手']);
    if (name == '未知歌曲' && singer == '未知歌手') return null;

    final albumRecord = (item['album'] is List && (item['album'] as List).isNotEmpty)
        ? (item['album'] as List).first
        : null;
    final albumMap = albumRecord is Map ? albumRecord.cast<String, dynamic>() : <String, dynamic>{};
    final albumName = _pickString([
      albumMap['albumname'],
      item['album_name'],
      item['albumname'],
      '未知专辑',
    ]);

    final hash = _pickString([
      item['hash'],
      item['hash_128'],
      item['FileHash'],
      item['hash_320'],
      item['hash_flac'],
    ]);
    final songmid = _pickString([
      item['album_audio_id']?.toString(),
      item['mixsongid']?.toString(),
      item['audio_id']?.toString(),
      item['songid']?.toString(),
      hash,
    ]);

    final types = <String, dynamic>{};
    if (hash.isNotEmpty) types['128k'] = {'size': '', 'hash': hash};
    if (item['hash_320'] is String && (item['hash_320'] as String).isNotEmpty) {
      types['320k'] = {'size': '', 'hash': item['hash_320']};
    }
    if (item['hash_flac'] is String && (item['hash_flac'] as String).isNotEmpty) {
      types['flac'] = {'size': '', 'hash': item['hash_flac']};
    }

    final durationSec = _pickDurationSec(item);
    return RecognizeMatch(
      name: name,
      singer: singer,
      albumName: albumName,
      img: _formatCover(item, albumMap),
      hash: hash,
      songmid: songmid,
      interval: _formatInterval(durationSec),
      confidence: 1 - dist,
      types: types,
    );
  }

  String _pickString(List<dynamic> values) {
    for (final v in values) {
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return '';
  }

  int _pickDurationSec(Map<String, dynamic> item) {
    for (final key in ['timelength', 'timelength_128', 'timelength_320', 'duration']) {
      final v = item[key];
      if (v == null) continue;
      final ms = int.tryParse(v.toString()) ?? 0;
      if (ms > 0) return ms > 1000 ? (ms / 1000).floor() : ms;
    }
    return 0;
  }

  String _formatInterval(int seconds) {
    if (seconds <= 0) return '00:00';
    final m = (seconds / 60).floor();
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// 复现桌面端 formatCoverUrl：替换 {size}、补全协议、统一 https、替换旧域名。
  String? _formatCover(Map<String, dynamic> item, Map<String, dynamic> albumMap) {
    final raw = _pickString([
      item['union_cover'],
      albumMap['sizable_cover'],
      item['album_sizable_cover'],
      item['cover'],
    ]);
    if (raw.isEmpty) return null;
    var url = raw.replaceAll('{size}', '400');
    if (url.startsWith('//')) url = 'https:$url';
    url = url.replaceAll('http://', 'https://');
    url = url.replaceAll('c1.kgimg.com', 'imge.kugou.com');
    return url;
  }
}

/// 识曲异常。
class RecognizeException implements Exception {
  final String message;
  const RecognizeException(this.message);

  @override
  String toString() => message;
}
