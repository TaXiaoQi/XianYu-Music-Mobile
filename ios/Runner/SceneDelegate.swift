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
    // 自有 xianyu:// 深链进分享链解析；「用其他 App 打开」的受支持文件
    // （.js 插件脚本 / 音频）物化后并入同一派发链；其余 scheme（如 QQ 回调
    // tencent{appid}://）由 super 转发给插件生命周期代理，不进分享链解析。
    if let url = connectionOptions.urlContexts.first?.url {
      if url.scheme == "xianyu" {
        SceneDelegate.pendingURL = url.absoluteString
      } else if let link = Self.deepLinkForOpenedFile(url) {
        SceneDelegate.pendingURL = link
      }
    }
    ensureChannel()
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    // 引擎/窗口晚于场景连接就绪时的兜底（ensureChannel 幂等）。
    ensureChannel()
  }

  // 运行期深链/URL 回调。super.scene(_:openURLContexts:)（Flutter 3.47+
  // FlutterSceneDelegate 已实现）会把全部 URL 扇出给插件生命周期代理
  // （FlutterPluginSceneLifeCycleDelegate），tencent_kit 据此接收 QQ 分享回调
  // （tencent{appid}:// scheme 与 /qq_conn/ Universal Link）。
  // 自有通道只接 xianyu:// 深链与「用其他 App 打开」的受支持文件
  // （.js 插件脚本 / 音频），避免 QQ 回调误入分享深链解析。
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    guard let url = URLContexts.first?.url else { return }
    ensureChannel()
    if let link = Self.deepLinkForOpenedFile(url) {
      dispatchDeepLink(link)
      return
    }
    guard url.scheme == "xianyu" else { return }
    dispatchDeepLink(url.absoluteString)
  }

  /// 统一深链投递：通道已注册直接推 onDeepLink，否则暂存待 ensureChannel 兜底。
  private func dispatchDeepLink(_ raw: String) {
    if let ch = channel {
      ch.invokeMethod("onDeepLink", arguments: raw)
    } else {
      SceneDelegate.pendingURL = raw
    }
  }

  /// 系统把受支持文件交给本应用打开（文件 App「分享/用其他 App 打开」，经
  /// Info.plist CFBundleDocumentTypes 声明）：物化到沙盒 tmp（沙盒外文件被
  /// 移动/删除后副本仍可用），按类型封装成与 Android 端 MainActivity 同构的
  /// xianyu://open 深链，复用 Dart 派发管线：
  /// - .js 插件脚本 → target=plugin（导入插件）；
  /// - 音频文件 → target=file（直接播放）。
  /// 非受支持文件返回 nil，交回原有 scheme 分流。
  static func deepLinkForOpenedFile(_ url: URL) -> String? {
    let ext = url.pathExtension.lowercased()
    guard ext == "js" || Self.audioExtensions.contains(ext) else { return nil }
    let name = url.lastPathComponent
    let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    try? FileManager.default.removeItem(at: dest)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      try FileManager.default.copyItem(at: url, to: dest)
    } catch {
      return nil
    }
    func enc(_ s: String) -> String {
      s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
    let target = ext == "js" ? "plugin" : "file"
    return "xianyu://open?target=\(target)&name=\(enc(name))&file=\(enc(dest.path))"
  }

  /// 音频扩展名集合：与桌面端文件关联清单（audioFileAssociations.ts /
  /// file_assoc.rs AUDIO_EXTENSIONS）对齐，另含 Android 端 intent-filter
  /// 已注册的 opus。iOS 侧声明见 Info.plist CFBundleDocumentTypes。
  private static let audioExtensions: Set<String> = [
    "aac", "aif", "aiff", "flac", "m4a", "m4b", "mp3", "mp4", "oga", "ogg", "opus", "wav",
  ]

  /// Universal Link（QQ 分享回调 /qq_conn/ 路径）：转发插件生命周期代理。
  /// 冷启动经 UL 拉起时 connectionOptions.userActivities 由 super 自行处理。
  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    super.scene(scene, continue: userActivity)
  }

  /// 建立与 Dart 的深链通道；注册 handler 后投递暂存 URL。幂等。
  private func ensureChannel() {
    ensureDeviceInfoChannel()
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

  /// 注册 xianyu/device_info 通道（与 Android 端同名通道协议一致），
  /// 提供 Keychain 持久化的设备稳定 ID 与设备信息：卸载重装不变（仅抹机才清除）。
  private func ensureDeviceInfoChannel() {
    guard !deviceInfoChannelRegistered, let vc = flutterViewController() else { return }
    deviceInfoChannelRegistered = true
    let ch = FlutterMethodChannel(name: "xianyu/device_info", binaryMessenger: vc.binaryMessenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "getStableDeviceId":
        result(Self.keychainStableDeviceId())
      // 设备信息（JSON 字符串，字段与 Android 端 getDeviceInfo 一致）：
      // brand/manufacturer 固定 Apple，model 取 utsname machine（如 iPhone16,2），
      // os_version 如 "iOS 18.1"，market_name iOS 无对应概念留空
      case "getDeviceInfo":
        result(Self.deviceInfoJson())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 采集 iOS 设备信息，序列化为 JSON 字符串。
  private static func deviceInfoJson() -> String {
    var sys = utsname()
    uname(&sys)
    let machine = withUnsafeBytes(of: &sys.machine) { buf -> String in
      let chars = buf.prefix(while: { $0 != 0 }).compactMap { UnicodeScalar($0) }
      return String(String.UnicodeScalarView(chars))
    }
    let json: [String: String] = [
      "brand": "Apple",
      "manufacturer": "Apple",
      "model": machine.isEmpty ? UIDevice.current.model : machine,
      "market_name": "",
      "os_version": "iOS " + UIDevice.current.systemVersion,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: json) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }

  /// Keychain 稳定设备 ID：首次生成 UUID 写入 Keychain（ThisDeviceOnly，
  /// 不随备份迁移到其他设备），此后所有读取直接命中，卸载重装不丢。
  private static func keychainStableDeviceId() -> String {
    let service = "com.xianyumusic.app.deviceid"
    let account = "stable_id"
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess,
       let data = item as? Data,
       let existing = String(data: data, encoding: .utf8),
       !existing.isEmpty {
      return existing
    }
    guard status == errSecItemNotFound else { return "" }
    let id = UUID().uuidString.lowercased()
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: id.data(using: .utf8) as Any,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    return addStatus == errSecSuccess ? id : ""
  }
}
