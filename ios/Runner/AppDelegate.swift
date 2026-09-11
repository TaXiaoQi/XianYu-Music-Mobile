import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 冷启动深链兜底：UIScene 生命周期下 URL 主通道是 SceneDelegate 的
    // connectionOptions.urlContexts，部分系统版本仍会写入 launch options。
    // 仅接自有 xianyu:// 深链与「用其他 App 打开」的 .js 插件脚本，
    // 其余 scheme 由插件生命周期代理处理。
    if let url = launchOptions?[.url] as? URL {
      if url.scheme == "xianyu" {
        SceneDelegate.pendingURL = url.absoluteString
      } else if let link = SceneDelegate.deepLinkForOpenedPluginFile(url) {
        SceneDelegate.pendingURL = link
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // iOS 桌面小组件（WidgetKit）+ Live Activity（锁屏/灵动岛歌词）桥。
    IosWidgetPlugin.register(with: engineBridge.pluginRegistry)
  }
}
