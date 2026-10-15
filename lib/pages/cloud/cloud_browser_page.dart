import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/download/download_provider.dart';
import '../../src/i18n/i18n.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';

/// 网盘浏览页：我的网盘目录浏览 + 点播音频文件。
///
/// 路径语义各盘不同（fid / 真实路径 / folderId），导航键取
/// 「条目 path 非空且不等于当前目录时用 path，否则用 id」——覆盖
/// path 型盘（百度）与 id 型盘（其余）两种声明。
class CloudBrowserPage extends ConsumerStatefulWidget {
  const CloudBrowserPage({super.key, required this.providerId, this.accountId});

  final String providerId;

  /// 指定账号 id；缺省取该盘第一个已绑定账号。
  final String? accountId;

  @override
  ConsumerState<CloudBrowserPage> createState() => _CloudBrowserPageState();
}

class _Crumb {
  const _Crumb(this.path, this.name);
  final String path;
  final String name;
}

class _CloudBrowserPageState extends ConsumerState<CloudBrowserPage> {
  late final CloudProvider _provider;
  List<CloudAccount> _accounts = const [];
  String? _accountId;
  bool _noAccount = false;

  final List<_Crumb> _stack = [];
  List<CloudFile> _files = const [];
  String? _cursor;
  bool _loading = true;
  bool _appending = false;

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    _init();
  }

  Future<void> _init() async {
    final accounts =
        await CloudCredentialsStore.instance.accountsFor(_provider.id);
    if (!mounted) return;
    if (accounts.isEmpty) {
      setState(() {
        _noAccount = true;
        _loading = false;
      });
      return;
    }
    final id = widget.accountId ??
        accounts.first.accountId; // 传入账号已解绑时回退第一个
    final valid = accounts.any((a) => a.accountId == id)
        ? id
        : accounts.first.accountId;
    setState(() {
      _accounts = accounts;
      _accountId = valid;
      _stack
        ..clear()
        ..add(_Crumb(_provider.rootPath, tr('全部文件')));
    });
    _load();
  }

  Future<Map<String, String>> _cred() async {
    final id = _accountId;
    if (id != null) {
      final cred = await CloudCredentialsStore.instance.credFor(_provider.id, id);
      if (cred != null) return cred;
    }
    final sole = await CloudCredentialsStore.instance.soleCredFor(_provider.id);
    return sole ?? const {};
  }

  /// 进入子目录：path 型盘条目携带绝对路径，id 型盘回退用 id。
  void _enter(CloudFile dir) {
    final cur = _stack.last.path;
    final next = (dir.path != null &&
            dir.path!.isNotEmpty &&
            dir.path != cur)
        ? dir.path!
        : dir.id;
    setState(() => _stack.add(_Crumb(next, dir.name)));
    _load();
  }

  void _jumpTo(int index) {
    if (index == _stack.length - 1) return;
    setState(() => _stack.removeRange(index + 1, _stack.length));
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_cursor == null || _appending)) return;
    final path = _stack.last.path;
    if (!mounted) return;
    setState(() {
      if (more) {
        _appending = true;
      } else {
        _loading = true;
        _files = const [];
        _cursor = null;
      }
    });
    Map<String, String> cred = const {};
    try {
      cred = await _cred();
      final r = await _provider.listDir(cred, path, cursor: more ? _cursor : null);
      if (!mounted || _stack.isEmpty || _stack.last.path != path) return;
      setState(() {
        _files = more ? [..._files, ...r.files] : r.files;
        _cursor = r.nextCursor;
        _loading = false;
        _appending = false;
      });
    } catch (e) {
      if (!mounted || _stack.isEmpty || _stack.last.path != path) return;
      final credKeys = cred.keys.toList();
      final rtHead = (cred['refreshToken'] ?? '').toString();
      AppLog.warn(
          'cloud',
          '列目录失败 path=$path: ${e is CloudException ? e.message : e}'
          ' | credKeys=$credKeys rtLen=${rtHead.length} rtHead=${rtHead.length > 8 ? rtHead.substring(0, 8) : rtHead}');
      setState(() {
        _loading = false;
        _appending = false;
      });
      showXianYuToast(
        context,
        e is CloudException ? e.message : tr('目录加载失败'),
      );
    }
  }

  Future<void> _switchAccount(String id) async {
    if (id == _accountId) return;
    setState(() {
      _accountId = id;
      _stack
        ..clear()
        ..add(_Crumb(_provider.rootPath, tr('全部文件')));
    });
    _load();
  }

  String _sizeText(int size) {
    if (size <= 0) return '';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  CloudPlayContext? _contextFor(CloudFile f) {
    for (final a in _accounts) {
      if (a.accountId == _accountId) {
        return CloudPlayContext(
          provider: _provider.id,
          accountId: a.accountId,
          file: f,
        );
      }
    }
    return null;
  }

  Future<void> _play(CloudFile f) async {
    final ctx = _contextFor(f);
    if (ctx == null) {
      showXianYuToast(context, tr('网盘账号未绑定或已失效'));
      return;
    }
    await ref
        .read(playerProvider.notifier)
        .playQueue([cloudPlayQueueItem(ctx, artist: _provider.displayName)],
            startIndex: 0);
  }

  Future<void> _download(CloudFile f) async {
    final ctx = _contextFor(f);
    if (ctx == null) {
      showXianYuToast(context, tr('网盘账号未绑定或已失效'));
      return;
    }
    final dn = ref.read(downloadProvider.notifier);
    if (!await dn.requireDownloadDir(context)) return;
    try {
      await dn.downloadCloud(
          cloudPlayQueueItem(ctx, artist: _provider.displayName));
      if (!mounted) return;
      showXianYuToast(context,
          tr('开始下载：{title}，请留意通知查看下载进度', {'title': f.name}));
    } catch (e) {
      if (!mounted) return;
      showXianYuToast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Column(
            children: [
              SizedBox(height: GlassTopBar.height(context)),
              if (_accounts.length > 1) _accountSelector(context, scheme),
              _breadcrumb(context, scheme),
              Divider(
                height: 1,
                thickness: 0.5,
                color: scheme.onSurface.withValues(alpha: 0.08),
              ),
              Expanded(child: _list(context, scheme)),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(_provider.displayName),
            ),
          ),
          if (_noAccount) _noAccountView(context, scheme),
        ],
      ),
    );
  }

  Widget _accountSelector(BuildContext context, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          Text(
            tr('账号'),
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<String>(
              value: _accountId,
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final a in _accounts)
                  DropdownMenuItem(
                    value: a.accountId,
                    child: Text(
                      a.nickname.isEmpty ? a.accountId : a.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) _switchAccount(v);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _breadcrumb(BuildContext context, ColorScheme scheme) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shrinkWrap: true,
        children: [
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _stack.length; i++) ...[
                  if (i > 0)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  GestureDetector(
                    onTap: () => _jumpTo(i),
                    child: Text(
                      _stack[i].name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            i == _stack.length - 1 ? FontWeight.w600 : null,
                        color: i == _stack.length - 1
                            ? scheme.onSurface
                            : scheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_files.isEmpty) {
      return Center(
        child: Text(
          tr('空目录'),
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      );
    }
    final dirs = _files.where((f) => f.isDir).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final audio = _files.where((f) => !f.isDir && f.isAudio).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final others = _files
        .where((f) => !f.isDir && !f.isAudio)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final ordered = [...dirs, ...audio, ...others];

    return ListView.builder(
      itemCount: ordered.length + (_cursor != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= ordered.length) {
          return ListTile(
            title: Center(
              child: _appending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      tr('加载更多'),
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.primary,
                      ),
                    ),
            ),
            onTap: _appending ? null : () => _load(more: true),
          );
        }
        final f = ordered[i];
        final playable = f.isDir || f.isAudio;
        return ListTile(
          leading: Icon(
            f.isDir
                ? Icons.folder_rounded
                : (f.isAudio
                    ? Icons.music_note_rounded
                    : Icons.insert_drive_file_rounded),
            size: 22,
            color: f.isDir
                ? scheme.primary
                : (f.isAudio
                    ? scheme.primary
                    : scheme.onSurfaceVariant.withValues(alpha: 0.4)),
          ),
          title: Text(
            f.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              color: playable
                  ? scheme.onSurface
                  : scheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
          ),
          subtitle: f.isDir || f.size <= 0
              ? null
              : Text(
                  _sizeText(f.size),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
          trailing: !f.isDir && f.isAudio
              ? FutureBuilder<bool>(
                  future: ref
                      .read(downloadProvider.notifier)
                      .isAlreadyDownloaded(_contextFor(f)!.path),
                  initialData: false,
                  builder: (context, snap) => snap.data == true
                      ? Icon(
                          Icons.check_circle_rounded,
                          size: 20,
                          color: scheme.primary,
                        )
                      : IconButton(
                          constraints: const BoxConstraints(),
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            Icons.download_rounded,
                            size: 22,
                            color: scheme.primary,
                          ),
                          tooltip: tr('下载'),
                          onPressed: () => _download(f),
                        ),
                )
              : null,
          onTap: () {
            if (f.isDir) {
              _enter(f);
            } else if (f.isAudio) {
              _play(f);
            }
          },
        );
      },
    );
  }

  Widget _noAccountView(BuildContext context, ColorScheme scheme) {
    return Positioned.fill(
      child: ColoredBox(
        color: scheme.surface.withValues(alpha: 0.96),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 44,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                tr('尚未绑定{name}', {'name': _provider.displayName}),
                style: TextStyle(
                  fontSize: 14,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.push('/cloud'),
                child: Text(tr('去绑定')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
