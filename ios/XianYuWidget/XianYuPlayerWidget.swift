import WidgetKit
import SwiftUI

// MARK: - Timeline 数据

struct PlaybackEntry: TimelineEntry {
    let date: Date
    let state: WidgetPlaybackState?
}

/// 单 entry 时间线（.never 刷新）：小组件内容由主 App 经 App Group 写入状态后，
/// 以 WidgetCenter.reloadAllTimelines 主动触发重载，无需系统周期刷新。
struct PlaybackProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaybackEntry {
        PlaybackEntry(date: Date(), state: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaybackEntry) -> Void) {
        completion(PlaybackEntry(date: Date(), state: PlaybackStateStore.readState() ?? .sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaybackEntry>) -> Void) {
        let entry = PlaybackEntry(date: Date(), state: PlaybackStateStore.readState())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: - Widget 配置

struct XianYuPlayerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "XianYuPlayerWidget", provider: PlaybackProvider()) { entry in
            PlaybackEntryView(entry: entry)
        }
        .configurationDisplayName("正在播放")
        .description("显示当前歌曲、歌词进度与播放控制")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - 视图

struct PlaybackEntryView: View {
    let entry: PlaybackEntry

    var body: some View {
        content
            .modifier(WidgetBackgroundModifier())
    }

    @ViewBuilder
    private var content: some View {
        if let s = entry.state {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    CoverView(state: s)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title.isEmpty ? "弦予音乐" : s.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(s.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if !s.lyric.isEmpty {
                    Text(s.lyric)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ProgressSection(state: s)
                ControlsRow(state: s)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text("弦予音乐")
                    .font(.system(size: 13, weight: .medium))
                Text("暂无播放内容")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// iOS 17 要求 widget 声明 containerBackground；iOS 16 退回内边距。
struct WidgetBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .containerBackground(for: .widget) {
                    Color(uiColor: .systemBackground)
                }
        } else {
            content.padding(12)
        }
    }
}

struct CoverView: View {
    let state: WidgetPlaybackState

    var body: some View {
        if let url = PlaybackStateStore.coverURL(rev: state.coverRev),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

/// 播放中进度用 timerInterval 自走（无需刷新小组件），暂停时静态展示。
struct ProgressSection: View {
    let state: WidgetPlaybackState

    var body: some View {
        if state.duration > 0 {
            let start = Date(timeIntervalSinceNow: -state.position)
            let end = start.addingTimeInterval(state.duration)
            if state.playing {
                VStack(spacing: 2) {
                    ProgressView(timerInterval: start...end, countsDown: false)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    HStack {
                        Text(timerInterval: start...end, countsDown: false, showsHours: true)
                            .font(.system(size: 10).monospacedDigit())
                        Spacer()
                        Text(Self.format(state.duration))
                            .font(.system(size: 10).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 2) {
                    ProgressView(
                        value: min(state.position, state.duration), total: state.duration)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    HStack {
                        Text(Self.format(state.position))
                            .font(.system(size: 10).monospacedDigit())
                        Spacer()
                        Text(Self.format(state.duration))
                            .font(.system(size: 10).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// 播放控制：iOS 17+ 交互按钮（extension 进程 AppIntent → Darwin 通知转主 App）；
/// iOS 16 回退整卡点按 widgetURL 打开 App 切换播放。
struct ControlsRow: View {
    let state: WidgetPlaybackState

    var body: some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 0) {
                Spacer()
                Button(intent: PrevWidgetIntent()) {
                    Image(systemName: "backward.fill").font(.system(size: 15))
                }
                .padding(.horizontal, 18)
                Button(intent: PlayPauseWidgetIntent()) {
                    Image(systemName: state.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                }
                .padding(.horizontal, 18)
                Button(intent: NextWidgetIntent()) {
                    Image(systemName: "forward.fill").font(.system(size: 15))
                }
                .padding(.horizontal, 18)
                Spacer()
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
        } else {
            Color.clear
                .frame(height: 1)
                .contentShape(Rectangle())
                .widgetURL(URL(string: "xianyu://play/toggle"))
        }
    }
}
