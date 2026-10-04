import 'dart:convert';

import '../core/application_logger.dart';
import '../rust/api.dart' as frb;
import 'fallback_modules/registry.dart';
import 'fallback_modules/types.dart';

/// 宿主侧歌单导入兜底：五平台统一薄壳。
///
/// 内置实现已下沉 Rust（rust/src/music/playlist_fetcher，移植自桌面端），
/// 本文件仅保留关键词/来源判断与结果映射；条目 Map 格式与原 Dart
/// 实现（*_sheet_import.dart）逐键一致，下游 mfItemToSearchResult 零适配。
class HostSheetImportResult {
  final List<Map<String, dynamic>> tracks;
  final String name;
  final String cover;
  final String author;
  final String desc;

  const HostSheetImportResult({
    required this.tracks,
    required this.name,
    required this.cover,
    required this.author,
    required this.desc,
  });
}

/// 平台 key → 模块方法后缀（kg→Kg / qishui→Qishui）
String _methodSuffix(String platform) =>
    platform.isEmpty ? platform : platform[0].toUpperCase() + platform.substring(1);

/// 经热修模块或 Rust 内置实现拉取歌单并映射为宿主导入结果；
/// 空结果按 null 处理（与旧实现「不适用或失败返回 null」语义一致）
Future<HostSheetImportResult?> _importViaRust(
  String platform,
  String keyword,
) async {
  final t = keyword.trim();
  if (t.isEmpty) return null;
  try {
    // 先走服务端热修模块（getListDetail{Platform}），未加载/失败回退 Rust 内置实现
    final decoded = await dispatchFallbackModule<Map<String, dynamic>?>(
      kFallbackModulePlaylistImport,
      'getListDetail${_methodSuffix(platform)}',
      {'rawId': t},
      () async {
        final raw = await frb.fetchPlaylistFromSource(source: platform, rawId: t);
        final obj = jsonDecode(raw);
        return obj is Map ? Map<String, dynamic>.from(obj) : null;
      },
    );
    if (decoded == null) return null;
    final songs = decoded['songs'];
    if (songs is! List || songs.isEmpty) return null;
    final info = decoded['info'] is Map ? decoded['info'] as Map : const {};
    return HostSheetImportResult(
      tracks: songs
          .whereType<Map>()
          .map((e) => _rustSongToItem(e.cast<String, dynamic>(), platform))
          .toList(),
      name: info['name']?.toString() ?? '',
      cover: info['img']?.toString() ?? '',
      author: info['author']?.toString() ?? '',
      desc: info['desc']?.toString() ?? '',
    );
  } catch (e) {
    AppLog.warn('plugin', '[$platform-import] 歌单导入失败: $e');
  }
  return null;
}

/// PlaylistSong（camelCase）→ 旧宿主条目 Map（songmid/name/singer/
/// source/interval/artwork 等宿主补充键，兼容 mfItemToSearchResult 与播放链）
Map<String, dynamic> _rustSongToItem(Map<String, dynamic> song, String platform) {
  final id = song['id']?.toString() ?? '';
  final title = song['title']?.toString() ?? '';
  final artist = song['artist']?.toString() ?? '';
  final durationMs = (song['duration'] as num?)?.toInt() ?? 0;
  final src = song['platform']?.toString() ?? platform;
  return {
    'id': id,
    'title': title,
    'artist': artist,
    'album': song['album']?.toString() ?? '',
    'artwork': song['coverUrl']?.toString() ?? '',
    'duration': durationMs,
    'songmid': id,
    'name': title,
    'singer': artist,
    'source': src,
    'platform': src,
    'interval': _formatPlayTime(durationMs ~/ 1000),
  };
}

String _formatPlayTime(int seconds) {
  if (seconds <= 0) return '--/--';
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '${m < 10 ? '0$m' : '$m'}:${s < 10 ? '0$s' : '$s'}';
}

class KgSheetImport {
  KgSheetImport._();

  /// 关键词是否酷狗特征（链接域 / gcid / 数字酷狗码）
  static bool isKgKeyword(String keyword) {
    final t = keyword.trim().toLowerCase();
    return t.contains('kugou.com') ||
        t.contains('gcid_') ||
        t.contains('global_collection_id');
  }

