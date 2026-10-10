import {
  BinaryMessenger,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

// ArkTS 禁止 any/unknown（arkts-no-any-unknown），返回结构用显式
// interface 声明（对象字面量带显式类型即合法）。
interface ImportResult {
  imported: number;
  failed: string[];
}

interface ExportResult {
  exported: number;
  skipped: string[];
  failed: string[];
}

const TAG = 'FolderImportChannel';

/**
 * 鸿蒙曲库「导入文件夹」通道（channel: xianyu/ohos_folder）。
 *
 * 职责：DocumentViewPicker 文件夹选择（selectMode=FOLDER，临时授权、
 * 免权限声明）→ 递归列出受支持音频 → 物化（复制）到应用沙盒。
 * 授权仅存活于前台，复制完成后不再依赖授权；重启重扫扫的是沙盒副本，
 * 因此不做持久化授权（FILE_ACCESS_PERSIST）。
 *
 * 协议对应 Dart 侧 lib/src/library/ohos_folder_channel.dart：
 * - pickFolder → string?（取消/不支持/失败均 null）
 * - listAudioFiles(folderUri, exts) → [{name, rel}]（rel 以 / 开头的相对路径）
 * - importFiles(folderUri, rels[], destDir) → {imported, failed}
 *   （保持相对目录结构落盘，沙盒递归扫描天然兼容）
 * - exportFiles(folderUri, paths[]) → {exported, skipped, failed}
 *   （沙盒真实路径 → 授权目录子文件 uri；目标已存在跳过不覆盖）
 */
export class FolderImportChannel {
  static attach(messenger: BinaryMessenger, context: common.UIAbilityContext): void {
    const channel = new MethodChannel(messenger, 'xianyu/ohos_folder');
    channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        switch (call.method) {
          case 'pickFolder':
            FolderImportChannel.pickFolder(context, result);
            break;
          case 'listAudioFiles':
            FolderImportChannel.listAudioFiles(call, result);
            break;
          case 'importFiles':
            FolderImportChannel.importFiles(call, result);
            break;
          case 'exportFiles':
            FolderImportChannel.exportFiles(call, result);
            break;
          default:
            result.notImplemented();
        }
      },
    });
  }

  private static pickFolder(context: common.UIAbilityContext, result: MethodResult): void {
    if (!canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
      Log.w(TAG, 'FolderSelection syscap not supported');
      result.success(null);
      return;
    }
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1; // 目录选择单次仅 1 个（API 23 起才放开）
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    const documentPicker = new picker.DocumentViewPicker(context);
    documentPicker.select(options).then((uris: string[]) => {
      result.success(uris != null && uris.length > 0 ? uris[0] : null);
    }).catch((err: BusinessError<Error>) => {
      // 用户取消（13900042?）/拉起失败一律静默回 null，与 Android SAF 取消语义一致
      Log.w(TAG, `pickFolder failed: code=${err.code} msg=${err.message}`);
      result.success(null);
    });
  }

  private static listAudioFiles(call: MethodCall, result: MethodResult): void {
    const uri: string = call.argument('folderUri') as string;
    const exts: string[] = call.argument('exts') as string[];
    const extSet: Set<string> = new Set((exts ?? []).map((e: string): string => e.toLowerCase()));
    // listFileSync 的 File 重载在当前 SDK 不可用（仅 string path），
    // 直接传 picker 授权 uri。
    try {
      const rels: string[] = fs.listFileSync(uri, { recursion: true });
      // ArkTS 禁止无类型对象字面量（arkts-no-untyped-obj-literals），
      // 条目用 Map<string, string> 表达（Dart 侧同为 Map，协议不变）。
      const out: Array<Map<string, string>> = [];
      for (const rel of rels) {
        const name: string = rel.substring(rel.lastIndexOf('/') + 1);
        const dot = name.lastIndexOf('.');
        const ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
        if (!extSet.has(ext)) {
          continue;
        }
        const item = new Map<string, string>();
        item.set('name', name);
        item.set('rel', rel);
        out.push(item);
      }
      result.success(out);
    } catch (e) {
      Log.e(TAG, `listAudioFiles failed: ${e}`);
      result.error('LIST_FAILED', `${e}`, null);
    }
  }

  private static importFiles(call: MethodCall, result: MethodResult): void {
    const folderUri: string = call.argument('folderUri') as string;
    const rels: string[] = call.argument('rels') as string[];
    const destDir: string = call.argument('destDir') as string;
    try {
      fs.mkdirSync(destDir, true);
    } catch (_) {
      // 已存在则忽略
    }
    let imported = 0;
    const failed: string[] = [];
    for (const rel of rels) {
      const name: string = rel.substring(rel.lastIndexOf('/') + 1);
      const destPath = `${destDir}${rel}`;
      const parent = destPath.substring(0, destPath.lastIndexOf('/'));
      if (parent.length > 0 && parent !== destDir) {
        try {
          fs.mkdirSync(parent, true);
        } catch (_) {
          // 已存在则忽略
        }
      }
      let src: fs.File | null = null;
      try {
        src = fs.openSync(FolderImportChannel.childUri(folderUri, rel), fs.OpenMode.READ_ONLY);
        fs.copyFileSync(src.fd, destPath);
        imported++;
      } catch (e) {
        Log.e(TAG, `copy ${rel} failed: ${e}`);
        failed.push(name);
      } finally {
        if (src != null) {
          try {
            fs.closeSync(src);
          } catch (_) {
            // ignore
          }
        }
      }
    }
    const done: ImportResult = { imported, failed };
    result.success(done);
  }

  // picker 返回的 folderUri 各段已 URL 编码，而 listFile 返回的相对路径是
  // 原始文件名（中文/空格未编码），子文件 uri 需对每段重新编码后拼接。
  private static childUri(folderUri: string, rel: string): string {
    const segs: string[] = rel.split('/').filter((s: string): boolean => s.length > 0);
    const encoded: string = segs.map((s: string): string => encodeURIComponent(s)).join('/');
    return `${folderUri}/${encoded}`;
  }

  /**
   * 导出沙盒文件到 picker 授权目录（「批量移动/导出」）。
   * src 为沙盒真实路径，dest 为授权目录下子文件 uri。目标已存在时：
   * 大小一致视为同一内容（此前导出的副本）→ 计入 exported（不重复复制，
   * 调用方可据此删原件实现重复「移动」）；大小不一致 → skipped 防误覆盖。
   * 复制失败进 failed。skipped/failed 均为文件名名单（调用方据此确定
   * 可安全删除原件的成功集合）。协议：{exported, skipped[], failed[]}。
   */
  private static exportFiles(call: MethodCall, result: MethodResult): void {
    const folderUri: string = call.argument('folderUri') as string;
    const paths: string[] = call.argument('paths') as string[];
    let exported = 0;
    const skipped: string[] = [];
    const failed: string[] = [];
    for (const p of paths) {
      const name: string = p.substring(p.lastIndexOf('/') + 1);
      const dest = `${folderUri}/${encodeURIComponent(name)}`;
      let exists = false;
      try {
        fs.accessSync(dest);
        exists = true;
      } catch (_) {
        // 不存在 → 正常导出
      }
      if (exists) {
        let same = false;
        try {
          same = fs.statSync(p).size === fs.statSync(dest).size;
        } catch (_) {
          same = false;
        }
        if (same) {
          exported++;
        } else {
          skipped.push(name);
        }
        continue;
      }
      try {
        fs.copyFileSync(p, dest);
        exported++;
      } catch (e) {
        Log.e(TAG, `export ${name} failed: ${e}`);
        failed.push(name);
      }
    }
    const done: ExportResult = { exported, skipped, failed };
    result.success(done);
  }
}
