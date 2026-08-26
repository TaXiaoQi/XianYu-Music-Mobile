import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../src/core/app_colors.dart';
import '../../src/rust/api.dart' as frb;

/// QMC 独立文件解密页：解密 QQ 音乐加密文件（.qmcflac/.mflac 等）。
class QmcDecryptPage extends ConsumerStatefulWidget {
  const QmcDecryptPage({super.key});

  @override
  ConsumerState<QmcDecryptPage> createState() => _QmcDecryptPageState();
}

enum _DecryptStatus { pending, running, decrypted, notEncrypted, failed }

class _DecryptResult {
  final String fileName;
  final String inputPath;
  String? outputPath;
  _DecryptStatus status = _DecryptStatus.pending;
  String? error;
  String? crypto;
  bool renamed = false;

  _DecryptResult({required this.fileName, required this.inputPath});
}

class _QmcDecryptPageState extends ConsumerState<QmcDecryptPage> {
  final TextEditingController _ekeyCtrl = TextEditingController();
  final List<_DecryptResult> _results = [];
  bool _showEkey = false;
  bool _busy = false;

  @override
  void dispose() {
    _ekeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAndDecrypt() async {
    if (_busy) return;
    final files = await FilePicker.pickFiles(
      type: FileType.any,
    );
    if (files.isEmpty) return;

    // content URI 场景：file_picker 已复制到缓存（path 可用）；无 path 时落盘字节。
    final dir = await getTemporaryDirectory();
    final items = <_DecryptResult>[];
    for (final f in files) {
      String? path = f.path;
      if (path == null || path.isEmpty || !File(path).existsSync()) {
        final bytes = await f.readAsBytes();
        if (bytes.isEmpty) continue;
        final safeName = f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final tmp = File('${dir.path}/$safeName');
        await tmp.writeAsBytes(bytes);
        path = tmp.path;
      }
      items.add(_DecryptResult(
        fileName: f.name.isNotEmpty ? f.name : path.split(RegExp(r'[\\/]')).last,
        inputPath: path,
      ));
    }
    if (items.isEmpty) return;

    setState(() {
      _results
        ..clear()
        ..addAll(items);
      _busy = true;
    });

    final ekey = _ekeyCtrl.text.trim();
    for (final item in items) {
      setState(() => item.status = _DecryptStatus.running);
      try {
        final json = await frb.decryptQmcFileStandalone(
          filePath: item.inputPath,
          ekey: ekey.isEmpty ? null : ekey,
        );
        final map = (jsonDecode(json) as Map).cast<String, dynamic>();
        item.outputPath = map['outputPath'] as String?;
        final status = map['status'] as String? ?? '';
        if (status == 'decrypted') {
          item.status = _DecryptStatus.decrypted;
          item.crypto = map['crypto'] as String?;
          item.renamed = (map['renamedTo'] as String?)?.isNotEmpty ?? false;
        } else {
          item.status = _DecryptStatus.notEncrypted;
        }
      } catch (e) {
        item.status = _DecryptStatus.failed;
        item.error = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      }
      if (mounted) setState(() {});
    }

    setState(() => _busy = false);
  }

  Future<void> _share(_DecryptResult item) async {
    final path = item.outputPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: '已解密：${item.fileName}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(title: const Text('QMC 文件解密')),
      resizeToAvoidBottomInset: false,
      body: RepaintBoundary(
        child: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16,
                120 + MediaQuery.viewInsetsOf(context).bottom),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_open_outlined,
                        size: 20, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '解密 QQ 音乐加密文件（.qmcflac / .qmcmp3 / .mflac / .mmp3 等）。\n'
                        '优先使用文件内置 ekey（QMC2），老格式 .qmc 系列自动用固定密钥（QMC1）；'
                        '解密后自动修正扩展名，可分享保存到任意位置。',
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurfaceVariant,
                            height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (_showEkey) ...[
                TextField(
                  controller: _ekeyCtrl,
                  decoration: InputDecoration(
                    labelText: 'ekey（可选，QMC2 加密密钥）',
                    hintText: '留空则自动从文件尾部提取',
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _pickAndDecrypt,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.folder_open, size: 18),
                      label: Text(_busy ? '解密中…' : '选择文件并解密'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    tooltip: _showEkey ? '隐藏 ekey 输入' : '手动输入 ekey',
                    isSelected: _showEkey,
                    onPressed: () => setState(() => _showEkey = !_showEkey),
                    icon: const Icon(Icons.vpn_key_outlined, size: 20),
                  ),
                ],
              ),
              if (_results.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildSummary(scheme),
                const SizedBox(height: 10),
                for (final item in _results) _buildResultCard(scheme, item),
              ],
            ],
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildSummary(ColorScheme scheme) {
    final ok = _results.where((r) => r.status == _DecryptStatus.decrypted).length;
    final skip = _results
        .where((r) => r.status == _DecryptStatus.notEncrypted)
        .length;
    final fail = _results.where((r) => r.status == _DecryptStatus.failed).length;
    return Text(
      '共 ${_results.length} 个文件：成功 $ok'
      '${skip > 0 ? '，无需解密 $skip' : ''}'
      '${fail > 0 ? '，失败 $fail' : ''}',
      style: TextStyle(
          fontSize: 12.5,
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600),
    );
  }

  Widget _buildResultCard(ColorScheme scheme, _DecryptResult item) {
    final (icon, color, text) = switch (item.status) {
      _DecryptStatus.pending => (Icons.schedule, scheme.outline, '等待解密'),
      _DecryptStatus.running => (Icons.sync, scheme.primary, '解密中…'),
      _DecryptStatus.decrypted => (Icons.check_circle, Colors.green.shade600,
          '解密成功（${item.crypto ?? 'QMC'}${item.renamed ? '，已修正扩展名' : ''}）'),
      _DecryptStatus.notEncrypted =>
        (Icons.info_outline, scheme.outline, '未检测到加密信息（已是普通音频或缺密钥）'),
      _DecryptStatus.failed => (Icons.error_outline, scheme.error, '失败：${item.error ?? '未知错误'}'),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 19, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              if (item.status == _DecryptStatus.decrypted)
                TextButton.icon(
                  onPressed: () => _share(item),
                  icon: const Icon(Icons.share_outlined, size: 17),
                  label: const Text('分享'),
                ),
            ],
          ),
          if (item.renamed &&
              item.status == _DecryptStatus.decrypted &&
              item.outputPath != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 29, right: 8),
              child: Text(
                item.outputPath!.split(RegExp(r'[\\/]')).last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: scheme.outline),
              ),
            )
          else if (item.status != _DecryptStatus.decrypted)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 29, right: 8),
              child: Text(
                text,
                style: TextStyle(fontSize: 11.5, color: color),
              ),
            ),
        ],
      ),
    );
  }
}
