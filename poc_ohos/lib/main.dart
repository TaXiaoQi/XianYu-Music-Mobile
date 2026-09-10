// main.dart - 弦予音乐 鸿蒙原生（HarmonyOS NEXT）PoC 验证页
//
// 验证项（对应可行性报告的两大不确定点细化）：
//  1. Rust .so 加载 + FRB 运行时（hostSha256Hex）
//  2. AMLL 歌词解析纯计算（parseLyrics）
//  3. reqwest + rustls + tokio + DNS 网络栈（fetchAnnouncement）
//  4. QuickJS 插件引擎运行时（pluginEngineInit + pluginEngineLoadMusicfree 试运行）
//  5. rusqlite bundled 交叉编译产物 + 读写往返（statsRecordPlay / statsGetListenDurations）
//  6. just_audio 鸿蒙实现（AVPlayer 播放直链）
//  7. audio_service 鸿蒙实现（AVSession 创建 + 系统播控）
//
// 编译 .so: scripts/build-rust-ohos.ps1
// 生成壳工程并装配: scripts/setup.ps1

import 'dart:io';

import 'package:flutter/material.dart';
// ExternalLibrary 类定义在 for_generated_io 库（与生成代码同源）；
// 主包公开 API 仅导出 loadExternalLibrary，其 loader 不识别 ohos 平台，故直接用类。
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'src/rust/api.dart' as rust;
import 'src/rust/frb_generated.dart' as frb;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PocApp());
}

/// FRB 2.12 的运行时 loader 只认识 android/windows/ios/macos/linux，
/// Flutter-OH 下 Platform.operatingSystem 为 'ohos'，会抛 Unknown platform。
/// 非 Android/Windows/iOS/macOS/Linux 平台时手动 open libxianyu_core.so
/// （HAP 打包后 .so 位于 libs/arm64-v8a，dlopen 按名可寻）。
Future<void> initRust() async {
  final knownPlatform = Platform.isAndroid ||
      Platform.isWindows ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux;
  await frb.RustLib.init(
    forceSameCodegenVersion: false,
    externalLibrary: knownPlatform
        ? null
        : ExternalLibrary.open('libxianyu_core.so'),
  );
}

/// 最小 audio_service handler：只响应 play/pause，验证 AVSession 链路。
class PocAudioHandler extends BaseAudioHandler {
  @override
  Future<void> play() async {
    playbackState.add(playbackState.value.copyWith(
      playing: true,
      processingState: AudioProcessingState.ready,
    ));
  }

  @override
  Future<void> pause() async {
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.ready,
    ));
  }
}

class PocApp extends StatelessWidget {
  const PocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '弦予 鸿蒙 PoC',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      home: const PocPage(),
    );
  }
}

class _PocCase {
  final String title;
  final String desc;
  final Future<String> Function() run;
  const _PocCase(this.title, this.desc, this.run);
}

class _CaseStatus {
  bool running = false;
  bool error = false;
  String message = '';
}

class PocPage extends StatefulWidget {
  const PocPage({super.key});

  @override
  State<PocPage> createState() => _PocPageState();
}

class _PocPageState extends State<PocPage> {
  final _urlCtrl = TextEditingController(
    text: 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
  );
  final _player = AudioPlayer();
  PocAudioHandler? _audioHandler;
  Future<void>? _rustInit;
  late final List<_PocCase> _cases;
  late final List<_CaseStatus> _status;

  Future<void> _ensureRust() => _rustInit ??= initRust();

