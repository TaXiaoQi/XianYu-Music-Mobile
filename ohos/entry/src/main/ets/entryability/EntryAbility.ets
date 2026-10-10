
import { FlutterAbility, FlutterEngine, MethodChannel } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { FolderImportChannel } from '../plugins/FolderImportChannel';
import { DeviceInfoChannel } from '../plugins/DeviceInfoChannel';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AbilityConstant, Want } from '@kit.AbilityKit';
import { WatchLinkServerDispatcher } from './WatchLinkServerDispatcher';

export default class EntryAbility extends FlutterAbility {
  private pendingDeepLink: string = '';
  private deepLinkChannel: MethodChannel | null = null;

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // 曲库「导入文件夹」通道：picker 选公共目录 → 物化进沙盒（免权限声明）
    FolderImportChannel.attach(
      flutterEngine.dartExecutor.getBinaryMessenger(), this.context)
    // 设备信息通道：反馈/日志上报带品牌机型与鸿蒙版本号
    DeviceInfoChannel.attach(
      flutterEngine.dartExecutor.getBinaryMessenger(), this.context)
    // 手表联动 SPP 通道（ohos 服务端角色）：协议与安卓 WatchLink.kt
    // 一致（字节管道 + Dart 侧帧/心跳），实机差异见 WatchLinkServerDispatcher。
    WatchLinkServerDispatcher.attach(
      flutterEngine.dartExecutor.getBinaryMessenger(), this.context)
    // xianyu:// 深链桥：协议与 Android MainActivity / iOS SceneDelegate 完全一致 ——
    // Dart → 原生 `getInitialDeepLink`（取冷启动暂存），原生 → Dart `onDeepLink`
    // （运行期投递）。Dart 侧 lib/src/deeplink/deep_link_handler.dart 无需改动。
    this.deepLinkChannel = new MethodChannel(
      flutterEngine.dartExecutor.getBinaryMessenger(), 'xianyu/deeplink');
    this.deepLinkChannel.setMethodCallHandler({
      onMethodCall: (call, result) => {
        if (call.method === 'getInitialDeepLink') {
          result.success(this.pendingDeepLink === '' ? null : this.pendingDeepLink);
          this.pendingDeepLink = '';
        } else {
          result.notImplemented();
        }
      }
    });
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onCreate(want, launchParam)
    // 冷启动带 .js 打开：此刻 Flutter 侧尚未注册 handler，投递会丢失，
    // 暂存 pendingDeepLink 由 Dart 启动时经 getInitialDeepLink 主动拉取。
    this.handleOpenWant(want)
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onNewWant(want, launchParam)
    this.handleOpenWant(want)
  }

  // 文件管理器/浏览器「打开」受支持文件（module.json5 skills 声明
  // general.javascript / general.audio 等 UTD + viewData）：把 want.uri 物化到
  // 沙盒缓存（沙盒副本不随原文件移动/删除失效），按类型封装成与 Android 端
  // MainActivity / iOS SceneDelegate 同构的 xianyu://open 深链，复用 Dart 派发
  // 管线：.js 插件脚本 → target=plugin（导入插件）；.json 主题包 →
  // target=theme（导入并应用）；音频 → target=file（直接播放）。
  private handleOpenWant(want: Want): void {
    const uri = want.uri;
    if (!uri) {
      return;
    }
    const fileName = uri.substring(uri.lastIndexOf('/') + 1);
    const dot = fileName.lastIndexOf('.');
    const ext = dot > 0 ? fileName.substring(dot + 1).toLowerCase() : '';
    const isJs = ext === 'js';
    // .json 主题包：文件管理器「打开」→ 导入并应用（target=theme）。
    // 与 general.javascript（插件）/ general.audio（音频）同一管线。
    const isTheme = ext === 'json';
    if (!isJs && !isTheme && !EntryAbility.audioExtensions.has(ext)) {
      return;
    }
    try {
      const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const dest = `${this.context.cacheDir}/${fileName}`;
      fs.copyFileSync(src.fd, dest);
      fs.closeSync(src.fd);
      const target = isJs ? 'plugin' : isTheme ? 'theme' : 'file';
      const link =
        `xianyu://open?target=${target}&name=${encodeURIComponent(fileName)}` +
        `&file=${encodeURIComponent(dest)}`;
      this.pendingDeepLink = link;
      this.deepLinkChannel?.invokeMethod('onDeepLink', link);
    } catch (e) {
      // 读取失败（无 URI 读权限/云文件未下载等）：静默放弃，不影响正常启动
    }
  }

  // 音频扩展名集合：与桌面端文件关联清单（audioFileAssociations.ts /
  // file_assoc.rs AUDIO_EXTENSIONS）及 Android 端 intent-filter 对齐。
  private static readonly audioExtensions = new Set([
    'aac', 'aif', 'aiff', 'flac', 'm4a', 'm4b', 'mp3', 'mp4', 'oga', 'ogg', 'opus', 'wav',
  ]);
}
