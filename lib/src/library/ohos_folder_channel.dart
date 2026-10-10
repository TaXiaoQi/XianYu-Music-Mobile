import 'package:flutter/services.dart';

/// 鸿蒙曲库「导入文件夹」通道封装（channel: xianyu/ohos_folder）。
///
/// 原生实现见 ohos/.../plugins/FolderImportChannel.ets：DocumentViewPicker
/// 文件夹选择（临时授权、免权限声明）→ 递归列出受支持音频 → 物化（复制）
/// 到应用沙盒。授权仅前台有效，落盘后的沙盒副本走普通曲库扫描，重启可用。
class OhosFolderFile {
  const OhosFolderFile({required this.name, required this.rel});

  /// 文件名（含扩展名）。
  final String name;

  /// 相对 [folderUri] 的路径，以 `/` 开头，可含子目录。
  final String rel;

  factory OhosFolderFile._fromMap(Map<dynamic, dynamic> map) => OhosFolderFile(
        name: map['name'] as String? ?? '',
        rel: map['rel'] as String? ?? '',
      );
}

abstract final class OhosFolderChannel {
  static const MethodChannel _channel = MethodChannel('xianyu/ohos_folder');

  /// 拉起系统文件夹选择器。取消/不支持/失败均返回 null。
  static Future<String?> pickFolder() => _channel.invokeMethod<String>('pickFolder');

  /// 递归列出 [folderUri] 下扩展名命中 [exts] 的音频（不含目录）。
  static Future<List<OhosFolderFile>> listAudioFiles(
    String folderUri,
    List<String> exts,
  ) async {
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'listAudioFiles',
      <String, dynamic>{'folderUri': folderUri, 'exts': exts},
    );
    return [
      for (final e in raw ?? const <dynamic>[])
        OhosFolderFile._fromMap(e as Map<dynamic, dynamic>),
    ];
  }

  /// 把 [files] 对应的授权文件复制进沙盒 [destDir]（保持相对目录结构）。
  /// 返回成功导入的数量。
  static Future<int> importFiles({
    required String folderUri,
    required List<String> rels,
    required String destDir,
  }) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'importFiles',
      <String, dynamic>{
        'folderUri': folderUri,
        'rels': rels,
        'destDir': destDir,
      },
    );
    return (result?['imported'] as num?)?.toInt() ?? 0;
  }

  /// 导出沙盒 [paths] 到授权目录 [folderUri]（「批量移动/导出」第一步）。
  /// 目标已存在同名文件时跳过（不覆盖用户文件）。
  static Future<OhosExportResult> exportFiles({
    required String folderUri,
    required List<String> paths,
  }) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'exportFiles',
      <String, dynamic>{'folderUri': folderUri, 'paths': paths},
    );
    return OhosExportResult(
      exported: (result?['exported'] as num?)?.toInt() ?? 0,
      skipped: [
        for (final f in (result?['skipped'] as List<dynamic>? ?? const []))
          f as String,
      ],
      failed: [
        for (final f in (result?['failed'] as List<dynamic>? ?? const []))
          f as String,
      ],
    );
  }
}

class OhosExportResult {
  const OhosExportResult({
    required this.exported,
    required this.skipped,
    required this.failed,
  });

  final int exported;

  /// 目标已存在同名而被跳过的文件名（不含路径）。
  final List<String> skipped;

  /// 导出失败的文件名（不含路径）。
  final List<String> failed;

  /// 从输入 [paths] 里解出确认导出成功的完整路径（按文件名排除
  /// skipped/failed），移动模式据此决定可安全删除的原件。
  List<String> succeededOf(List<String> paths) {
    String base(String p) => p.substring(p.lastIndexOf('/') + 1);
    return [
      for (final p in paths)
        if (!failed.contains(base(p)) && !skipped.contains(base(p))) p,
    ];
  }
}
