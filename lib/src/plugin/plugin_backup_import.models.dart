part of 'plugin_backup_import.dart';

class ImportedSong {
  final String title;
  final String artist;
  final String album;
  final int duration;
  final String? coverUrl;
  final String? coverThumbPath;
  final String? localPath;
  final String? pluginId;
  final String? source;
  final String? format;
  final Map<String, dynamic>? musicInfo;
  final bool addedInApp;
  final String path;

  ImportedSong({
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    this.coverUrl,
    this.coverThumbPath,
    this.localPath,
    this.pluginId,
    this.source,
    this.format,
    this.musicInfo,
    this.addedInApp = false,
    required this.path,
  });

  bool get isLocal => localPath != null && localPath!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'album': album,
        'duration': duration,
        'coverUrl': coverUrl,
        'coverThumbPath': coverThumbPath,
        'localPath': localPath,
        'pluginId': pluginId,
        'source': source,
        'format': format,
        'musicInfo': musicInfo,
        if (addedInApp) 'addedInApp': true,
        'path': path,
      };

  factory ImportedSong.fromJson(Map<String, dynamic> j) => ImportedSong(
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        album: j['album'] as String? ?? '',
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        coverUrl: j['coverUrl'] as String?,
        coverThumbPath: j['coverThumbPath'] as String?,
        localPath: j['localPath'] as String?,
        pluginId: j['pluginId'] as String?,
        source: j['source'] as String?,
        format: j['format'] as String?,
        musicInfo: j['musicInfo'] is Map
            ? (j['musicInfo'] as Map).cast<String, dynamic>()
            : null,
        addedInApp: j['addedInApp'] == true,
        path: j['path'] as String? ?? '',
      );

  ImportedSong copyWith({
    String? pluginId,
    String? source,
    String? format,
    Map<String, dynamic>? musicInfo,
    bool? addedInApp,
  }) => ImportedSong(
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        coverUrl: coverUrl,
        coverThumbPath: coverThumbPath,
        localPath: localPath,
        pluginId: pluginId ?? this.pluginId,
        source: source ?? this.source,
        format: format ?? this.format,
        musicInfo: musicInfo ?? this.musicInfo,
        addedInApp: addedInApp ?? this.addedInApp,
        path: path,
      );
}

class PluginBackupPlaylist {
  final String name;
  final List<ImportedSong> songs;
  final int originalSongCount;
  final String? cloudId;
  final bool isCloud;
  final String? sourcePluginId;
  final String? sourceUrl;
  final Map<String, dynamic>? sourceRaw;

  PluginBackupPlaylist({
    required this.name,
    required this.songs,
    required this.originalSongCount,
    this.cloudId,
    this.isCloud = false,
    this.sourcePluginId,
    this.sourceUrl,
    this.sourceRaw,
  });
}

class PluginBackupFailedSong {
  final String playlist;
  final String title;
  final String artist;
  final String platform;
  final String reason;
  final String reasonCode;

  PluginBackupFailedSong({
    required this.playlist,
    required this.title,
    required this.artist,
    required this.platform,
    required this.reason,
    required this.reasonCode,
  });
}

class PluginBackupAssociation {
  final String pluginId;
  final String pluginName;
  final String pluginFormat;
  final bool enabled;
  final String platform;
  int songCount;

  PluginBackupAssociation({
    required this.pluginId,
    required this.pluginName,
    required this.pluginFormat,
    required this.enabled,
    required this.platform,
    required this.songCount,
  });
}

class MissingBackupPlugin {
  final String platform;
  final int songCount;

  MissingBackupPlugin({required this.platform, required this.songCount});
}

class PreparedPluginBackupImport {
  final String format;
  final int sourcePlaylistCount;
  final int totalSongCount;
  final int importedSongCount;
  final List<PluginBackupPlaylist> playlists;
  final List<PluginBackupFailedSong> failures;
  final List<PluginBackupAssociation> associations;
  final List<MissingBackupPlugin> missingPlugins;
  final int? backupVersion;
  final bool migratedTrackIds;
  final int migratedTrackIdCount;

  PreparedPluginBackupImport({
    required this.format,
    required this.sourcePlaylistCount,
    required this.totalSongCount,
    required this.importedSongCount,
    required this.playlists,
    required this.failures,
    required this.associations,
    required this.missingPlugins,
    this.backupVersion,
    required this.migratedTrackIds,
    required this.migratedTrackIdCount,
  });
}
