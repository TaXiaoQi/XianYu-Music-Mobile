import AVFoundation
import AVKit
import CoreText
import Flutter

/// iOS 桌面歌词（画中画路线，网易云/QQ 音乐同款实现）。
///
/// iOS 不允许第三方 App 建系统级悬浮窗（Android 的 SYSTEM_ALERT_WINDOW
/// 无等价物），唯一合法的跨应用悬浮手段是 Picture-in-Picture：把歌词行
/// 渲染成 BGRA 视频帧喂给 AVSampleBufferDisplayLayer，经
/// AVPictureInPictureController 驱动系统 PiP 小窗——悬浮在桌面与其他
/// App 上层、可拖动/双指缩放，位置尺寸由系统管理（锁定/边距设置不适用）。
///
/// 通道协议与 Android 完全镜像（xianyu/floating_lyrics + ..._events），
/// Dart 侧 FloatingLyricsController 无平台分支：
/// - show/hide：启停 PiP
/// - setSettings/setLyrics/setPlayback：样式、歌词全文（含时间轴）、播放态
/// - 事件回传：onTogglePlayback（PiP 播放/暂停按钮）、onClosed（PiP 关闭钮）
///
/// 约束：PiP 会话存活依赖音频后台播放（UIBackgroundModes=audio 已配置）；
/// 自定义 sample-buffer PiP 需 iOS 15+，低版本静默不启用。
@objc class IosFloatingLyricsPlugin: NSObject {
  private static let canvasW = 1280
  private static let canvasH = 320

  private var channel: FlutterMethodChannel?
  private var eventsChannel: FlutterMethodChannel?

  // PiP 管线
  private var displayLayer: AVSampleBufferDisplayLayer?
  private var pipController: AVPictureInPictureController?
  private lazy var playbackDelegate = LyricsPlaybackDelegate(owner: self)

  // 渲染状态（Dart 推送）
  private struct OverlayLine {
    let startMs: Int
    let endMs: Int
    let text: String
    let translation: String?
    let romaji: String?
  }

  private struct OverlaySettings {
    var textColor: UInt32 = 0xFFFFFFFF
    var unplayedColor: UInt32 = 0
    var opacity: Double = 1.0
    var fontScale: Double = 1.0
    var secondaryScale: Double = 1.0
    var showTranslation = true
    var showNextLine = false
    var showRomanization = false
    var showBackground = true
    var hideWhenPaused = false
    var lyricFontPath: String?
  }

  private var settings = OverlaySettings()
  private var lines: [OverlayLine] = []
  private var basePositionMs = 0
  private var baseStampMs = 0  // CMClock host time ms，与 basePositionMs 配对
  private var playing = false
  private var lastRenderedKey = ""
  private var customFont: CTFont?
  private var renderTimer: DispatchSourceTimer?

  static func register(with registrar: any FlutterPluginRegistrar) {
    let instance = IosFloatingLyricsPlugin()
    instance.channel = FlutterMethodChannel(
      name: "xianyu/floating_lyrics", binaryMessenger: registrar.messenger())
    instance.eventsChannel = FlutterMethodChannel(
      name: "xianyu/floating_lyrics_events", binaryMessenger: registrar.messenger())
    instance.channel?.setMethodCallHandler(instance.handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "show":
      // 悬浮窗权限是 Android 概念，iOS PiP 无需授权
      startPip()
      result(true)
    case "hide":
      stopPip()
      result(true)
    case "setSettings":
      if let args = call.arguments as? [String: Any],
        let json = args["json"] as? String,
        let data = json.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        applySettings(obj)
      }
      result(true)
    case "setLyrics":
      if let args = call.arguments as? [String: Any],
        let json = args["json"] as? String,
        let data = json.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        applyLyrics(obj)
      }
      result(true)
    case "setPlayback":
      if let args = call.arguments as? [String: Any] {
        basePositionMs = (args["positionMs"] as? Int) ?? 0
        baseStampMs = Int(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1000)
        let newPlaying = (args["isPlaying"] as? Bool) ?? false
        if playing != newPlaying {
          playing = newPlaying
          lastRenderedKey = ""  // 播放态变化强制重绘
        }
      }
      result(true)
    case "setLocked":
      // PiP 窗口由系统管理拖动，无位置锁定概念
      result(true)
    case "isPermissionGranted":
      result(true)
    case "openPermissionSettings":
      result(true)
    case "resetPosition":
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 状态接收

