library;

import 'dart:convert';
import 'dart:io';

import 'plugin_models.dart';
import '../i18n/i18n.dart';

part 'plugin_backup_import.models.dart';
part 'plugin_backup_import.platform.dart';
part 'plugin_backup_import.songs.dart';
part 'plugin_backup_import.detect.dart';
part 'plugin_backup_import.playlist_file.dart';

const int _stringifiedTrackIdBackupVersion = 2;
const int _currentTrackIdBackupVersion = 3;

String describeBackupVersion(PreparedPluginBackupImport prepared) {
  final formatName = switch (prepared.format) {
    'bakamusic' => 'BakaMusic',
    'musicfree' => 'MusicFree',
    'lxmusic' => tr('洛雪音乐'),
    'm3u' => tr('M3U 播放列表'),
    'txt' => tr('椒盐音乐'),
    _ => tr('未知格式'),
  };
  if (prepared.format == 'm3u' || prepared.format == 'txt') {
    return formatName;
  }
  if (prepared.backupVersion == null) {
    return tr('{name} 备份（未标注版本）', {'name': formatName});
  }
  final label = '$formatName v${prepared.backupVersion}';
  if (prepared.migratedTrackIds) {
    return prepared.migratedTrackIdCount > 0
        ? tr('{label} 旧版备份，已还原 {n} 首歌曲 ID 以恢复逐字歌词', {'label': label, 'n': prepared.migratedTrackIdCount})
        : tr('{label} 旧版备份', {'label': label});
  }
  if (prepared.format == 'bakamusic' && prepared.backupVersion! >= _currentTrackIdBackupVersion) {
    return tr('{label} 新版备份', {'label': label});
  }
  return label;
}
