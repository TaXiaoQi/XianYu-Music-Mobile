import Foundation
import ActivityKit

/// Live Activity 属性与动态状态（Runner 与 XianYuWidget 两个 target 共享编译）。
///
/// 全部字段放 ContentState：无「随 Activity 恒定不变」的静态属性，简化 start/update 调用。
/// position/duration 仅供 UI 用 `Text(timerInterval:)` / `ProgressView(timerInterval:)`
/// 自走时钟，播放中无需周期性 update。
@available(iOS 16.1, *)
struct PlaybackActivityAttributes: ActivityAttributes {
    struct ContentState: Codable & Hashable {
        var title: String
        var artist: String
        /// 当前歌词行（锁屏歌词主体）。
        var lyric: String
        /// 秒。update 时刻的进度锚点。
        var position: Double
        var duration: Double
        var playing: Bool
        /// App Group 内封面文件版本号（cover_0 / cover_1 交替）。
        var coverRev: Int
    }
}