  private func applySettings(_ o: [String: Any]) {
    var s = settings
    if let v = o["textColor"] as? Int { s.textColor = UInt32(bitPattern: Int32(truncatingIfNeeded: v)) }
    if let v = o["unplayedColor"] as? Int { s.unplayedColor = UInt32(bitPattern: Int32(truncatingIfNeeded: v)) }
    if let v = o["opacity"] as? Double { s.opacity = v }
    if let v = o["fontScale"] as? Double { s.fontScale = v }
    if let v = o["secondaryScale"] as? Double { s.secondaryScale = v }
    if let v = o["showTranslation"] as? Bool { s.showTranslation = v }
    if let v = o["showNextLine"] as? Bool { s.showNextLine = v }
    if let v = o["showRomanization"] as? Bool { s.showRomanization = v }
    if let v = o["showBackground"] as? Bool { s.showBackground = v }
    if let v = o["hideWhenPaused"] as? Bool { s.hideWhenPaused = v }
    if let v = o["lyricFontPath"] as? String { s.lyricFontPath = v.isEmpty ? nil : v }
    settings = s
    reloadCustomFont()
    lastRenderedKey = ""
  }

  private func reloadCustomFont() {
    customFont = nil
    guard let path = settings.lyricFontPath else { return }
    let url = URL(fileURLWithPath: path)
    guard let provider = CGDataProvider(url: url as CFURL),
      let cgFont = CGFont(provider)
    else { return }
    customFont = CTFontCreateWithGraphicsFont(cgFont, 60, nil, nil)
  }

  private func applyLyrics(_ o: [String: Any]) {
    var parsed: [OverlayLine] = []
    if let arr = o["lines"] as? [[String: Any]] {
      for it in arr {
        guard let text = it["text"] as? String,
          let start = it["startMs"] as? Int
        else { continue }
        parsed.append(
          OverlayLine(
            startMs: start,
            endMs: (it["endMs"] as? Int) ?? start,
            text: text,
            translation: it["translation"] as? String,
            romaji: it["romaji"] as? String))
      }
    }
    lines = parsed
    lastRenderedKey = ""
  }

  // MARK: - PiP 生命周期

