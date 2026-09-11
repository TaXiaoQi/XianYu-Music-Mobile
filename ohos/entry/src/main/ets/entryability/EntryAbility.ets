
import { FlutterAbility, FlutterEngine, MethodChannel } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AbilityConstant, Want } from '@kit.AbilityKit';

export default class EntryAbility extends FlutterAbility {
  private pendingDeepLink: string = '';
  private deepLinkChannel: MethodChannel | null = null;

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
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

  // 文件管理器/浏览器「打开」.js 插件脚本（module.json5 skills 声明
  // general.javascript + viewData）：把 want.uri 物化到沙盒缓存（沙盒副本
  // 不随原文件移动/删除失效），封装成 xianyu://open?target=plugin 深链，
  // 复用 Dart 侧统一的插件导入管线（LX/MusicFree 自动识别 + 安装校验）。
  private handleOpenWant(want: Want): void {
    const uri = want.uri;
    if (!uri || !uri.toLowerCase().endsWith('.js')) {
      return;
    }
    try {
      const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const fileName = uri.substring(uri.lastIndexOf('/') + 1) || 'plugin.js';
      const dest = `${this.context.cacheDir}/${fileName}`;
      fs.copyFileSync(src.fd, dest);
      fs.closeSync(src.fd);
      const link =
        `xianyu://open?target=plugin&name=${encodeURIComponent(fileName)}` +
        `&file=${encodeURIComponent(dest)}`;
      this.pendingDeepLink = link;
      this.deepLinkChannel?.invokeMethod('onDeepLink', link);
    } catch (e) {
      // 读取失败（无 URI 读权限/云文件未下载等）：静默放弃，不影响正常启动
    }
  }
}
