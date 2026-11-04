import Flutter
import UIKit
import UniformTypeIdentifiers

/// iOS 文件夹书签桥：文档选择器选目录 → security-scoped bookmark 持久授权。
/// 扫描/播放前用书签解析并 startAccessing（进程级作用域，保持到会话结束），
/// 由此 Rust 扫描器与播放器可直接按路径读取沙盒外目录。
@objc class IosFolderPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private static var pendingResult: FlutterResult?
  private static var accessedURLs: [URL] = []
  private static let shared = IosFolderPlugin()

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "xianyu/ios_folder",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(shared, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickFolder":
      DispatchQueue.main.async { Self.presentFolderPicker(result) }
    case "startAccess":
      guard let args = call.arguments as? [String: Any],
            let b64 = args["bookmark"] as? String,
            let data = Data(base64Encoded: b64) else {
        result(nil)
        return
      }
      var stale = false
      do {
        // iOS 上书签创建/解析均不带 withSecurityScope 选项（macOS 专属），
        // 安全作用域由解析后 startAccessingSecurityScopedResource 显式拉起。
        let url = try URL(
          resolvingBookmarkData: data,
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        )
        let granted = url.startAccessingSecurityScopedResource()
        if granted,
           !Self.accessedURLs.contains(where: { $0 == url }) {
          Self.accessedURLs.append(url)
        }
        result(["path": url.path, "stale": stale, "granted": granted])
      } catch {
        result(nil)
      }
    case "stopAccess":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(nil)
        return
      }
      Self.accessedURLs.removeAll { url in
        if url.path == path {
          url.stopAccessingSecurityScopedResource()
          return true
        }
        return false
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func presentFolderPicker(_ result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(nil)
      return
    }
    pendingResult = result
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.folder],
      asCopy: false
    )
    picker.allowsMultipleSelection = false
    picker.delegate = shared
    let scenes = UIApplication.shared.connectedScenes.compactMap {
      $0 as? UIWindowScene
    }
    var root = scenes.first(where: { $0.activationState == .foregroundActive })?
      .keyWindow?.rootViewController
      ?? scenes.first?.keyWindow?.rootViewController
    while let presented = root?.presentedViewController {
      root = presented
    }
    if let root {
      root.present(picker, animated: true)
    } else {
      pendingResult = nil
      result(nil)
    }
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let result = Self.pendingResult else { return }
    Self.pendingResult = nil
    guard let url = urls.first else {
      result(nil)
      return
    }
    do {
      let data = try url.bookmarkData()
      result(["path": url.path, "bookmark": data.base64EncodedString()])
    } catch {
      result(nil)
    }
  }

  func documentPickerWasCancelled(
    _ controller: UIDocumentPickerViewController
  ) {
    if let result = Self.pendingResult {
      Self.pendingResult = nil
      result(nil)
    }
  }
}
