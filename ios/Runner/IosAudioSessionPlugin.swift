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

    // 蓝牙输出路由事件：蓝牙歌词自动跟随 / 蓝牙接入自动续播的数据源，
    // 与 Android 侧 xianyu/bluetooth_audio EventChannel 同名同载荷
    let btChannel = FlutterEventChannel(
      name: "xianyu/bluetooth_audio", binaryMessenger: registrar.messenger())
    btChannel.setStreamHandler(instance)
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

/// 蓝牙音频输出路由监听。iOS 无 A2DP 连接状态的直接查询 API（那是
/// 配对层面的概念，第三方拿不到），等价信号是 AVAudioSession 输出路由：
/// 路由落到蓝牙端口（A2DP/LE/HFP）即视为「已接入」。
extension IosAudioSessionPlugin: FlutterStreamHandler {
  func bluetoothConnected(_ route: AVAudioSessionRouteDescription?) -> Bool {
    let outputs = route?.outputs ?? AVAudioSession.sharedInstance().currentRoute.outputs
    return outputs.contains {
      $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE
        || $0.portType == .bluetoothHFP
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    let center = NotificationCenter.default
    center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil,
      queue: .main
    ) { _ in
      // 任何路由变化后按当前路由重算接入状态（闭包强持有 plugin
      // 单例，与进程同生命周期；onCancel 时移除观察者）
      events(["connected": self.bluetoothConnected(nil)])
    }
    // 订阅即回报当前状态，与 Dart 侧「启动时探测一次」的预期一致
    events(["connected": bluetoothConnected(nil)])
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NotificationCenter.default.removeObserver(
      self, name: AVAudioSession.routeChangeNotification, object: nil)
    return nil
  }
}
