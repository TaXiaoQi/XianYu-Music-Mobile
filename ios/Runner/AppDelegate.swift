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
    if let url = launchOptions?[.url] as? URL {
      SceneDelegate.pendingURL = url.absoluteString
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // iOS 桌面小组件（WidgetKit）+ Live Activity（锁屏/灵动岛歌词）桥。
    IosWidgetPlugin.register(with: engineBridge.pluginRegistry)
  }
}
