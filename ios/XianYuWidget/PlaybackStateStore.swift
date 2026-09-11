import Foundation

/// App Group 共容器的播放状态快照（WidgetKit 小组件与 Live Activity 渲染数据源）。
struct WidgetPlaybackState: Codable {
    var title: String
    var artist: String
    var lyric: String
    var playing: Bool
    var position: Double
    var duration: Double
    var coverRev: Int
    var updatedAt: TimeInterval

    /// 占位样态（无播放记录 / TimelineProvider placeholder）。
    static let sample = WidgetPlaybackState(
        title: "弦予音乐", artist: " ", lyric: "",
        playing: false, position: 0, duration: 0, coverRev: -1, updatedAt: 0)
}

/// App Group (`group.cc.xymusic.mobile`) 容器读写：状态 JSON / 封面文件 / 交互命令。
///
/// 数据流：
/// - 主 App（Runner / IosWidgetPlugin）写入状态与封面；
/// - WidgetKit TimelineProvider、Live Activity UI 读取渲染；
/// - 反向：AppIntent（小组件按钮）写命令文件 + 发 Darwin 通知，主 App 消费。
enum PlaybackStateStore {
    static let appGroupId = "group.cc.xymusic.mobile"
    static let stateFileName = "state.json"
    static let commandFileName = "command.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    // ---- 播放状态 ----

    static func writeState(_ state: WidgetPlaybackState) {
        guard let dir = containerURL else { return }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: dir.appendingPathComponent(stateFileName), options: .atomic)
        } catch {
            NSLog("[XianYuWidget] writeState failed: \(error)")
        }
    }

    static func readState() -> WidgetPlaybackState? {
        guard let dir = containerURL,
              let data = try? Data(contentsOf: dir.appendingPathComponent(stateFileName))
        else { return nil }
        return try? JSONDecoder().decode(WidgetPlaybackState.self, from: data)
    }

    /// 清空状态（播放队列清空 / 退出）。返回是否确有旧状态被清理。
    @discardableResult
    static func clearState() -> Bool {
        guard let dir = containerURL else { return false }
        let url = dir.appendingPathComponent(stateFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    // ---- 封面：cover_0 / cover_1 交替写，避免 extension 读到写了一半的文件 ----

    /// 拷贝封面到 App Group，返回新版本号（失败返回 nil，沿用旧封面）。
    static func writeCover(from source: URL) -> Int? {
        guard let dir = containerURL else { return nil }
        let nextRev = (readState()?.coverRev ?? -1) + 1
        do {
            let data = try Data(contentsOf: source)
            try data.write(to: dir.appendingPathComponent("cover_\(nextRev % 2)"), options: .atomic)
            return nextRev
        } catch {
            NSLog("[XianYuWidget] writeCover failed: \(error)")
            return nil
        }
    }

    static func coverURL(rev: Int) -> URL? {
        guard rev >= 0 else { return nil }
        return containerURL?.appendingPathComponent("cover_\(rev % 2)")
    }

    // ---- 交互命令（widget extension AppIntent -> 主 App）----

    static func writeCommand(_ action: String) {
        guard let dir = containerURL else { return }
        let payload: [String: String] = [
            "action": action,
            "ts": String(Date().timeIntervalSince1970),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: dir.appendingPathComponent(commandFileName), options: .atomic)
        }
    }

    /// 取出并删除 pending 命令（主 App 启动/唤醒时消费兜底）。
    static func takeCommand() -> String? {
        guard let dir = containerURL else { return nil }
        let url = dir.appendingPathComponent(commandFileName)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = obj["action"] as? String
        else { return nil }
        try? FileManager.default.removeItem(at: url)
        return action
    }
}
