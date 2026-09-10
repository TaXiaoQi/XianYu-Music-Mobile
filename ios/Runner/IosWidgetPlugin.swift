import Flutter
import UIKit
import WidgetKit
import ActivityKit

/// iOS 桌面小组件（WidgetKit）与 Live Activity（锁屏/灵动岛歌词）桥。
///
/// Dart 侧：lib/src/player/ios_widget_bridge.dart（IosWidgetController）。
///
/// 职责：
/// - setState：写 App Group 状态 JSON + 拷封面（cover_0/1 交替）+ 仅切歌时刷新
///   小组件时间线；同时驱动 Live Activity start/update（歌词行/播放态变化即更）。
/// - clear：清空状态并结束 Live Activity。
/// - 消费小组件按钮命令：Darwin 通知（extension AppIntent 发出）→ onCommand 回 Dart；
///   冷启动 pending command.json → takePendingCommand 供 Dart 启动时兜底消费。
final class IosWidgetPlugin: NSObject, FlutterPlugin {
    private static let channelName = "xianyu/ios_widget"

    private let channel: FlutterMethodChannel

    /// 当前 Live Activity 句柄（主 App 进程单实例）。
    @available(iOS 16.1, *)
    private static var activity: Activity<PlaybackActivityAttributes>?

    static func register(with registry: FlutterPluginRegistry) {
        let registrar = registry.registrar(forPlugin: "IosWidgetPlugin")
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
            Self.startOrUpdateActivity(state)
        }
    }

    // MARK: - Live Activity

    @available(iOS 16.1, *)
    private static func makeContentState(
        _ s: WidgetPlaybackState
    ) -> PlaybackActivityAttributes.ContentState {
        .init(
            title: s.title, artist: s.artist, lyric: s.lyric,
            position: s.position, duration: s.duration, playing: s.playing,
            coverRev: s.coverRev)
    }

    /// 有播放内容时启动/更新 Live Activity；更新由 Dart 侧签名去重控制频率。
    @available(iOS 16.1, *)
    private static func startOrUpdateActivity(_ state: WidgetPlaybackState) {
        let contentState = makeContentState(state)
        if let activity = activity {
            Task {
                try? await activity.update(using: contentState)
            }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: PlaybackActivityAttributes(),
                contentState: contentState,
                pushType: nil)
        } catch {
            NSLog("[IosWidgetPlugin] request live activity failed: \(error)")
        }
    }

    /// 结束 Live Activity（队列清空 / Dart 显式清理）。
    @available(iOS 16.1, *)
    private static func endActivity() {
        guard let activity = activity else { return }
        Self.activity = nil
        Task {
            try? await activity.end(using: activity.contentState, dismissalPolicy: .immediate)
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
