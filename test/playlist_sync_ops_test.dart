import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_music_mobile/src/playlist/playlist_store.dart';
import 'package:xianyu_music_mobile/src/plugin/plugin_backup_import.dart';
import 'package:xianyu_music_mobile/src/sync/playlist_sync_ops.dart';

// ==================== applySyncOps 单测（对齐桌面端 playlistOpsApply.test.ts） ====================

/// 带「本地曲库路径解析」的 resolver：path 直查，miss 后按 title|artist 兜底
ImportedSong Function(Map<String, dynamic>) makeResolver(
  List<ImportedSong> library,
) {
  final byPath = {for (final s in library) s.path: s};
  final byMeta = <String, List<ImportedSong>>{};
  for (final s in library) {
    byMeta.putIfAbsent('${s.title}|${s.artist}', () => []).add(s);
  }
  return (payload) {
    final s = ImportedSong.fromJson(payload);
    if (byPath.containsKey(s.path)) return s;
    final candidates = byMeta['${s.title}|${s.artist}'];
    if (candidates == null || candidates.isEmpty) return s;
    return ImportedSong(
      title: s.title,
      artist: s.artist,
      album: s.album,
      duration: s.duration,
      coverUrl: s.coverUrl,
      localPath: candidates.first.path,
      path: candidates.first.path,
    );
  };
}

class _Env {
  final SyncOpsTarget target;
  final List<ImportedPlaylist> playlists;
  final Map<String, Set<String>> kept;
  final Map<String, Set<String>> pending;

  _Env._(this.target, this.playlists, this.kept, this.pending);

  factory _Env({
    List<ImportedSong> library = const [],
    Map<String, Set<String>> kept = const {},
    Map<String, Set<String>> pending = const {},
  }) {
    final playlists = <ImportedPlaylist>[];
    final target = SyncOpsTarget(
      playlists: playlists,
      resolveSong: makeResolver(library),
      isSongKept: (cloudId, path) => kept[cloudId]?.contains(path) ?? false,
      isSongPendingDeleted: (cloudId, path) =>
          pending[cloudId]?.contains(path) ?? false,
    );
    return _Env._(target, playlists, kept, pending);
  }

  void addPlaylist(ImportedPlaylist pl) => playlists.add(pl);
}

ImportedSong song(String path, String title, String artist, {int duration = 180}) =>
    ImportedSong(
      title: title,
      artist: artist,
      album: '',
      duration: duration,
      path: path,
    );

Map<String, dynamic> payload(String path, String title, String artist) =>
    ImportedSong(title: title, artist: artist, album: '', duration: 180, path: path)
        .toJson();

