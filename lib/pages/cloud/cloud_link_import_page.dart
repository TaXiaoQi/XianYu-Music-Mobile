import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/cloud/share_link_parser.dart';
import '../../src/core/app_colors.dart';
import '../../src/i18n/i18n.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';

/// 分享链接导入页：粘贴链接 → 识别盘 → 解析文件列表 → 播放/转存播放。
///
/// directPlayable 盘（蓝奏/139/夸克等）免转存直链点播；其余盘走
/// transferShareFiles 转存后按我的网盘直链播放（未绑定引导先绑定）。
class CloudLinkImportPage extends ConsumerStatefulWidget {
  const CloudLinkImportPage({super.key});

  @override
  ConsumerState<CloudLinkImportPage> createState() =>
      _CloudLinkImportPageState();
}

class _CloudLinkImportPageState extends ConsumerState<CloudLinkImportPage> {
  final _urlCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  bool _parsing = false;
  bool _transferring = false;
  CloudProvider? _provider;
  CloudShareParse? _share;

  @override
  void initState() {
    super.initState();
    _readClipboard();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  /// 进入页面时探测剪贴板：内容可识别为网盘分享链接则自动填充。
  Future<void> _readClipboard() async {
    try {
      final text = (await Clipboard.getData('text/plain'))?.text?.trim() ?? '';
      if (text.isEmpty || !mounted) return;
      if (parseUrlToProvider(text) != null) {
        setState(() => _urlCtrl.text = text);
      }
    } catch (_) {
      // 剪贴板不可用静默忽略。
    }
  }

  Future<void> _parse() async {
    if (_parsing) return;
    final info = parseUrlToProvider(_urlCtrl.text);
    if (info == null) {
      showXianYuToast(context, tr('未识别的分享链接'));
      return;
    }
    final provider = cloudProviderById(info.providerId);
    if (provider == null) {
      showXianYuToast(context, tr('该网盘暂未支持'));
      return;
    }
    setState(() => _parsing = true);
    try {
      final pwd = _pwdCtrl.text.trim();
      final share = await provider.parseShareLink(info.url, pwd.isEmpty ? null : pwd);
      if (!mounted) return;
      if (share.files.isEmpty) {
        showXianYuToast(context, tr('分享内没有文件'));
      }
      setState(() {
        _provider = provider;
        _share = share;
        _parsing = false;
      });
    } catch (e) {
      if (!mounted) return;
      showXianYuToast(
        context,
        e is CloudException ? e.message : tr('分享链接解析失败'),
      );
      setState(() => _parsing = false);
    }
  }

  Future<void> _playFile(CloudFile f) async {
    final provider = _provider;
    final share = _share;
    if (provider == null || share == null || _transferring) return;
    final accounts =
        await CloudCredentialsStore.instance.accountsFor(provider.id);

    if (share.directPlayable) {
      // 免转存直链：已绑账号用其凭据，未绑定也允许（免登录通道）。
      final ctx = CloudPlayContext(
        provider: provider.id,
        accountId: accounts.isEmpty ? '_' : accounts.first.accountId,
        file: f,
        share: share,
      );
      await ref
          .read(playerProvider.notifier)
          .playQueue([cloudPlayQueueItem(ctx, artist: provider.displayName)],
              startIndex: 0);
      return;
    }

    // 需转存：必须已绑定。
    if (accounts.isEmpty) {
      if (!mounted) return;
      showXianYuToast(context, tr('请先绑定{name}', {'name': provider.displayName}));
      return;
    }
    final account = accounts.first;
    setState(() => _transferring = true);
    try {
      final transferred =
          await provider.transferShareFiles(account.cred, share);
      if (!mounted) return;
      final audioFiles = transferred.where((x) => x.isAudio).toList();
      if (audioFiles.isEmpty) {
        showXianYuToast(context, tr('分享内没有音频文件'));
        return;
      }
      var start = audioFiles.indexWhere((x) => x.name == f.name);
      if (start < 0) start = 0;
      final items = [
        for (final x in audioFiles)
          cloudPlayQueueItem(
            CloudPlayContext(
              provider: provider.id,
              accountId: account.accountId,
              file: x,
            ),
            artist: provider.displayName,
          ),
      ];
      await ref
          .read(playerProvider.notifier)
          .playQueue(items, startIndex: start);
    } catch (e) {
      if (!mounted) return;
      showXianYuToast(
        context,
        e is CloudException ? e.message : tr('转存失败，请重试'),
      );
    } finally {
      if (mounted) setState(() => _transferring = false);
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
          ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              GlassTopBar.height(context),
              16,
              40 + MediaQuery.of(context).padding.bottom,
            ),
            children: [
              TextField(
                controller: _urlCtrl,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: tr('粘贴网盘分享链接'),
                  isDense: true,
                  filled: true,
                  fillColor: scheme.onSurface.withValues(alpha: 0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pwdCtrl,
                      autocorrect: false,
                      decoration: InputDecoration(
                        hintText: tr('提取码（选填）'),
                        isDense: true,
                        filled: true,
                        fillColor: scheme.onSurface.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _parsing ? null : _parse,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                    ),
                    child: _parsing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(tr('解析')),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ..._result(context, scheme),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(tr('分享链接导入')),
            ),
          ),
          if (_transferring)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black26,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _result(BuildContext context, ColorScheme scheme) {
    final provider = _provider;
    final share = _share;
    if (provider == null || share == null) return const [];
    return [
      Row(
        children: [
          Text(
            provider.displayName,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          if (share.directPlayable)
            Text(
              tr('免转存播放'),
              style: TextStyle(fontSize: 11, color: scheme.primary),
            )
          else
            Text(
              tr('需转存后播放'),
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
        ],
      ),
      const SizedBox(height: 6),
      for (final f in share.files)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            f.isDir
                ? Icons.folder_rounded
                : (f.isAudio
                    ? Icons.music_note_rounded
                    : Icons.insert_drive_file_rounded),
            size: 22,
            color: f.isAudio
                ? scheme.primary
                : scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          title: Text(
            f.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14),
          ),
          subtitle: f.isDir
              ? Text(
                  tr('文件夹'),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                )
              : null,
          trailing: f.isAudio
              ? Icon(
                  Icons.play_circle_outline_rounded,
                  size: 22,
                  color: scheme.primary,
                )
              : null,
          onTap: f.isAudio ? () => _playFile(f) : null,
        ),
    ];
  }
}
