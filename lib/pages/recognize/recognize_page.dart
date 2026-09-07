import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/db_path.dart';
import '../../src/library/library_provider.dart';
import '../../src/online/online_search_provider.dart';
import '../../src/plugin/plugin_backup_import.dart';
import '../../src/plugin/plugin_engine.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/recognize/recognize_service.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/add_to_playlist_sheet.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/bottom_play_bar_slot.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/i18n/i18n.dart';

/// 听歌识曲页（桌面端风格）：居中麦克风圆钮 + 脉冲/旋转 / 波形条，
/// 识别成功后展示匹配度、封面、收藏、加歌单与重新识别。
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

  bool get _active =>
      _phase == _Phase.recording || _phase == _Phase.recognizing;

  Future<void> _start() async {
    if (_active) return;
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
      if (matches.isNotEmpty) {
        HapticFeedback.mediumImpact();
      }
      setState(() {
        _matches = matches;
        _phase = _Phase.done;
        if (matches.isEmpty && _error == null) {
          _error = tr('没有识别到匹配的歌曲，请靠近音源重试');
        }
      });
    } on RecognizeException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        // 用户主动停止识别，不展示错误。
        if (e.message == tr('识别已取消')) {
          _error = null;
        } else {
          _error = e.message;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _error = tr('识别失败：{e}', {'e': e});
      });
    }
  }

  Future<void> _cancel() async {
    await _service.cancel();
    // recordAndRecognize 会以「识别已取消」异常返回，由 _start 的 catch 处理状态。
  }

  /// 把识别结果转成可播放/收藏/加歌单的队列项（LX 酷狗协议）。
  QueueItem _toQueueItem(RecognizeMatch m) {
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
        for (final e in m.types.entries)
          {'type': e.key, 'size': '', 'hash': (e.value as Map)['hash']},
      ],
      '_types': m.types,
    };
    return QueueItem(
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
  }

  String _bestQuality(RecognizeMatch m) {
    for (final q in ['flac', '320k', '128k']) {
      if (m.types.containsKey(q)) return q;
    }
    return '320k';
  }

  Future<void> _play(RecognizeMatch m) async {
    final notifier = ref.read(playerProvider.notifier);
    // 1) 本地曲库优先：识别结果命中本地文件时直接播放，无需任何在线解析。
    final local = await _findLocalMatch(m);
    if (local != null) {
      await ref.read(libraryProvider.notifier).playList([local], 0);
      if (mounted) {
        showXianYuToast(context, tr('已匹配本地歌曲'),
            duration: const Duration(seconds: 1));
      }
      return;
    }
    // 2) 在线兜底：落雪音源逐源搜索同名曲目，命中且直链可解析才播放。
    if (mounted) {
      showXianYuToast(context, tr('正在搜索可播放音源…'),
          duration: const Duration(seconds: 2));
    }
    final online = await _findOnlineMatch(m);
    QueueItem? toPlay = online;
    // 3) 最终兜底：原酷狗识别项，绑定酷狗插件后验证可播。
    toPlay ??= await _buildKgFallbackItem(m);
    if (toPlay == null) {
      if (mounted) {
        showXianYuToast(
          context,
          tr('无法播放：请安装支持该音源（酷狗等）的插件'),
          duration: const Duration(seconds: 2),
        );
      }
      return;
    }
    try {
      await notifier.playQueue([toPlay]);
    } catch (e) {
      if (mounted) {
        showXianYuToast(
          context,
          tr('播放失败：{e}', {'e': e.toString()}),
          duration: const Duration(seconds: 2),
        );
      }
      return;
    }
    if (mounted) {
      showXianYuToast(context, tr('正在解析播放链接…'),
          duration: const Duration(seconds: 1));
    }
  }

  /// 标题归一化（与播放器 _matchOnlineTitle 同口径）：去空格/标点/大小写。
  static String _normTitle(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\-_（）()【】\[\].、，,·/\\+&]'), '');

  /// 判断识别标题与候选标题是否匹配（归一化相等；长度≥3 允许互相包含）。
  static bool _titleMatches(String a, String b) {
    final na = _normTitle(a);
    final nb = _normTitle(b);
    if (na.isEmpty || nb.isEmpty) return false;
    if (na == nb) return true;
    if (na.length >= 3 && nb.length >= 3) {
      return na.contains(nb) || nb.contains(na);
    }
    return false;
  }

  /// 歌手归一化匹配：任一方向包含即命中（识别歌手名常含「/」多歌手）。
  static bool _artistMatches(String a, String b) {
    final na = _normTitle(a);
    final nb = _normTitle(b);
    if (na.isEmpty || nb.isEmpty) return false;
    return na.contains(nb) || nb.contains(na);
  }

  /// 在本地曲库中查找与识别结果同名的歌曲（歌手匹配者优先）。
  Future<Song?> _findLocalMatch(RecognizeMatch m) async {
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final json = await searchLibrarySongs(
          dbPath: dbPath, query: m.name, limit: BigInt.from(50));
      final list = (jsonDecode(json) as List)
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList();
      Song? titleOnly;
      for (final s in list) {
        if (!_titleMatches(m.name, s.title)) continue;
        if (_artistMatches(m.singer, s.artist)) return s;
        titleOnly ??= s;
      }
      return titleOnly;
    } catch (_) {
      return null;
    }
  }

  /// 酷狗识别项兜底：找一个酷狗插件，绑定 pluginId 后验证可播。
  Future<QueueItem?> _buildKgFallbackItem(RecognizeMatch m) async {
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final plugins = await engine.store.loadSources();
      final enabled = plugins.where((p) => p.enabled).toList();
      final plugin = findPluginForPlatform(
        platformLabel: 'kg',
        installedPlugins: enabled,
        format: PluginFormat.lx,
        allowCrossFormat: true,
      );
      if (plugin == null) return null;
      final musicInfo = <String, dynamic>{
        'name': m.name,
        'singer': m.singer,
        'albumName': m.albumName,
        'songmid': m.songmid,
        'source': 'kg',
        'interval': m.interval,
        'img': m.img,
        'hash': m.hash,
        '_types': m.types,
      };
      final isMusicFree = plugin.format == PluginFormat.musicfree;
      final songJson = <String, dynamic>{
        'pluginId': plugin.id,
        'format': isMusicFree ? 'musicfree' : 'lx',
        if (!isMusicFree) 'source': 'kg',
        'musicInfo': musicInfo,
      };
      for (final q in ['320k', '128k', 'flac']) {
        try {
          if (isMusicFree) {
            final r = await engine.getMusicFreeUrl(
              plugin, musicInfo, preferred: q, fallback: 'pause',
            ).timeout(const Duration(seconds: 4));
            if (r != null) {
              return _toQueueItem(m).copyWithOnlineSource(
                onlineSongJson: jsonEncode(songJson), source: 'kg',
              );
            }
          } else {
            final r = await engine.getMusicUrl(
              plugin, 'kg', musicInfo, q,
            ).timeout(const Duration(seconds: 4));
            if (r != null && r['url'] != null) {
              return _toQueueItem(m).copyWithOnlineSource(
                onlineSongJson: jsonEncode(songJson), source: 'kg',
              );
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
    return null;
  }

  /// 在落雪在线音源（酷我/网易云/酷狗/QQ/咪咕）中搜索识别结果，
  /// 返回首个标题命中（歌手匹配者优先）且**直链可解析**的队列项；全源失败返回 null。
  ///
  /// 直链解析完全依赖已安装插件。返回的队列项绑定具体 pluginId，走播放器的
  /// [_resolvePluginUrl] 路径，绕过 Rust 侧按音源 key 精确匹配（插件 sources
  /// 可能用「酷狗」「kugou」等别名）。
  Future<QueueItem?> _findOnlineMatch(RecognizeMatch m) async {
    final keyword = m.singer.trim().isEmpty
        ? m.name.trim()
        : '${m.name.trim()} ${m.singer.trim()}';
    if (keyword.isEmpty) return null;

    final engine = await ref.read(pluginEngineProvider.future);
    final plugins = await engine.store.loadSources();
    final enabled = plugins.where((p) => p.enabled).toList();
    if (enabled.isEmpty) return null;

    for (final src in kOnlineSources) {
      // 找一个能服务该音源的已启用插件（别名归一化匹配）。
      final plugin = findPluginForPlatform(
        platformLabel: src.id,
        installedPlugins: enabled,
        format: PluginFormat.lx,
        allowCrossFormat: true,
      );
      if (plugin == null) continue;
      try {
        final res = await lxSearch(source: src.id, keyword: keyword, limit: 10);
        final list = (jsonDecode(res) as List).cast<Map<String, dynamic>>();
        final matches = <Map<String, dynamic>>[];
        for (final raw in list) {
          final track = OnlineTrack.fromJson(raw);
          if (!_titleMatches(m.name, track.title)) continue;
          if (_artistMatches(m.singer, track.artist)) {
            matches.insert(0, raw);
          } else {
            matches.add(raw);
          }
        }
        // 每源最多验证前 3 个候选。
        for (final hit in matches.take(3)) {
          final item = await _buildPlayableItem(
            engine, plugin, src.id, hit,
          );
          if (item != null) return item;
        }
      } catch (_) {
        // 该源搜索失败，继续下一源。
      }
    }
    return null;
  }

  /// 用插件引擎验证候选可播，成功则返回绑定 pluginId 的队列项。
  Future<QueueItem?> _buildPlayableItem(
    PluginEngine engine,
    PluginSource plugin,
    String sourceKey,
    Map<String, dynamic> raw,
  ) async {
    final track = OnlineTrack.fromJson(raw);
    final isMusicFree = plugin.format == PluginFormat.musicfree;
    final songJson = <String, dynamic>{
      'pluginId': plugin.id,
      'format': isMusicFree ? 'musicfree' : 'lx',
      if (!isMusicFree) 'source': sourceKey,
      'musicInfo': raw,
    };
    final qualities = ['320k', '128k', 'flac'];
    for (final q in qualities) {
      try {
        if (isMusicFree) {
          final r = await engine.getMusicFreeUrl(
            plugin, raw, preferred: q, fallback: 'pause',
          ).timeout(const Duration(seconds: 4));
          if (r != null) {
            return _queueItemFromTrack(track, songJson, sourceKey);
          }
        } else {
          final r = await engine.getMusicUrl(
            plugin, sourceKey, raw, q,
          ).timeout(const Duration(seconds: 4));
          if (r != null && r['url'] != null) {
            return _queueItemFromTrack(track, songJson, sourceKey);
          }
        }
      } catch (_) {
        // 该档失败，继续下一档。
      }
    }
    return null;
  }

  QueueItem _queueItemFromTrack(
    OnlineTrack track,
    Map<String, dynamic> songJson,
    String sourceKey,
  ) => QueueItem(
        path: 'lx://$sourceKey/${track.songmid}',
        title: track.title,
        artist: track.artist,
        album: track.album,
        durationMs: track.durationSeconds * 1000,
        coverUrl: track.coverUrl,
        source: sourceKey,
        onlineSongJson: jsonEncode(songJson),
        onlineQuality: '320k',
      );

  void _toggleFavorite(RecognizeMatch m) {
    ref.read(favoritesProvider.notifier).toggle(_toQueueItem(m));
    showXianYuToast(
      context,
      ref.read(favoritesProvider).contains(_toQueueItem(m).path)
          ? tr('已收藏')
          : tr('已取消收藏'),
      duration: const Duration(seconds: 1),
    );
  }

  void _addToPlaylist(RecognizeMatch m) {
    final item = _toQueueItem(m);
    showAddToPlaylistSheet(context, ref, [importedSongFromQueueItem(item)]);
  }

  String get _statusText => switch (_phase) {
        _Phase.recording =>
          tr('正在聆听 {cur}s / {max}s', {'cur': (RecognizeService.maxSeconds * _progress).round(), 'max': RecognizeService.maxSeconds}),
        _Phase.recognizing => tr('识别中…'),
        _Phase.done => _matches.isEmpty ? tr('识别失败') : tr('识别到 {n} 首匹配', {'n': _matches.length}),
        _Phase.idle => tr('点击麦克风开始识别'),
      };

  @override
  Widget build(BuildContext context) {
    final success = _phase == _Phase.done && _matches.isNotEmpty;

    return Scaffold(
      // 底色与其他二级页统一：常规模式实色（覆盖/平滑转场不透底、离屏快照
      // 玻璃背板有内容可采样，不闪黑帧）；壁纸模式返回透明，由 AppPageBackground
      // 在页内烘焙壁纸底色（不透明卡片），行为与原先一致。
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: GlassTopBar.height(context)),
            child: Stack(
              children: [
                if (success)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 70),
                    child: _MatchListView(
                      matches: _matches,
                      onPlay: _play,
                      onFavorite: _toggleFavorite,
                      isFavorite: (m) =>
                          ref.read(favoritesProvider).contains(_toQueueItem(m).path),
                      onAddToPlaylist: _addToPlaylist,
                      onRestart: () => setState(() => _phase = _Phase.idle),
                      onStart: _start,
                    ),
                  )
                else
                  _MicView(
                    phase: _phase,
                    active: _active,
                    pulse: _pulse,
                    statusText: _statusText,
                    error: !success ? _error : null,
                    onTap: _active ? _cancel : _start,
                    onRestart: () => setState(() => _phase = _Phase.idle),
                  ),
                const Positioned(
                  left: 0, right: 0, bottom: 0,
                  child: BottomPlayBarSlot(),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0, left: 0, right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.mic, size: 18, color: const Color(0xFFEC4141)),
                  const SizedBox(width: 8),
                  Text(tr('听歌识曲'), style: TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 麦克风主视图 ====================

class _MicView extends StatelessWidget {
  const _MicView({
    required this.phase,
    required this.active,
    required this.pulse,
    required this.statusText,
    required this.error,
    required this.onTap,
    required this.onRestart,
  });

  final _Phase phase;
  final bool active;
  final AnimationController pulse;
  final String statusText;
  final String? error;
  final VoidCallback onTap;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = const Color(0xFFEC4141);
    final recognizing = phase == _Phase.recognizing;
    final failed = phase == _Phase.done && error != null && error!.isNotEmpty;

    return ListView(
      padding: EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        // —— 麦克风圆钮 ——
        SizedBox(
          height: 96,
          child: Center(
            child: SizedBox(
              width: 80,
              height: 80,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 脉冲环（录音中）
                  if (active && !recognizing)
                    ScaleTransition(
                      scale: Tween(begin: 0.92, end: 1.08).animate(CurvedAnimation(
                          parent: pulse, curve: Curves.easeInOut)),
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: primary.withValues(alpha: 0.18),
                        ),
                      ),
                    ),
                  Material(
                    color: active && !recognizing ? primary : primary.withValues(alpha: 0.10),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onTap,
                      child: SizedBox(
                        width: 64,
                        height: 64,
                        child: Icon(
                          recognizing
                              ? Icons.mic_off
                              : active
                                  ? Icons.mic
                                  : Icons.mic_none_rounded,
                          color: active && !recognizing ? Colors.white : primary,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 16),
        Text(
          statusText,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: active ? primary : scheme.onSurfaceVariant,
          ),
        ),

        // —— 波形条（录音中）——
        const SizedBox(height: 14),
        if (phase == _Phase.recording)
          const _Waveform(color: Color(0xFFEC4141))
        else
          Align(
            alignment: Alignment.center,
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outline.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

        // —— 错误提示 / 提示文案 ——
        const SizedBox(height: 16),
        if (failed && error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          )
        else if (failed)
          const SizedBox.shrink()
        else ...[
          Text(
            tr('识别外放中的音乐，请先播放音乐，再点击识别按钮'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: scheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            active ? tr('点击停止') : tr('播放优先匹配本地曲库，在线按可用音源解析'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
        ],

        // —— 失败后重新识别 ——
        if (failed && !active) ...[
          const SizedBox(height: 24),
          Center(
            child: _ReRecognizeButton(onTap: onRestart),
          ),
        ],
      ],
    );
  }
}

/// 波形条：7 根红色竖条，模拟桌面端录音动画。
class _Waveform extends StatefulWidget {
  const _Waveform({required this.color});

  final Color color;

  @override
  State<_Waveform> createState() => _WaveformState();
}

class _WaveformState extends State<_Waveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 850))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return SizedBox(
          height: 28,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 7; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 4,
                    height: 8 +
                        20 *
                            (0.5 +
                                0.5 *
                                    math.sin(2 * math.pi * (_c.value + i / 7))),
                    decoration: BoxDecoration(
                      color: widget.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ==================== 匹配结果列表 ====================

class _MatchListView extends ConsumerWidget {
  const _MatchListView({
    required this.matches,
    required this.onPlay,
    required this.onFavorite,
    required this.isFavorite,
    required this.onAddToPlaylist,
    required this.onRestart,
    required this.onStart,
  });

  final List<RecognizeMatch> matches;
  final void Function(RecognizeMatch) onPlay;
  final void Function(RecognizeMatch) onFavorite;
  final bool Function(RecognizeMatch) isFavorite;
  final void Function(RecognizeMatch) onAddToPlaylist;
  final VoidCallback onRestart;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        // 结果提示条
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: appCardColor(context),
          child: Text(
            tr('识别到 {n} 首匹配', {'n': matches.length}),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: matches.length + 1,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index == matches.length) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: _ReRecognizeButton(onTap: onRestart),
                );
              }
              final m = matches[index];
              return _MatchRow(
                match: m,
                fav: isFavorite(m),
                onPlay: () => onPlay(m),
                onFavorite: () => onFavorite(m),
                onAddToPlaylist: () => onAddToPlaylist(m),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MatchRow extends StatefulWidget {
  const _MatchRow({
    required this.match,
    required this.fav,
    required this.onPlay,
    required this.onFavorite,
    required this.onAddToPlaylist,
  });

  final RecognizeMatch match;
  final bool fav;
  final VoidCallback onPlay;
  final VoidCallback onFavorite;
  final VoidCallback onAddToPlaylist;

  @override
  State<_MatchRow> createState() => _MatchRowState();
}

class _MatchRowState extends State<_MatchRow> {
  BuildContext? _coverCtx;

  Future<void> _handlePlay() async {
    // 等封面落地后再播放：播放条封面随落地同步更新。
    final ok = await launchFlyCover(
      context,
      coverContext: _coverCtx,
      coverSize: 52,
      networkUrl: widget.match.img,
      radius: 8,
    );
    if (ok) widget.onPlay();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = const Color(0xFFEC4141);
    final pct = (widget.match.confidence * 100).round();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // 匹配度
          SizedBox(
            width: 56,
            child: Column(
              children: [
                Text(
                  '$pct%',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFEC4141),
                  ),
                ),
                Text(
                  tr('匹配度'),
                  style: TextStyle(
                      fontSize: 9, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 封面
          Builder(
            builder: (c) {
              _coverCtx = c;
              return ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 52,
                  height: 52,
                  child: OnlineCover(url: widget.match.img, size: 52),
                ),
              );
            },
          ),
          const SizedBox(width: 12),
          // 歌曲信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.match.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  [widget.match.singer, widget.match.albumName]
                      .where((e) => e.isNotEmpty)
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          // 操作按钮
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(Icons.play_circle_fill,
                    size: 30, color: primary),
                tooltip: tr('播放'),
                onPressed: _handlePlay,
              ),
              IconButton(
                icon: Icon(
                  widget.fav ? Icons.favorite : Icons.favorite_border,
                  size: 22,
                  color: widget.fav ? primary : scheme.onSurfaceVariant,
                ),
                tooltip: widget.fav ? tr('已收藏') : tr('收藏'),
                onPressed: widget.onFavorite,
              ),
              IconButton(
                icon: Icon(Icons.playlist_add,
                    size: 22, color: scheme.onSurfaceVariant),
                tooltip: tr('添加到歌单'),
                onPressed: widget.onAddToPlaylist,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReRecognizeButton extends StatelessWidget {
  const _ReRecognizeButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: const Color(0xFFEC4141).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child:   Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.refresh, size: 18, color: Color(0xFFEC4141)),
            SizedBox(width: 6),
            Text(
              tr('重新识别'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFFEC4141),
              ),
            ),
          ],
        ),
      ),
    );
  }
}