void main() {
  test('create_playlist 新建歌单并解析本地路径', () {
    final env = _Env(library: [song('C:/Music/a.mp3', 'Song A', 'Artist')]);
    final outcome = applySyncOps([
      {
        'type': 'create_playlist',
        'playlist': {
          'id': 'pl-1',
          'name': '云端歌单',
          'cloudId': 'c-1',
          'cloudCoverUrl': 'http://cover',
          'songs': [payload('C:/Music/a.mp3', 'Song A', 'Artist')],
        },
      }
    ], env.target);

    expect(outcome.createdPlaylists, 1);
    expect(env.playlists, hasLength(1));
    final pl = env.playlists.first;
    expect(pl.cloudId, 'c-1');
    expect(pl.isCloud, true);
    expect(pl.songs.map((s) => s.path), ['C:/Music/a.mp3']);
  });

  test('create_playlist 按 cloudId 命中既有歌单时走合并而非重复建单', () {
    final env = _Env();
    env.addPlaylist(ImportedPlaylist(
      id: 'pl-1',
      name: '已有',
      songs: [song('C:/Music/old.mp3', 'Old', 'A')],
      importedAt: 1,
      cloudId: 'c-1',
    ));
    final outcome = applySyncOps([
      {
        'type': 'create_playlist',
        'playlist': {
          'id': 'pl-1',
          'name': '云端歌单',
          'cloudId': 'c-1',
          'songs': [payload('C:/Music/new.mp3', 'New', 'A')],
        },
      }
    ], env.target);

    expect(outcome.createdPlaylists, 0);
    expect(outcome.mergedPlaylists, 1);
    expect(env.playlists.first.songs.map((s) => s.path),
        ['C:/Music/old.mp3', 'C:/Music/new.mp3']);
    expect(env.playlists.first.isCloud, true);
  });

  test('create_playlist 在 cloudId 缺失时按本地 id 兜底匹配并回写 cloudId', () {
    final env = _Env();
    env.addPlaylist(ImportedPlaylist(
        id: 'pl-1', name: '已有', songs: [], importedAt: 1));
    final outcome = applySyncOps([
      {
        'type': 'create_playlist',
        'playlist': {'id': 'pl-1', 'name': '云端歌单', 'cloudId': 'c-1', 'songs': []},
      }
    ], env.target);

    expect(outcome.createdPlaylists, 0);
    expect(outcome.mergedPlaylists, 1);
    expect(env.playlists.first.cloudId, 'c-1');
  });

  test('create_playlist 合并时按 deletedSongPaths 过滤既有歌曲（含路径展开）', () {
    final env = _Env(library: [song('D:/Music/local.mp3', 'Del', 'A')]);
    env.addPlaylist(ImportedPlaylist(
      id: 'pl-1',
      name: '已有',
      songs: [song('D:/Music/local.mp3', 'Del', 'A')],
      importedAt: 1,
      cloudId: 'c-1',
    ));
    applySyncOps([
      {
        'type': 'create_playlist',
        'playlist': {
          'id': 'pl-1',
          'name': '云端歌单',
          'cloudId': 'c-1',
          'deletedSongPaths': ['C:/Music/local.mp3'],
          'songs': [payload('C:/Music/local.mp3', 'Del', 'A')],
        },
      }
    ], env.target);

    // 云端墓碑路径 C:/Music/local.mp3 经曲库解析展开为 D:/Music/local.mp3，
    // 既有同名歌被移除，载荷自身也被墓碑拦截
    expect(env.playlists.first.songs, isEmpty);
  });

  test('add_songs 只追加本地没有的歌曲并按 path 去重', () {
    final env = _Env();
    env.addPlaylist(ImportedPlaylist(
      id: 'pl-1',
      name: '已有',
      songs: [song('C:/Music/a.mp3', 'Song A', 'Artist')],
      importedAt: 1,
      cloudId: 'c-1',
    ));
    final outcome = applySyncOps([
      {
        'type': 'add_songs',
        'cloudId': 'c-1',
        'songs': [
          payload('C:/Music/a.mp3', 'Song A', 'Artist'),
          payload('C:/Music/b.mp3', 'Song B', 'Artist'),
        ],
      }
    ], env.target);

    expect(outcome.addedSongs, 1);
    expect(env.playlists.first.songs.map((s) => s.path),
        ['C:/Music/a.mp3', 'C:/Music/b.mp3']);
  });

  test('add_songs 过滤 cloudKeep 与 pendingDeleted 中的歌曲', () {
    final env = _Env(
      kept: {
        'c-1': {'keep://1'},
      },
      pending: {
        'c-1': {'pending://1'},
      },
    );
    env.addPlaylist(ImportedPlaylist(
        id: 'pl-1', name: '已有', songs: [], importedAt: 1, cloudId: 'c-1'));
    final outcome = applySyncOps([
      {
        'type': 'add_songs',
        'cloudId': 'c-1',
        'songs': [
          payload('keep://1', 'K', 'A'),
          payload('pending://1', 'P', 'A'),
          payload('lx://ok/1', 'Ok', 'A'),
        ],
      }
    ], env.target);

    expect(env.playlists.first.songs.map((s) => s.path), ['lx://ok/1']);
    expect(outcome.addedSongs, 1);
  });

  test('add_songs 无命中歌单时跳过', () {
    final env = _Env();
    final outcome = applySyncOps([
      {
        'type': 'add_songs',
        'cloudId': 'missing',
        'songs': [payload('lx://x/1', 'X', 'A')],
      }
    ], env.target);

    expect(outcome.mergedPlaylists, 0);
    expect(env.playlists, isEmpty);
  });

  test('add_songs 在 cloudId 未命中时按 id 字段兜底匹配并回写 cloudId', () {
    final env = _Env();
    env.addPlaylist(ImportedPlaylist(
        id: 'pl-1', name: '已有', songs: [], importedAt: 1));
    applySyncOps([
      {
        'type': 'add_songs',
        'cloudId': 'c-1',
        'id': 'pl-1',
        'songs': [],
      }
    ], env.target);
    expect(env.playlists.first.cloudId, 'c-1');

    // 已有一致 cloudId 时不重复写
    final env2 = _Env();
    env2.addPlaylist(ImportedPlaylist(
        id: 'pl-2', name: '已有', songs: [], importedAt: 1, cloudId: 'c-9'));
    applySyncOps([
      {'type': 'add_songs', 'cloudId': 'c-9', 'songs': []}
    ], env2.target);
    expect(env2.playlists.first.cloudId, 'c-9');
  });

  test('remove_songs 过滤墓碑路径', () {
    final env = _Env();
    env.addPlaylist(ImportedPlaylist(
      id: 'pl-1',
      name: '已有',
      songs: [song('a', 'A', 'x'), song('b', 'B', 'x'), song('c', 'C', 'x')],
      importedAt: 1,
      cloudId: 'c-1',
    ));
    final outcome = applySyncOps([
      {
        'type': 'remove_songs',
        'cloudId': 'c-1',
        'paths': ['a', 'c'],
      }
    ], env.target);

    expect(outcome.removedSongs, 2);
    expect(env.playlists.first.songs.map((s) => s.path), ['b']);
  });

  test('update_playlist_meta 只应用 patch 中出现的字段', () {
    final env = _Env();
    env.addPlaylist(ImportedPlaylist(
      id: 'pl-1',
      name: '已有',
      songs: [song('a', 'A', 'x')],
      importedAt: 1,
      cloudId: 'c-1',
      sourcePluginId: 'p1',
    ));
    applySyncOps([
      {
        'type': 'update_playlist_meta',
        'cloudId': 'c-1',
        'sourceUrl': 'http://s',
      }
    ], env.target);

    expect(env.playlists.first.sourceUrl, 'http://s');
    expect(env.playlists.first.sourcePluginId, 'p1');
    expect(env.playlists.first.songs.map((s) => s.path), ['a']);
  });

  test('混合 ops 顺序应用且相互独立', () {
    final env = _Env();
    env.addPlaylist(ImportedPlaylist(
      id: 'pl-1',
      name: '已有',
      songs: [song('old', 'Old', 'x')],
      importedAt: 1,
      cloudId: 'c-1',
    ));
    final outcome = applySyncOps([
      {
        'type': 'update_playlist_meta',
        'cloudId': 'c-1',
        'sourceUrl': 'http://cover',
      },
      {
        'type': 'add_songs',
        'cloudId': 'c-1',
        'songs': [payload('lx://1', 'S1', 'x')],
      },
      {
        'type': 'remove_songs',
        'cloudId': 'c-1',
        'paths': ['old'],
      },
      {
        'type': 'create_playlist',
        'playlist': {'id': 'pl-2', 'name': '新歌单', 'cloudId': 'c-2', 'songs': []},
      },
    ], env.target);

    expect(outcome.mergedPlaylists, 1);
    expect(outcome.createdPlaylists, 1);
    expect(outcome.removedSongs, 1);
    expect(env.playlists.first.songs.map((s) => s.path), ['lx://1']);
    expect(env.playlists.first.sourceUrl, 'http://cover');
    expect(env.playlists.last.isCloud, true);
  });

  test('playlistSyncSongHash 口径：online=md5(path)，local=md5(title|artist|local)', () {
    expect(
      playlistSyncSongHash(song('lx://wy/1', 'T', 'A')),
      md5.convert(utf8.encode('lx://wy/1')).toString(),
    );
    final local = playlistSyncSongHash(song('C:/m/f.mp3', 'T', 'A'));
    expect(local, md5.convert(utf8.encode('T|A|local')).toString());
    // 本地 hash 与路径无关（跨设备按元数据对齐），与在线 hash 互异
    expect(playlistSyncSongHash(song('C:/other/f.mp3', 'T', 'A')), local);
    expect(
      playlistSyncSongHash(song('https://x/1', 'T', 'A')),
      isNot(local),
    );
  });
}
