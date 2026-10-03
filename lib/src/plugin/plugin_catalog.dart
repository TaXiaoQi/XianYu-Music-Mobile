import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../player/player_provider.dart';
import '../core/application_logger.dart';
import '../i18n/i18n.dart';
import '../rust/api.dart';
import 'host_sheet_import.dart';
import 'plugin_engine.dart';
import 'plugin_host_fallback.dart';
import 'plugin_models.dart';
part 'plugin_catalog.models.dart';
part 'plugin_catalog.service.dart';
part 'plugin_catalog.utils.dart';

class PluginCatalogService {
  final PluginEngine engine;
  final List<PluginSource> sources;

  PluginCatalogService(this.engine, this.sources);

  /// 判断输入是否像歌单分享链接或纯数字歌单 ID。
  /// 自己的歌单只能靠链接/ID 精确导入，公开搜索搜不到。
  static bool looksLikeSheetLinkOrId(String keyword) {
    final t = keyword.trim().toLowerCase();
    if (t.isEmpty) return false;
    if (RegExp(r'^\d{6,}$').hasMatch(t)) return true;
    return RegExp(
            r'https?://|\.com|\.cn|\.cc|netease|kugou|kuwo|qishui|douyin|qq\.com')
        .hasMatch(t);
  }

  Future<List<MfSheetItem>> searchSheets(
      PluginSource source, String keyword) async {
    // 链接/歌单 ID 优先走 importMusicSheet 精确导入：公开搜索会把链接当
    // 关键词，搜出来的全是别人的同名歌单。
    final linkLike = looksLikeSheetLinkOrId(keyword);
    if (linkLike) {
      final exact = await importSheetExact(source, keyword);
      if (exact != null) return [exact];
    }
    for (final type in ['sheet', 'playlist', 'album']) {
      final list = await _tryCallRawList(source, 'search', [keyword, 1, type]);
      if (list.isEmpty) continue;
      final sheets = list.map((m) {
        if (type == 'album') m['_isAlbum'] = true;
        return _toSheet(m, source);
      }).where((s) => s.title.isNotEmpty).toList();
      if (sheets.isNotEmpty) return sheets;
    }
    if (!linkLike) {
      final rawTracks =
          await _tryCallRawList(source, 'importMusicSheet', [keyword]);
      if (rawTracks.isNotEmpty) {
        return _sheetFromImportedTracks(source, keyword, rawTracks);
      }
    }
    return const [];
  }

  /// 酷狗歌单宿主兜底：插件 importMusicSheet 失败后调用。
  /// 链接类输入直接尝试；纯数字 ID 仅在酷狗系插件下尝试。
  Future<MfSheetItem?> _kgFallbackSheet(
      PluginSource source, String keyword) async {
    final applicable = KgSheetImport.isKgKeyword(keyword) ||
        (looksLikeSheetLinkOrId(keyword) &&
            KgSheetImport.isKgSource(source.name, source.sources));
    if (!applicable) return null;
    final kg = await KgSheetImport.import(keyword);
    if (kg == null || kg.tracks.isEmpty) return null;
    return _hostImportSheetItem(source, keyword, kg);
  }

  /// 汽水歌单宿主兜底：插件 importMusicSheet 返回空后调用。
  Future<MfSheetItem?> _qsFallbackSheet(
      PluginSource source, String keyword) async {
    final applicable = QishuiSheetImport.isQishuiKeyword(keyword) ||
        (looksLikeSheetLinkOrId(keyword) &&
            QishuiSheetImport.isQishuiSource(source.name, source.sources));
    if (!applicable) return null;
    final qs = await QishuiSheetImport.import(keyword);
    if (qs == null || qs.tracks.isEmpty) return null;
    return _hostImportSheetItem(source, keyword, qs);
  }

  /// 网易云歌单宿主兜底：插件 importMusicSheet 返回空后调用。
  Future<MfSheetItem?> _wyFallbackSheet(
      PluginSource source, String keyword) async {
    final applicable = WySheetImport.isWyKeyword(keyword) ||
        (looksLikeSheetLinkOrId(keyword) &&
            WySheetImport.isWySource(source.name, source.sources));
    if (!applicable) return null;
    final wy = await WySheetImport.import(keyword);
    if (wy == null || wy.tracks.isEmpty) return null;
    return _hostImportSheetItem(source, keyword, wy);
  }

  /// QQ 音乐歌单宿主兜底：插件 importMusicSheet 返回空后调用。
  Future<MfSheetItem?> _txFallbackSheet(
      PluginSource source, String keyword) async {
    final applicable = TxSheetImport.isTxKeyword(keyword) ||
        (looksLikeSheetLinkOrId(keyword) &&
            TxSheetImport.isTxSource(source.name, source.sources));
    if (!applicable) return null;
    final tx = await TxSheetImport.import(keyword);
    if (tx == null || tx.tracks.isEmpty) return null;
    return _hostImportSheetItem(source, keyword, tx);
  }

  /// 酷我歌单宿主兜底：插件 importMusicSheet 返回空后调用。
  Future<MfSheetItem?> _kwFallbackSheet(
      PluginSource source, String keyword) async {
    final applicable = KwSheetImport.isKwKeyword(keyword) ||
        (looksLikeSheetLinkOrId(keyword) &&
            KwSheetImport.isKwSource(source.name, source.sources));
    if (!applicable) return null;
    final kw = await KwSheetImport.import(keyword);
    if (kw == null || kw.tracks.isEmpty) return null;
    return _hostImportSheetItem(source, keyword, kw);
  }

  // ==================== 队列项转换 ====================

  static QueueItem toQueueItem(PluginSource source, PluginSearchResult r) {
    final songJson = jsonEncode({
      'pluginId': source.id,
      'format': source.format.value,
      'musicInfo': r.toJson(),
    });
    return QueueItem(
      path: 'plugin://${source.id}/${r.songmid}',
      title: r.name,
      artist: r.singer,
      album: r.albumName,
      durationMs: _parseIntervalMs(r.interval),
      coverUrl: r.img,
      onlineSongJson: songJson,
      onlineQuality: '320k',
    );
  }
}
