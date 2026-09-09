import Flutter
import UIKit

/// xianyu:// 分享深链桥（iOS 侧）。
///
/// 协议与 Android 端 MainActivity 完全一致：MethodChannel('xianyu/deeplink')，
/// Dart → 原生 `getInitialDeepLink`（取冷启动深链），原生 → Dart `onDeepLink`
/// （运行期投递）。Dart 侧 lib/src/deeplink/deep_link_handler.dart 无需改动。
///
/// UIScene 生命周期下：
/// - 冷启动带 URL 打开：URL 在 connectionOptions.urlContexts（兼容旧 launch
///   options 由 AppDelegate 兜底写入 pendingURL）；
/// - 运行期打开：scene(_:openURLContexts:)。
///
/// 时序说明：Dart 启动即拉 getInitialDeepLink，若通道尚未注册会抛
/// MissingPluginException（Dart 侧已 catch）；通道注册完成后若仍有 pendingURL
/// 会主动 push onDeepLink 兜底，两条路都不会漏也不会重复投递。
class SceneDelegate: FlutterSceneDelegate {

  /// 冷启动暂存的深链 URL（通道就绪后投递并清空）。
  static var pendingURL: String?

  private var channel: FlutterMethodChannel?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    // 冷启动带 URL 打开：UIScene 生命周期下 URL 在 connectionOptions 里。
    if let url = connectionOptions.urlContexts.first?.url {
      SceneDelegate.pendingURL = url.absoluteString
    }
    ensureChannel()
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    // 引擎/窗口晚于场景连接就绪时的兜底（ensureChannel 幂等）。
    ensureChannel()
  }

  // 运行期深链。仅经自有通道转发（当前 iOS 插件均无需 URL 回调，
  // 故不调 super 以规避 FlutterSceneDelegate 未实现该转发导致的编译不确定）。
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else { return }
    ensureChannel()
    let raw = url.absoluteString
    if let ch = channel {
      ch.invokeMethod("onDeepLink", arguments: raw)
    } else {
      SceneDelegate.pendingURL = raw
    }
  }

  /// 建立与 Dart 的深链通道；注册 handler 后投递暂存 URL。幂等。
  private func ensureChannel() {
    guard channel == nil, let vc = flutterViewController() else { return }
    let ch = FlutterMethodChannel(name: "xianyu/deeplink", binaryMessenger: vc.binaryMessenger)
    ch.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getInitialDeepLink":
        result(SceneDelegate.pendingURL)
        SceneDelegate.pendingURL = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
    if let pending = SceneDelegate.pendingURL {
      SceneDelegate.pendingURL = nil
      ch.invokeMethod("onDeepLink", arguments: pending)
    }
  }

  /// 取 FlutterViewController：优先窗口根控制器，退回场景 keyWindow。
  private func flutterViewController() -> FlutterViewController? {
    if let vc = window?.rootViewController as? FlutterViewController {
      return vc
    }
    return (scene as? UIWindowScene)?.keyWindow?.rootViewController
        as? FlutterViewController
  }
}
