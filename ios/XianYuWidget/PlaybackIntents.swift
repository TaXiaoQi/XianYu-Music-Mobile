import Foundation
import AppIntents
#if !EXTENSION
import Flutter
#endif

/// 播放控制动作总线（Runner 与 XianYuWidget 两个 target 共享编译）。
///
/// 两条链路：
/// - **Live Activity 按钮**（LiveActivityIntent，iOS 17+）：系统保证在主 App 进程执行
///   perform()（App 挂起时也会被唤醒），直接经 Flutter MethodChannel 驱动播放器；
/// - **桌面小组件按钮**（AppIntent，iOS 17+）：在 widget extension 进程执行，extension
///   拿不到 Flutter 引擎，故写 App Group 命令文件 + 发 Darwin 通知；播放中主 App 因
///   后台音频存活即时消费，挂起时降级为 pending 文件，下次唤醒消费。
enum PlaybackCommandHub {
    /// Darwin 通知名（跨进程唤醒主 App 消费小组件命令）。
    static let darwinNotificationName = "cc.xymusic.mobile.playbackCommand" as CFString

    #if !EXTENSION
    /// 主 App 侧 Flutter MethodChannel（IosWidgetPlugin 注册时写入）。
    /// App 冷启动被 LiveActivityIntent 唤醒时可能尚未注册，走 pending 文件兜底。
    nonisolated(unsafe) static weak var methodChannel: FlutterMethodChannel?

    /// 主 App 进程内直接派发（LiveActivityIntent 执行体 / Darwin 通知回调共用）。
    static func dispatchInApp(_ action: String) {
        if let channel = methodChannel {
            channel.invokeMethod("command", arguments: ["action": action])
        } else {
            // 引擎未就绪：落 pending 文件，Dart 侧 init 后 takePendingCommand 消费。
            PlaybackStateStore.writeCommand(action)
        }
    }
    #endif

    /// widget extension 进程派发：写 pending 命令 + 发 Darwin 通知。
    static func dispatchFromExtension(_ action: String) {
        PlaybackStateStore.writeCommand(action)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center, CFNotificationName(darwinNotificationName), nil, nil, true)
    }
}

// MARK: - Live Activity 按钮（iOS 17+，主 App 进程执行）

@available(iOS 17.0, *)
struct PlayPauseLiveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "播放 / 暂停"

    func perform() async throws -> some IntentResult {
        #if EXTENSION
        // LiveActivityIntent 由系统在主 App 进程执行；extension 内编译仅为 UI 引用，防御性 no-op。
        #else
        PlaybackCommandHub.dispatchInApp("toggle")
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct NextLiveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "下一首"

    func perform() async throws -> some IntentResult {
        #if EXTENSION
        #else
        PlaybackCommandHub.dispatchInApp("next")
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct PrevLiveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "上一首"

    func perform() async throws -> some IntentResult {
        #if EXTENSION
        #else
        PlaybackCommandHub.dispatchInApp("previous")
        #endif
        return .result()
    }
}

// MARK: - 桌面小组件按钮（iOS 17+，extension 进程执行，Darwin 通知转主 App）

@available(iOS 17.0, *)
struct PlayPauseWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "播放 / 暂停"

    func perform() async throws -> some IntentResult {
        PlaybackCommandHub.dispatchFromExtension("toggle")
        return .result()
    }
}

@available(iOS 17.0, *)
struct NextWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "下一首"

    func perform() async throws -> some IntentResult {
        PlaybackCommandHub.dispatchFromExtension("next")
        return .result()
    }
}

@available(iOS 17.0, *)
struct PrevWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "上一首"

    func perform() async throws -> some IntentResult {
        PlaybackCommandHub.dispatchFromExtension("previous")
        return .result()
    }
}
