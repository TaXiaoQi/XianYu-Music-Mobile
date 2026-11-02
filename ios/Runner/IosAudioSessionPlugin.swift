import AVFoundation
import Flutter

/// iOS 音频会话偏好桥（Apple Music 路线）：输出路由与混音全部交给系统
/// （AVAudioSession），App 不碰设备、不做独占；仅把源采样率作为「偏好」
/// 提交给系统——外接 DAC 时系统尽量贴近源规格，内建扬声器按硬件上限执行。
/// 这是 iOS 上唯一合法的「逼近直出」手段（Apple Music 24/192 外接 DAC 同款）。
@objc class IosAudioSessionPlugin: NSObject {
  static func register(with registrar: any FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "xianyu/ios_audio", binaryMessenger: registrar.messenger())
    let instance = IosAudioSessionPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }
}

extension IosAudioSessionPlugin: FlutterPlugin {
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setPreferredSampleRate":
      guard
        let args = call.arguments as? [String: Any],
        let rate = args["rate"] as? Double, rate > 0
      else {
        result(nil)
        return
      }
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setPreferredSampleRate(rate)
        // 返回系统当前实际输出采样率，供日志对照（偏好≠保证）
        result(Int(session.sampleRate))
      } catch {
        // 个别会话配置下可能抛错，降级为「未生效」，不影响播放
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