  @override
  void initState() {
    super.initState();
    _cases = [
      _PocCase('1. FRB 加载与调用', '加载 libxianyu_core.so 并走 FRB 全链路计算 SHA-256', () async {
        const input = 'xianyu-ohos-poc';
        final h = await rust.hostSha256Hex(text: input);
        return 'sha256 成功：${h.length} 位 hex，前 16 位 ${h.substring(0, 16)}';
      }),
      _PocCase('2. AMLL 歌词解析', 'parseLyrics 纯 Rust 计算（serde/AMLL 栈）', () async {
        const lrc = '[ti:鸿蒙PoC]\n[00:01.00]你好鸿蒙\n[00:03.50]弦予音乐\n';
        final json = await rust.parseLyrics(rawLyrics: lrc);
        return '解析成功：${json.length} 字节，displayLines=${json.contains('displayLines')}';
      }),
      _PocCase('3. 网络栈 reqwest+rustls', '走真实 HTTPS 请求，验证 DNS/TLS 在鸿蒙 musl 上可用', () async {
        final r = await rust.fetchAnnouncement();
        return r.isEmpty ? '请求成功但内容为空' : '请求成功，返回 ${r.length} 字节';
      }),
      _PocCase('4. QuickJS 插件引擎', '加载最小 MusicFree 格式脚本（引擎内带 CommonJS wrapper 试运行）', () async {
        final dir = await getApplicationSupportDirectory();
        final dataDir = dir.path;
        await rust.pluginEngineInit(dataDir: dataDir);
        const script =
            "module.exports = { platform: 'poc', version: '0.0.1', appVersion: '>=0.0.1', "
            "author: 'poc', srcUrl: 'https://example.com/poc.js', "
            "async getMediaSource() { return { url: '' } } };";
        final r = await rust.pluginEngineLoadMusicfree(
          dataDir: dataDir,
          pluginId: 'poc',
          script: script,
          userVarsJson: '{}',
        );
        return r.length > 220 ? '${r.substring(0, 220)}…' : r;
      }),
      _PocCase('5. SQLite（rusqlite bundled）', 'C 交叉编译组件 + 读写往返验证', () async {
        final dir = await getApplicationSupportDirectory();
        final db = '${dir.path}${Platform.pathSeparator}poc.db';
        await rust.statsRecordPlay(
          dbPath: db,
          payloadJson:
              '{"songPath":"poc://a.mp3","listenedMs":5000,"durationMs":200000,"title":"PoC","artist":"PoC","album":"PoC"}',
        );
        final d = await rust.statsGetListenDurations(dbPath: db);
        return '写入 + 读取往返成功：$d';
      }),
      _PocCase('6. just_audio 播放（AVPlayer）', '用顶部直链起播，能出声即 AVPlayer 适配通过', () async {
        final url = _urlCtrl.text.trim();
        if (url.isEmpty) {
          throw '请先在顶部输入音频直链 URL';
        }
        final dur = await _player.setUrl(url);
        _player.play();
        return '已起播，时长 ${dur?.inSeconds ?? '?'} 秒，请确认能听到声音';
      }),
      _PocCase('7. audio_service（AVSession）', '创建系统播控会话与通知，验证锁屏/播控中心', () async {
        // AudioService.init 不允许重复调用（内部 assert _cacheManager == null），
        // 复用首次创建的 handler 保证幂等可重复点击。
        final handler = _audioHandler ??= await AudioService.init(
          builder: () => PocAudioHandler(),
          config: const AudioServiceConfig(
            androidNotificationChannelId: 'cn.xianyumusic.poc.audio',
            androidNotificationChannelName: '鸿蒙 PoC 播放',
            androidNotificationOngoing: true,
          ),
        );
        await handler.prepare();
        return 'AudioService 初始化成功，检查通知栏/播控中心是否出现卡片';
      }),
    ];
    _status = List.generate(_cases.length, (_) => _CaseStatus());
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _run(int i) async {
    final c = _cases[i];
    setState(() {
      _status[i]
        ..running = true
        ..error = false
        ..message = '运行中…';
    });
    try {
      if (i < 5) await _ensureRust(); // 用例 1-5 走 Rust 链路，先确保 initRust
      final msg = await c.run();
      setState(() {
        _status[i]
          ..running = false
          ..error = false
          ..message = msg;
      });
    } catch (e) {
      setState(() {
        _status[i]
          ..running = false
          ..error = true
          ..message = '失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('弦予 鸿蒙 PoC'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text('Platform: ${Platform.operatingSystem}',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: '音频直链 URL（测试项 6 使用）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (var i = 0; i < _cases.length; i++) _card(i),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(int i) {
    final c = _cases[i];
    final st = _status[i];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        title: Text(c.title,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
          st.message.isEmpty ? c.desc : st.message,
          style: TextStyle(color: st.error ? Colors.red : null),
        ),
        trailing: st.running
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : FilledButton(
                onPressed: () => _run(i),
                child: const Text('运行'),
              ),
      ),
    );
  }
}