  /// 插件是否酷狗系（数字酷狗码导入需要来源限定，避免误伤网易/QQ 数字 ID）
  static bool isKgSource(String name, List<String> sources) {
    final n = name.toLowerCase();
    if (n.contains('酷狗') || n.contains('kugou')) return true;
    for (final s in sources) {
      final t = s.trim().toLowerCase();
      if (t == 'kg' || t == 'kugou' || t.contains('酷狗')) return true;
    }
    return false;
  }

  /// 导入入口。返回 null 表示不适用或失败，调用方继续原有流程。
  static Future<HostSheetImportResult?> import(String keyword) =>
      _importViaRust('kg', keyword);
}

class QishuiSheetImport {
  QishuiSheetImport._();

  static bool isQishuiKeyword(String keyword) {
    final t = keyword.trim().toLowerCase();
    return t.contains('qishui') ||
        keyword.contains('汽水') ||
        t.contains('douyin.com');
  }

  static bool isQishuiSource(String name, List<String> sources) {
    final n = name.toLowerCase();
    if (n.contains('汽水') || n.contains('qishui')) return true;
    for (final s in sources) {
      final t = s.trim().toLowerCase();
      if (t == 'qishui' || t.contains('汽水') || t.contains('qishui')) {
        return true;
      }
    }
    return false;
  }

  /// 导入入口。返回 null 表示不适用或失败，调用方继续原有流程。
  static Future<HostSheetImportResult?> import(String keyword) =>
      _importViaRust('qishui', keyword);
}

class WySheetImport {
  WySheetImport._();

  static bool isWyKeyword(String keyword) {
    final t = keyword.trim().toLowerCase();
    return t.contains('music.163.com') ||
        t.contains('y.music.163.com') ||
        t.contains('163cn.tv');
  }

  /// 插件是否网易云系（纯数字歌单 ID 导入需要来源限定）
  static bool isWySource(String name, List<String> sources) {
    final n = name.toLowerCase();
    if (n.contains('网易') || n.contains('netease')) return true;
    for (final s in sources) {
      final t = s.trim().toLowerCase();
      if (t == 'wy' || t == 'netease' || t.contains('网易')) return true;
    }
    return false;
  }

  /// 导入入口。返回 null 表示不适用或失败，调用方继续原有流程。
  static Future<HostSheetImportResult?> import(String keyword) =>
      _importViaRust('wy', keyword);
}

class TxSheetImport {
  TxSheetImport._();

  static bool isTxKeyword(String keyword) {
    final t = keyword.trim().toLowerCase();
    return t.contains('y.qq.com') ||
        t.contains('i.y.qq.com') ||
        t.contains('c.y.qq.com');
  }

  /// 插件是否 QQ 音乐系（纯数字歌单 ID 导入需要来源限定）
  static bool isTxSource(String name, List<String> sources) {
    final n = name.toLowerCase();
    if (n.contains('qq') || n.contains('企鹅') || n.contains('腾讯')) return true;
    for (final s in sources) {
      final t = s.trim().toLowerCase();
      if (t == 'tx' || t == 'qq' || t.contains('qq')) return true;
    }
    return false;
  }

  /// 导入入口。返回 null 表示不适用或失败，调用方继续原有流程。
  static Future<HostSheetImportResult?> import(String keyword) =>
      _importViaRust('tx', keyword);
}

class KwSheetImport {
  KwSheetImport._();

  /// 关键词是否酷我特征（链接域）
  static bool isKwKeyword(String keyword) {
    final t = keyword.trim().toLowerCase();
    return t.contains('kuwo.cn');
  }

  /// 插件是否酷我系（纯数字歌单 ID 导入需要来源限定）
  static bool isKwSource(String name, List<String> sources) {
    final n = name.toLowerCase();
    if (n.contains('酷我') || n.contains('kuwo')) return true;
    for (final s in sources) {
      final t = s.trim().toLowerCase();
      if (t == 'kw' || t == 'kuwo' || t.contains('酷我')) return true;
    }
    return false;
  }

  /// 导入入口。返回 null 表示不适用或失败，调用方继续原有流程。
  static Future<HostSheetImportResult?> import(String keyword) =>
      _importViaRust('kw', keyword);
}
