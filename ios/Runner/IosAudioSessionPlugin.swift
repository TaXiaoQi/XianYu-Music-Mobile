import AVFoundation
import Flutter

/// iOS 音频会话偏好桥（Apple Music 路线）：输出路由与混音全部交给系统
/// （AVAudioSession），App 不碰设备、不做独占；仅把源采样率作为「偏好」
/// 提交给系统——外接 DAC 时系统尽量贴近源规格，内建扬声器按硬件上限执行。
/// 这是 iOS 上唯一合法的「逼近直出」手段（Apple Music 24/192 外接 DAC 同款）。
///
/// DSP 管线模式（Rust coreaudio 后端）配合：
/// - `configurePipeline`：起播前强制 `.playback` category + 激活会话
///   （AURemoteIO 输出流要求会话处于激活状态，且 .playback 不受静音键影响）；
/// - `releasePipeline`：管线停止后按需让出会话（notifyOthersOnDeactivation）；
/// - 中断/路由变化经本通道 invokeMethod 回传 Dart（"onPipelineInterruption" /
///   "onPipelineRouteChanged"）。audio_session 插件的 interruption 流在 iOS
///   同样会投递中断事件，Dart 侧两条信号路径均做幂等处理。
@objc class IosAudioSessionPlugin: NSObject {
  private static var pipelineChannel: FlutterMethodChannel?

  static func register(with registrar: any FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "xianyu/ios_audio", binaryMessenger: registrar.messenger())
    let instance = IosAudioSessionPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    pipelineChannel = channel

    // 蓝牙输出路由事件：蓝牙歌词自动跟随 / 蓝牙接入自动续播的数据源，
    // 与 Android 侧 xianyu/bluetooth_audio EventChannel 同名同载荷
    let btChannel = FlutterEventChannel(
      name: "xianyu/bluetooth_audio", binaryMessenger: registrar.messenger())
    btChannel.setStreamHandler(instance)

    instance.observePipelineEvents()
  }

  // MARK: - DSP 管线会话管理

  /// 管线起播前的会话准备：.playback category（后台可播、不受静音键影响）、
  /// 采样率偏好、激活。重复调用幂等（setCategory 重复设置无害）。
  private func configurePipeline(_ args: [String: Any], result: @escaping FlutterResult) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [])
      if let rate = args["rate"] as? Double, rate > 0 {
        try session.setPreferredSampleRate(rate)
      }
      try session.setActive(true)
      // Dart 侧 invokeMethod<int>：只回传系统实际输出采样率
      result(Int(session.sampleRate))
    } catch {
      result(FlutterError(code: "ios_audio_session", message: error.localizedDescription, details: nil))
    }
  }

  /// 管线停止后的会话释放：让出音频焦点并通知其他 App 可恢复播放。
  private func releasePipeline(result: @escaping FlutterResult) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setActive(false, options: .notifyOthersOnDeactivation)
      result(true)
    } catch {
      // 让出失败不影响（下一段播放会重新激活），降级为成功
      result(false)
    }
  }

  // MARK: - 中断 / 路由事件回传 Dart

  /// 常驻观察者：中断与路由变化转发到 Dart（仅 DSP 管线消费这些事件；
  /// audio_session 插件在 iOS 也投递中断，Dart 侧做幂等去重）。
  private func observePipelineEvents() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard
        let info = note.userInfo,
        let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
      else { return }
      var extra: [String: Any] = ["began": type == .began]
      if type == .ended,
        let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt
      {
        let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
        extra["shouldResume"] = opts.contains(.shouldResume)
      }
      self?.notifyDart("onPipelineInterruption", extra)
    }
    center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard
        let info = note.userInfo,
        let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
      else { return }
      // oldDeviceUnavailable = 拔掉耳机/断开蓝牙（becomingNoisy 等价信号）
      let oldUnavailable = reason == .oldDeviceUnavailable
      let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }
      self?.notifyDart(
        "onPipelineRouteChanged",
        ["oldDeviceUnavailable": oldUnavailable, "outputs": outputs])
    }
  }

  private func notifyDart(_ method: String, _ args: [String: Any]) {
    Self.pipelineChannel?.invokeMethod(method, arguments: args)
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
    case "configurePipeline":
      configurePipeline(call.arguments as? [String: Any] ?? [:], result: result)
    case "releasePipeline":
      releasePipeline(result: result)
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
