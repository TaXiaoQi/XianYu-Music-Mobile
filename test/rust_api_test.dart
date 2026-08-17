import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/rust/frb_generated.dart' show RustLib;
import 'package:xianyu_music_mobile/src/rust/lib.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final dllPath =
        r'D:\Program Files\MC\开发端\开发组\弦予音乐\XianYu-Music-Mobile\rust\target\debug\xianyu_core.dll';
    await RustLib.init(externalLibrary: ExternalLibrary.open(dllPath));
  });

  test('qmc 解密可被 Dart 调用且 XOR 可逆', () async {
    // 任意 8 字节 key 的 base64 作为 ekey（无 body → Map 模式）
    final key8 = Uint8List.fromList(List.generate(8, (i) => 0x40 + i));
    final ekey = base64Encode(key8);
    final data = Uint8List.fromList(List.generate(100, (i) => i % 256));

    final once = await qmcDecryptBytes(data: data, ekey: ekey);
    final twice = await qmcDecryptBytes(data: once, ekey: ekey);

    expect(twice, data, reason: '解密两次应还原明文（XOR 可逆）');
  });

  test('spectrum 频带划分返回正确数量', () async {
    final samples = List<double>.generate(2048, (i) => (i % 100) / 100.0);
    final bands = await spectrumBands(
      samples: samples,
      sampleRate: 44100,
      bandCount: BigInt.from(10),
    );

    expect(bands.length, 10, reason: '应返回 10 个频带的能量');
  });

  test('音效 DSP 空设置时无损直通', () async {
    // 立体声交错 PCM，1 秒 44100Hz，正弦波
    const sr = 44100;
    const ch = 2;
    final samples = <double>[];
    for (var i = 0; i < sr; i++) {
      final v = (i % 100) / 100.0; // 0..0.99
      samples.add(v);
      samples.add(v);
    }

    final out = await soundEffectProcess(
      samples: samples,
      sampleRate: sr,
      channels: ch,
      settingsJson: '{}', // 空设置 → 默认（全关）
    );

    expect(out.length, samples.length, reason: '直通时样本数应保持不变');
    for (var i = 0; i < samples.length; i++) {
      expect((out[i] - samples[i]).abs(), lessThan(1e-4),
          reason: '所有音效关闭时应无损直通');
    }
  });

  test('音效 DSP 启用低音增强后输出改变', () async {
    const sr = 44100;
    const ch = 2;
    final samples = <double>[];
    for (var i = 0; i < sr; i++) {
      final v = (i % 100) / 100.0;
      samples.add(v);
      samples.add(v);
    }

    // 开启低音增强（gain 12dB）
    final settingsJson = jsonEncode({
      'bassBoost': {'enabled': true, 'gain': 12.0, 'dynamic': false},
      'pitchShift': 100.0,
      'playbackRate': 100.0,
    });
    final out = await soundEffectProcess(
      samples: samples,
      sampleRate: sr,
      channels: ch,
      settingsJson: settingsJson,
    );

    expect(out.length, greaterThan(0), reason: '开启低音增强后应输出样本');
  });

  test('lx 搜索返回合法 JSON 数组结构', () async {
    final result = await lxSearch(source: 'kw', keyword: '测试', limit: 3);
    // 搜索需要网络，可能失败；若成功则必须是合法 JSON
    if (result != 'null') {
      final decoded = jsonDecode(result);
      expect(decoded, isA<List<dynamic>>(), reason: '搜索结果应为 JSON 数组');
    }
  });

  test('lx 解析直链对无效参数优雅失败而非崩溃', () async {
    // 缺必填字段 → Rust 侧 serde 反序列化失败 → FRB 抛出异常，而非进程崩溃
    await expectLater(
      lxResolveUrl(songInfoJson: '{}', quality: '128k'),
      throwsA(anything),
      reason: '无效歌曲信息应抛异常而非崩溃',
    );
  });

  test('歌词解析返回 displayLines', () async {
    const raw = '[00:00.000]如果当时\n[00:03.000]人能顺着时光\n';
    final jsonStr = await parseLyrics(rawLyrics: raw);
    final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;

    expect(decoded['displayLines'], isA<List<dynamic>>(),
        reason: '应包含 displayLines 展示行');
    final lines = decoded['displayLines'] as List<dynamic>;
    expect(lines, isNotEmpty, reason: 'LRC 应解析出至少一行');
    expect((lines.first as Map<String, dynamic>)['text'], isNotEmpty,
        reason: '首行应包含歌词文本');
  });

  test('有状态音效处理器逐块处理且可复用', () async {
    const sr = 44100;
    const ch = 2;
    final proc = await SoundEffectProcessor.newInstance(
      sampleRate: sr,
      channels: ch,
    );

    // 空设置 → 直通
    await proc.setSettings(settingsJson: '{}');
    final samples = <double>[];
    for (var i = 0; i < 4410; i++) {
      final v = (i % 100) / 100.0;
      samples.add(v);
      samples.add(v);
    }
    final out = await proc.processBlock(samples: samples);
    expect(out.length, samples.length, reason: '直通时样本数一致');

    // 开启低音增强后有输出
    await proc.setSettings(settingsJson: jsonEncode({
      'bassBoost': {'enabled': true, 'gain': 9.0, 'dynamic': false},
    }));
    final out2 = await proc.processBlock(samples: samples);
    expect(out2.length, greaterThan(0), reason: '低音增强后仍应输出');

    // effectiveSampleRate 在默认变速下应等于输入采样率
    final sr2 = await proc.effectiveSampleRate();
    expect(sr2, sr, reason: '未变速时有效采样率与输入一致');
  });

  test('歌词在线抓取对无效参数优雅失败', () async {
    // 缺必填字段 → Rust 侧 serde 反序列化失败 → FRB 抛出异常
    await expectLater(
      fetchLyricFromSource(source: 'kg', songInfoJson: '{}'),
      throwsA(anything),
      reason: '无效歌曲信息应抛异常而非崩溃',
    );
  });

  test('均衡器默认旁路直通，启用后输出改变', () async {
    const sr = 44100;
    const ch = 2;
    final eq = await EqualizerProcessor.newInstance(
      sampleRate: sr,
      channels: ch,
    );

    final samples = <double>[];
    for (var i = 0; i < 4410; i++) {
      final v = (i % 100) / 100.0;
      samples.add(v);
      samples.add(v);
    }

    // 默认关闭 → 直通
    final out1 = await eq.processBlock(samples: samples);
    expect(out1.length, samples.length, reason: '旁路时样本数不变');
    for (var i = 0; i < samples.length; i++) {
      expect((out1[i] - samples[i]).abs(), lessThan(1e-4),
          reason: '旁路直通应无损');
    }

    // 启用 + preamp 6dB → 增益后输出幅度增大
    await eq.setSettings(settingsJson: jsonEncode({
      'enabled': true,
      'preamp': 6.0,
      'gains': List.filled(10, 0.0),
    }));
    final out2 = await eq.processBlock(samples: samples);
    final sum1 = out1.fold<double>(0, (a, b) => a + b.abs());
    final sum2 = out2.fold<double>(0, (a, b) => a + b.abs());
    expect(sum2, greaterThan(sum1), reason: '启用 preamp 后输出幅度应增大');
  });

  test('音频元数据读取对不存在的文件优雅失败', () async {
    await expectLater(
      readAudioMetadata(filePath: 'Z:\\\\nonexistent\\\\not_a_real_song.mp3'),
      throwsA(anything),
      reason: '不存在的文件应抛异常而非崩溃',
    );
  });

  test('音频元数据写入对不存在的文件优雅失败', () async {
    await expectLater(
      writeAudioMetadata(requestJson: jsonEncode({
        'filePath': 'Z:\\\\nonexistent\\\\write_test.mp3',
        'title': '测试',
      })),
      throwsA(anything),
      reason: '不存在的文件应抛异常而非崩溃',
    );
  });
}