import WidgetKit
import SwiftUI

/// WidgetKit 扩展入口：桌面播放小组件 + Live Activity（锁屏/灵动岛歌词）。
@main
struct XianYuWidgetBundle: WidgetBundle {
    var body: some Widget {
        XianYuPlayerWidget()
        PlaybackLiveActivityWidget()
    }
}
