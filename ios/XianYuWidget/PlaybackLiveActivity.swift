import ActivityKit
import WidgetKit
import SwiftUI

/// Live Activity：锁屏歌词 + 灵动岛（iOS 16.1+；extension 部署目标即 16.1）。
///
/// 进度/时间用 timerInterval 视图自走，仅在歌词行 / 播放态 / 切歌变化时由主 App
/// update（规避系统更新预算限制）。播放控制按钮 iOS 17+ 走 LiveActivityIntent
/// （系统在主 App 进程执行，挂起也能唤醒）；16.1 锁屏不放按钮——系统锁屏媒体
/// 控件本身已有播放控制。
struct PlaybackLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            LockScreenPlaybackView(state: context.state)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveCoverView(state: context.state)
                        .frame(width: 44, height: 44)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveProgressText(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !context.state.lyric.isEmpty {
                            Text(context.state.lyric)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.tint)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        LiveProgressSection(state: context.state)
                        LiveControlsRow(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                Image(systemName: context.state.playing ? "waveform" : "pause.fill")
                    .foregroundStyle(.tint)
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundStyle(.tint)
            }
        }
    }
}

// MARK: - 锁屏视图

struct LockScreenPlaybackView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                LiveCoverView(state: state)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text(state.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                LiveProgressText(state: state)
            }
            if !state.lyric.isEmpty {
                Text(state.lyric)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LiveProgressSection(state: state)
            LiveControlsRow(state: state)
        }
        .padding(14)
    }
}

// MARK: - 复用子视图

struct LiveCoverView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if let url = PlaybackStateStore.coverURL(rev: state.coverRev),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

/// 已播时间（播放中自走）与总时长。
struct LiveProgressText: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if state.duration > 0 {
            let start = Date(timeIntervalSinceNow: -state.position)
            let end = start.addingTimeInterval(state.duration)
            if state.playing {
                Text(timerInterval: start...end, countsDown: false, showsHours: true)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 64, alignment: .trailing)
            } else {
                Text("\(XianYuPlayerWidgetFormat.format(state.position)) / \(XianYuPlayerWidgetFormat.format(state.duration))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 进度条：播放中 timerInterval 自走，暂停时静态。
struct LiveProgressSection: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if state.duration > 0 {
            let start = Date(timeIntervalSinceNow: -state.position)
            let end = start.addingTimeInterval(state.duration)
            if state.playing {
                ProgressView(timerInterval: start...end, countsDown: false)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            } else {
                ProgressView(value: min(state.position, state.duration), total: state.duration)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
        }
    }
}

struct LiveControlsRow: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 0) {
                Spacer()
                Button(intent: PrevLiveIntent()) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 16))
                }
                .padding(.horizontal, 22)
                Button(intent: PlayPauseLiveIntent()) {
                    Image(systemName: state.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 21, weight: .semibold))
                }
                .padding(.horizontal, 22)
                Button(intent: NextLiveIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16))
                }
                .padding(.horizontal, 22)
                Spacer()
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
    }
}

enum XianYuPlayerWidgetFormat {
    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
