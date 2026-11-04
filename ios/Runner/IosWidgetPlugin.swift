import Flutter
import UIKit
import WidgetKit
import ActivityKit

/// iOS 桌面小组件（WidgetKit）桥。
///
/// Dart 侧：lib/src/player/ios_widget_bridge.dart（IosWidgetController）。
///
/// 职责：
/// - setState：写 App Group 状态 JSON + 拷封面（cover_0/1 交替）+ 仅切歌时刷新
///   小组件时间线。
/// - clear：清空状态并收尾 Live Activity。
/// - 消费小组件按钮命令：Darwin 通知（extension AppIntent 发出）→ onCommand 回 Dart；
///   冷启动 pending command.json → takePendingCommand 供 Dart 启动时兜底消费。
///
/// 说明：Live Activity（锁屏歌词/灵动岛）已退役——系统播控媒体卡片
/// （audio_service Now Playing）承担锁屏/播控中心展示，两者同屏会出现
/// 两张媒体卡片。此处仅保留对旧版本遗留运行实例的清理。
final class IosWidgetPlugin: NSObject, FlutterPlugin {
    private static let channelName = "xianyu/ios_widget"

    private let channel: FlutterMethodChannel

    static func register(with registrar: any FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName, binaryMessenger: registrar.messenger())
        let instance = IosWidgetPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        PlaybackCommandHub.methodChannel = channel
        instance.observeDarwinNotification()
    }

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - MethodChannel

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setState":
            guard let args = call.arguments as? [String: Any] else {
                result(nil)
                return
            }
            handleSetState(args)
            result(nil)
        case "clear":
            if #available(iOS 16.1, *) {
                Self.endActivity()
            }
            _ = PlaybackStateStore.clearState()
            WidgetCenter.shared.reloadAllTimelines()
            result(nil)
        case "takePendingCommand":
            result(PlaybackStateStore.takeCommand())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 状态写入

    private func handleSetState(_ args: [String: Any]) {
        let title = args["title"] as? String ?? ""
        let artist = args["artist"] as? String ?? ""
        let lyric = args["lyric"] as? String ?? ""
        let playing = args["playing"] as? Bool ?? false
        let position = args["position"] as? Double ?? 0
        let duration = args["duration"] as? Double ?? 0
        let songChanged = args["songChanged"] as? Bool ?? false
        let coverPath = args["coverPath"] as? String

        var state = WidgetPlaybackState(
            title: title, artist: artist, lyric: lyric, playing: playing,
            position: position, duration: duration,
            coverRev: PlaybackStateStore.readState()?.coverRev ?? -1,
            updatedAt: Date().timeIntervalSince1970)

        // 封面变化时拷入 App Group 并更新版本号（cover_0/1 交替，避免读写竞态）。
        if let coverPath = coverPath, !coverPath.isEmpty,
           let newRev = PlaybackStateStore.writeCover(from: URL(fileURLWithPath: coverPath)) {
            state.coverRev = newRev
        }

        PlaybackStateStore.writeState(state)

        if songChanged {
            WidgetCenter.shared.reloadAllTimelines()
        }

        if #available(iOS 16.1, *) {
            // 退役的实时活动不再启动；旧版本可能遗留运行实例（进程重启后
            // 句柄丢失，注册表里还挂着），统一收尾防止与播控卡片重复
            Self.endActivity()
        }
    }

    // MARK: - Live Activity 收尾

    /// 结束本进程持有的 Live Activity，并清理注册表中的遗留实例
    /// （上一版本启动的实例在进程重启后仅能经 Activity.activities 发现）。
    @available(iOS 16.1, *)
    private static func endActivity() {
        for live in Activity<PlaybackActivityAttributes>.activities {
            Task {
                try? await live.end(using: live.contentState, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - Darwin 通知（小组件按钮命令）

    private func observeDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, _, _, _) in
                guard let observer = observer else { return }
                let plugin = Unmanaged<IosWidgetPlugin>.fromOpaque(observer)
                    .takeUnretainedValue()
                if let action = PlaybackStateStore.takeCommand() {
                    plugin.channel.invokeMethod("onCommand", arguments: ["action": action])
                }
            },
            PlaybackCommandHub.darwinNotificationName,
            nil,
            .deliverImmediately)
    }
}