  private func startPip() {
    NSLog("[FloatingLyrics] startPip called, active=\(pipController?.isPictureInPictureActive ?? false)")
    if pipController?.isPictureInPictureActive == true { return }
    let layer = displayLayer ?? AVSampleBufferDisplayLayer()
    displayLayer = layer
    layer.videoGravity = .resizeAspect
    // Apple 要求 sample-buffer layer 挂进视图层级（离屏 1pt 即可），
    // 否则 PiP 会话无法建立。方法通道回调在主线程，必须同步挂载——
    // 异步挂载会与 startPictureInPicture 产生竞态导致启动失败
    if layer.superlayer == nil {
      let window = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
      window?.layer.addSublayer(layer)
      layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
      NSLog("[FloatingLyrics] layer attached to window: \(window != nil)")
    }
    if pipController == nil {
      // 自定义 sample-buffer PiP 需 iOS 15+
      if #available(iOS 15.0, *) {
        let source = AVPictureInPictureController.ContentSource(
          sampleBufferDisplayLayer: layer, playbackDelegate: playbackDelegate)
        let c = AVPictureInPictureController(contentSource: source)
        // 退后台自动弹出 PiP 小窗
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.delegate = playbackDelegate
        pipController = c
      }
    }
    startRenderLoop()
    renderFrame(force: true)
    if #available(iOS 15.0, *) {
      let c = pipController
      NSLog(
        "[FloatingLyrics] start PiP: possible=\(c?.isPictureInPicturePossible ?? false)")
      c?.startPictureInPicture()
    }
  }

  private func stopPip() {
    stopRenderLoop()
    if #available(iOS 15.0, *) {
      if pipController?.isPictureInPictureActive == true {
        pipController?.stopPictureInPicture()
      }
    }
    displayLayer?.flush()
  }

  // MARK: - 渲染循环

  /// 4Hz 轮询：PiP 会话依赖持续供帧（长时间无帧会被系统判定为卡顿），
  /// 且本地时钟随播放推进，行变化即重绘
  private func startRenderLoop() {
    guard renderTimer == nil else { return }
    let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    t.schedule(deadline: .now(), repeating: 0.25)
    t.setEventHandler { [weak self] in
      self?.renderFrame(force: false)
    }
    t.resume()
    renderTimer = t
  }

  private func stopRenderLoop() {
    renderTimer?.cancel()
    renderTimer = nil
  }

  fileprivate var currentPositionMs: Int {
    let nowMs = Int(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1000)
    let delta = playing ? nowMs - baseStampMs : 0
    return basePositionMs + max(0, delta)
  }

  private func activeLine(at posMs: Int) -> Int? {
    for (i, l) in lines.enumerated() where posMs >= l.startMs && posMs < l.endMs {
      return i
    }
    // 间奏期落到上一句
    var last: Int?
    for (i, l) in lines.enumerated() where l.startMs <= posMs { last = i }
    return last
  }

  private func renderFrame(force: Bool) {
    guard let layer = displayLayer else { return }
    let posMs = currentPositionMs
    let idx = activeLine(at: posMs)
    let key = "\(idx)|\(settings.textColor)|\(settings.opacity)|\(settings.fontScale)|\(playing)"
    guard force || key != lastRenderedKey else { return }
    lastRenderedKey = key

    let blank = playing == false && settings.hideWhenPaused
    let buffer = makePixelBuffer { [weak self] ctx, w, h in
      guard let self = self else { return }
      self.drawBackground(ctx: ctx, w: w, h: h)
      guard !blank, let idx = idx else { return }
      self.drawLyric(ctx: ctx, w: w, h: h, index: idx)
    }
    guard let buffer = buffer, let sample = sampleBuffer(from: buffer) else {
      NSLog("[FloatingLyrics] render failed: buffer/sample nil")
      return
    }
    if layer.status == .failed {
      NSLog("[FloatingLyrics] layer error: \(layer.error?.localizedDescription ?? "?")")
      layer.flush()
    }
    layer.enqueue(sample)
  }

  // MARK: - 绘制

  private func drawBackground(ctx: CGContext, w: Int, h: Int) {
    guard settings.showBackground else { return }
    let bg = CGRect(x: 0, y: 0, width: w, height: h)
    let alpha = CGFloat(max(0.15, min(1.0, settings.opacity))) * 0.62
    ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: alpha))
    let path = CGPath(
      roundedRect: bg, cornerWidth: 40, cornerHeight: 40, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()
  }

  private func colorOf(_ argb: UInt32, fallbackAlpha: CGFloat = 1) -> CGColor {
    let a = CGFloat((argb >> 24) & 0xFF) / 255.0
    let r = CGFloat((argb >> 16) & 0xFF) / 255.0
    let g = CGFloat((argb >> 8) & 0xFF) / 255.0
    let b = CGFloat(argb & 0xFF) / 255.0
    return CGColor(
      srgbRed: r, green: g, blue: b, alpha: (a == 0 && argb <= 0xFF) ? fallbackAlpha : a)
  }

  private func makeFont(_ size: CGFloat) -> CTFont {
    if let f = customFont {
      return CTFontCreateCopyWithAttributes(f, size, nil, nil)
    }
    return CTFontCreateWithName("PingFangSC-Semibold" as CFString, size, nil)
  }

  private func drawLyric(ctx: CGContext, w: Int, h: Int, index: Int) {
    let line = lines[index]
    let s = settings

    var rows: [(text: String, color: CGColor, size: CGFloat)] = []
    let mainSize = CGFloat(72 * s.fontScale)
    let subSize = CGFloat(36 * s.fontScale * max(0.6, min(1.5, s.secondaryScale)))
    let textAlpha = CGFloat(max(0.15, min(1.0, s.opacity)))
    let mainColor = colorOf(s.textColor).copy(alpha: textAlpha)!
    // 未播放色 0 = 跟随主色淡化（与设置页预览一致）
    let subColor =
      s.unplayedColor == 0
      ? colorOf(s.textColor, fallbackAlpha: 0.42).copy(alpha: 0.42 * textAlpha)!
      : colorOf(s.unplayedColor).copy(alpha: textAlpha)!

    rows.append((line.text, mainColor, mainSize))
    if s.showRomanization, let r = line.romaji, !r.isEmpty {
      rows.append((r, subColor, subSize))
    }
    if s.showTranslation, let t = line.translation, !t.isEmpty {
      rows.append((t, subColor, subSize))
    }
    if s.showNextLine {
      let nextIdx = index + 1
      if nextIdx < lines.count {
        rows.append((lines[nextIdx].text, subColor, subSize))
      }
    }

    let lineGap: CGFloat = 10
    let heights = rows.map { $0.size }
    let totalH = heights.reduce(0, +) + CGFloat(lineGap) * CGFloat(rows.count - 1)
    var y = (CGFloat(h) + totalH) / 2  // CGContext 原点在左下

    ctx.textMatrix = .identity
    for row in rows {
      let font = makeFont(row.size)
      let astr = NSAttributedString(string: row.text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): row.color,
      ])
      let line = CTLineCreateWithAttributedString(astr)
      let width = CTLineGetTypographicBounds(line, nil, nil, nil)
      y -= row.size
      ctx.textPosition = CGPoint(
        x: (CGFloat(w) - CGFloat(width)) / 2, y: y + row.size * 0.18)
      CTLineDraw(line, ctx)
      y -= lineGap
    }
  }

  private func makePixelBuffer(_ draw: (CGContext, Int, Int) -> Void) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, Self.canvasW, Self.canvasH,
        kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
      let buffer = pb
    else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: Self.canvasW, height: Self.canvasH,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }

    // 透明底，避免 PiP 窗口出现黑色整幅
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0))
    ctx.fill(CGRect(x: 0, y: 0, width: Self.canvasW, height: Self.canvasH))
    draw(ctx, Self.canvasW, Self.canvasH)
    return buffer
  }

  private func sampleBuffer(from buffer: CVPixelBuffer) -> CMSampleBuffer? {
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 4),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: CMTime.invalid)
    var sample: CMSampleBuffer?
    guard let format = formatDescription(of: buffer),
      CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr
    else { return nil }
    return sample
  }

  private func formatDescription(of buffer: CVPixelBuffer) -> CMVideoFormatDescription? {
    var desc: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer,
        formatDescriptionOut: &desc) == noErr
    else { return nil }
    return desc
  }
}

