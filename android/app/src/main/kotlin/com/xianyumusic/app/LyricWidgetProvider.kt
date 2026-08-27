package com.xianyumusic.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/**
 * 桌面播放组件 · 歌词卡样式（独立组件入口，launcher 组件列表单独可选）。
 *
 * 固定 4×3 方卡（系统通知式平面底色，随系统明暗反转，参考酷狗 4×3 排布、
 * 控件与歌名互换）：左列大封面 + 底部三控制钮（上一首/品牌红播放/下一首）；
 * 右列歌名、歌手·弦予音乐、五行渐变歌词窗口（当前行固定居中加粗）、细进度条。
 * 歌词窗口数据来自状态 JSON 的 lyricWindow（Flutter 侧随播放滚动推送）。
 * 控制链路与主组件共用（WidgetShared）。
 */
class LyricWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val s = WidgetShared.stateJson(context) ?: JSONObject()
        val views = WidgetShared.buildViews(
            context, s, WidgetShared.MODE_LYRIC, LyricWidgetProvider::class.java, 5000)
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        // 固定样式不随尺寸切换，尺寸变化后重渲染即可。
        appWidgetManager.updateAppWidget(
            appWidgetId,
            WidgetShared.buildViews(
                context,
                WidgetShared.stateJson(context) ?: JSONObject(),
                WidgetShared.MODE_LYRIC,
                LyricWidgetProvider::class.java,
                5000))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        WidgetShared.handleAction(context, intent)
    }
}