// MARK: - 事件回传（MethodChannel）

// Dart 侧 floating_lyrics.dart 的 _events 是 MethodChannel，原生须用
// FlutterMethodChannel.invokeMethod 回传（与 Android 实现一致），
// 不能用 FlutterEventChannel/FlutterStreamHandler。
extension IosFloatingLyricsPlugin {
  fileprivate func emit(_ method: String, args: [String: Any] = [:]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventsChannel?.invokeMethod(
        method, arguments: args.isEmpty ? nil : args)
    }
  }
}

// MARK: - PiP 播放代理

/// 系统经该代理获知 PiP 内容的播放态并下发用户操作：
/// PiP 窗上的播放/暂停按钮 → setPlaying → 回传 onTogglePlayback；
/// 关闭按钮 → didStopPictureInPicture → 回传 onClosed（Dart 关掉开关）。
class LyricsPlaybackDelegate: NSObject,
  AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate
{
  weak var owner: IosFloatingLyricsPlugin?

  init(owner: IosFloatingLyricsPlugin) {
    self.owner = owner
    super.init()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    // 用户点了 PiP 窗的播放/暂停：等价于 App 内切播放态
    owner?.emit("onTogglePlayback")
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    let pos = owner?.currentPositionMs ?? 0
    return CMTimeRange(
      start: CMTime(value: CMTimeValue(pos), timescale: 1000),
      duration: CMTime(value: 1, timescale: 1000))
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    // 恒报播放中：歌词窗长期暂停会被系统回收 PiP
    return false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }

  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    NSLog("[FloatingLyrics] PiP will start")
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    NSLog("[FloatingLyrics] PiP did stop (closed=\(pictureInPictureController.isPictureInPictureActive == false))")
    owner?.emit("onClosed")
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("[FloatingLyrics] PiP failed: \(error.localizedDescription)")
  }
}
